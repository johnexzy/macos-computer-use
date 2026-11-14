//! MCP adapts public arguments to the same typed client used by Rust callers.
use cua_client::Client;
use cua_protocol::*;
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Implementation, ServerCapabilities, ServerConfig},
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::json;
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

fn default_budget() -> u32 {
    5000
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CapabilitiesArgs {
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TargetsArgs {
    pub bundle_id: Option<String>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ObserveArgs {
    pub target: TargetKey,
    #[serde(default)]
    pub include_screenshot: bool,
    #[serde(default)]
    pub include_values: bool,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActArgs {
    pub observation_id: String,
    pub target: TargetKey,
    #[schemars(length(min = 1, max = 16))]
    pub steps: Vec<ActionStep>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WaitArgs {
    pub observation_id: String,
    pub target: TargetKey,
    pub condition: Condition,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Clone)]
pub struct Host {
    client: Arc<Client>,
    disconnected: CancellationToken,
    trace_count: Arc<AtomicUsize>,
    admission: Arc<tokio::sync::Semaphore>,
    tool_router: ToolRouter<Self>,
}

// Dropping an MCP handler must cancel native ownership even if rmcp drops its response.
struct RequestCancellation {
    token: CancellationToken,
    forwarder: tokio::task::JoinHandle<()>,
}
impl Drop for RequestCancellation {
    fn drop(&mut self) {
        self.token.cancel();
        self.forwarder.abort();
    }
}

fn validate_public(body: &RequestBody, budget_ms: u32) -> Result<(), McpError> {
    let mut body = body.clone();
    if let RequestBody::Act(act) = &mut body {
        act.grant_id = "host-validation".into();
    }
    Frame::Request(Request {
        version: VERSION,
        id: "public-validation".into(),
        epoch: Some("host-validation".into()),
        budget_ms,
        body,
    })
    .validate()
    .map_err(|e| McpError::invalid_params(e, None))
}

fn before_native_error(code: ErrorCode, message: &'static str) -> CallToolResult {
    CallToolResult::structured_error(json!({"version":VERSION,"route":"rust_host",
        "delivery":Delivery::NotDispatched,"verification":Verification::Unverified,
        "error":{"code":code,"message":message}}))
}

#[tool_router]
impl Host {
    pub fn new(client: Arc<Client>, disconnected: CancellationToken) -> Self {
        Self {
            client,
            disconnected,
            trace_count: Arc::new(AtomicUsize::new(0)),
            admission: Arc::new(tokio::sync::Semaphore::new(16)),
            tool_router: Self::tool_router(),
        }
    }

    async fn execute(
        &self,
        body: RequestBody,
        budget_ms: u32,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        let started = Instant::now();
        let Ok(_permit) = self.admission.try_acquire() else {
            return Ok(before_native_error(
                ErrorCode::ResourceLimit,
                "Host request limit reached",
            ));
        };
        validate_public(&body, budget_ms)?;
        let method = match &body {
            RequestBody::Capabilities(_) => "capabilities",
            RequestBody::Targets(_) => "targets",
            RequestBody::Observe(_) => "observe",
            RequestBody::Act(_) => "act",
            RequestBody::WaitFor(_) => "waitFor",
            _ => unreachable!("only public operations are routed"),
        };
        let token = self.disconnected.child_token();
        if context.ct.is_cancelled() {
            token.cancel();
        }
        let forward_token = token.clone();
        let forwarder = tokio::spawn(async move {
            context.ct.cancelled().await;
            forward_token.cancel();
        });
        let cancellation = RequestCancellation { token, forwarder };
        let Some(remaining) = Duration::from_millis(budget_ms.into())
            .checked_sub(started.elapsed())
            .filter(|remaining| remaining.as_millis() > 0)
        else {
            return Ok(before_native_error(
                ErrorCode::DeadlineExceeded,
                "Request budget exhausted before native handoff",
            ));
        };
        let response = self
            .client
            .call(body, remaining, cancellation.token.clone())
            .await;
        let trace = self.trace_count.fetch_add(1, Ordering::Relaxed) < 256;
        match response {
            Ok(response) => {
                let (dispatch, verification, stop) = match &response.body {
                    ResponseBody::Act(result) => (
                        result.steps.last().map(|s| s.delivery),
                        result.steps.last().map(|s| s.verification),
                        Some(result.stop_reason),
                    ),
                    _ => (None, None, None),
                };
                let native_elapsed = self
                    .client
                    .diagnostics()
                    .traces
                    .iter()
                    .rev()
                    .find(|trace| trace.request_id == response.id)
                    .map(|trace| trace.elapsed_ms);
                if trace {
                    eprintln!(
                        "{}",
                        json!({"event":"tool_finished","route":"persistent_swift","method":method,
                    "requestId":response.id,"elapsedMs":started.elapsed().as_secs_f64()*1000.0,
                    "nativeClientElapsedMs":native_elapsed,
                    "delivery":dispatch,"verification":verification,"stopReason":stop})
                    );
                }
                let is_error = matches!(&response.body, ResponseBody::Error(_))
                    || matches!(&response.body, ResponseBody::Act(result) if result.stop_reason != StopReason::Completed);
                let value = serde_json::to_value(response)
                    .map_err(|_| McpError::internal_error("Cannot encode native receipt", None))?;
                Ok(if is_error {
                    CallToolResult::structured_error(value)
                } else {
                    CallToolResult::structured(value)
                })
            }
            Err(error) => {
                if trace {
                    eprintln!(
                        "{}",
                        json!({"event":"tool_failed","route":"rust_host","method":method,
                    "elapsedMs":started.elapsed().as_secs_f64()*1000.0,"code":error.kind.as_str()})
                    );
                }
                Ok(CallToolResult::structured_error(
                    json!({"version":VERSION,"route":"rust_host",
                    "error":{"code":error.kind.as_str(),"message":error.message},"uncertainty":error.uncertainty}),
                ))
            }
        }
    }

    #[tool(
        description = "Read native permissions, installed execution mode and supported actions without requesting permissions."
    )]
    async fn capabilities(
        &self,
        Parameters(args): Parameters<CapabilitiesArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(RequestBody::Capabilities(Empty {}), args.budget_ms, context)
            .await
    }

    #[tool(
        description = "List bounded exact process/window targets, optionally filtering by bundle ID."
    )]
    async fn targets(
        &self,
        Parameters(args): Parameters<TargetsArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Targets(TargetsRequest {
                bundle_id: args.bundle_id,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Collect a session-scoped observation for one exact target. Values and images are opt-in. Semantic AX/image collection is not yet supported by this runtime."
    )]
    async fn observe(
        &self,
        Parameters(args): Parameters<ObserveArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Observe(ObserveRequest {
                target: args.target,
                include_screenshot: args.include_screenshot,
                include_values: args.include_values,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Run bounded typed steps with independent delivery and verification receipts. The host installs authority; unsupported operations are refused without input."
    )]
    async fn act(
        &self,
        Parameters(args): Parameters<ActArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Act(ActRequest {
                grant_id: String::new(),
                observation_id: args.observation_id,
                target: args.target,
                steps: args.steps,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        name = "waitFor",
        description = "Wait for a typed condition within one request budget. Native predicate evaluation is not yet supported by this runtime."
    )]
    async fn wait_for(
        &self,
        Parameters(args): Parameters<WaitArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::WaitFor(WaitRequest {
                observation_id: args.observation_id,
                target: args.target,
                condition: args.condition,
            }),
            args.budget_ms,
            context,
        )
        .await
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Host {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("macos-computer-use", env!("CARGO_PKG_VERSION")))
            .with_instructions("Background authority is installed by the operator. Read capabilities before acting. Observations establish provenance, not freshness. Unknown delivery must be reconciled before retrying. Semantic AX actions are a subsequent milestone.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_arguments_cannot_install_policy_or_protocol_fields() {
        for field in ["grantId", "mode", "epoch", "authority", "executionMode"] {
            let value = json!({(field):"foregroundAllowed"});
            assert!(serde_json::from_value::<CapabilitiesArgs>(value).is_err());
        }
        assert!(
            serde_json::from_value::<ActArgs>(
                json!({"observationId":"o","target":{"pid":1,"windowId":1},
            "steps":[],"grantId":"forged"})
            )
            .is_err()
        );
    }

    #[test]
    fn invalid_public_bounds_never_reach_native_transport() {
        assert!(validate_public(&RequestBody::Capabilities(Empty {}), 0).is_err());
        assert!(validate_public(&RequestBody::Capabilities(Empty {}), 60001).is_err());
        assert!(
            validate_public(
                &RequestBody::Observe(ObserveRequest {
                    target: TargetKey {
                        pid: 0,
                        window_id: 1
                    },
                    include_screenshot: false,
                    include_values: false
                }),
                5000
            )
            .is_err()
        );
    }
}
