//! MCP adapts public arguments to the same typed client used by Rust callers.
pub mod browser_bridge;
mod compact;
pub mod telemetry;
use browser_bridge::BrowserBridgeClient;
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use telemetry::TelemetryClient;
use tokio_util::sync::CancellationToken;
use useui_client::Client;
use useui_protocol::*;

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
    #[schemars(length(min = 1, max = 1024))]
    pub title_contains: Option<String>,
    #[schemars(length(min = 1, max = 1024))]
    pub owner_contains: Option<String>,
    #[serde(default)]
    pub unbundled_only: bool,
    #[serde(default)]
    pub include_offscreen: bool,
    #[serde(default)]
    pub include_apps: bool,
    #[serde(default)]
    pub include_displays: bool,
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
    pub include_ocr: bool,
    #[schemars(length(min = 1, max = 4096))]
    pub ocr_query: Option<String>,
    pub crop_window: Option<Rect>,
    #[schemars(range(min = 64, max = 2048))]
    pub max_image_dimension_px: Option<u32>,
    #[schemars(length(min = 1, max = 16))]
    pub ax_selectors: Option<Vec<Selector>>,
    pub event_history: Option<EventHistoryRequest>,
    pub scope: Option<ObserveScope>,
    #[serde(default)]
    pub interactive_only: bool,
    #[schemars(length(min = 1, max = 1024))]
    pub query: Option<String>,
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
    pub feedback: Option<FeedbackRequest>,
    #[serde(default)]
    pub foreground: bool,
    pub observe_after: Option<ObserveAfter>,
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
    #[serde(default)]
    pub include_values: bool,
    pub scope: Option<ObserveScope>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenArgs {
    pub bundle_id: Option<String>,
    #[schemars(length(min = 1, max = 256))]
    pub app_name: Option<String>,
    #[schemars(length(min = 1, max = 2048))]
    pub url: Option<String>,
    #[serde(default)]
    pub new_instance: bool,
    #[serde(default)]
    pub activate: bool,
    pub observe: Option<ObserveAfter>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClipboardArgs {
    pub action: ClipboardAction,
    #[serde(default)]
    pub include_text: bool,
    pub text: Option<String>,
    #[schemars(length(min = 1, max = 2048))]
    pub file_path: Option<String>,
    #[schemars(length(min = 1, max = 2048))]
    pub image_path: Option<String>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum BrowserAction {
    Status,
    ListTabs,
    OpenTab,
    Navigate,
    Snapshot,
    Act,
    BatchRead,
    CloseTab,
}

impl BrowserAction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::ListTabs => "listTabs",
            Self::OpenTab => "openTab",
            Self::Navigate => "navigate",
            Self::Snapshot => "snapshot",
            Self::Act => "act",
            Self::BatchRead => "batchRead",
            Self::CloseTab => "closeTab",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum BrowserHistory {
    Back,
    Forward,
    Reload,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowserStep {
    pub id: Option<String>,
    /// One of: "click", "type", "select", "pressKey", "scroll", "waitFor".
    pub kind: String,
    #[serde(rename = "ref")]
    pub element_ref: Option<String>,
    pub text: Option<String>,
    pub role: Option<String>,
    pub selector: Option<String>,
    pub value: Option<String>,
    pub label: Option<String>,
    pub clear: Option<bool>,
    pub submit: Option<bool>,
    pub key: Option<String>,
    pub direction: Option<String>,
    pub delta_y: Option<i32>,
    pub url_contains: Option<String>,
    pub text_contains: Option<String>,
    pub ms: Option<u32>,
    pub timeout_ms: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowserArgs {
    pub action: BrowserAction,
    pub tab_id: Option<i64>,
    pub snapshot_id: Option<String>,
    #[schemars(length(min = 1, max = 2048))]
    pub url: Option<String>,
    #[schemars(length(min = 1, max = 6))]
    pub urls: Option<Vec<String>>,
    pub history: Option<BrowserHistory>,
    pub active: Option<bool>,
    #[schemars(length(min = 1, max = 16))]
    pub steps: Option<Vec<BrowserStep>>,
    pub return_snapshot: Option<bool>,
    pub interactive_only: Option<bool>,
    pub include_text: Option<bool>,
    pub include_links: Option<bool>,
    #[schemars(length(min = 1, max = 1024))]
    pub query: Option<String>,
    #[schemars(range(min = 200, max = 30000))]
    pub max_chars: Option<u32>,
    #[schemars(range(min = 300, max = 16000))]
    pub max_chars_per_page: Option<u32>,
    #[schemars(range(min = 1, max = 400))]
    pub max_elements: Option<u32>,
    pub close_after: Option<bool>,
    #[schemars(range(min = 1, max = 6))]
    pub concurrency: Option<u32>,
    #[schemars(range(min = 0, max = 10000))]
    pub settle_ms: Option<u32>,
    #[schemars(length(min = 1, max = 28))]
    pub group_label: Option<String>,
    #[schemars(length(min = 1, max = 16))]
    pub group_color: Option<String>,
    pub visual: Option<bool>,
    #[serde(default = "default_budget")]
    #[schemars(range(min = 1, max = 60000))]
    pub budget_ms: u32,
}

#[derive(Clone)]
pub struct Host {
    client: Arc<Client>,
    browser_bridge: BrowserBridgeClient,
    telemetry: TelemetryClient,
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
    if let RequestBody::Open(open) = &mut body {
        open.grant_id = "host-validation".into();
    }
    if let RequestBody::Clipboard(clipboard) = &mut body {
        clipboard.grant_id = "host-validation".into();
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

fn extract_screenshot_block(value: &mut Value, pointer: &str) -> Option<ContentBlock> {
    value
        .pointer_mut(pointer)
        .and_then(Value::as_object_mut)
        .and_then(|screenshot| {
            let mime_type = match screenshot.get("mimeType")?.as_str()? {
                "jpeg" => "image/jpeg",
                "png" => "image/png",
                _ => return None,
            };
            let Value::String(data) = screenshot.remove("dataBase64")? else {
                return None;
            };
            Some(ContentBlock::image(data, mime_type))
        })
}

fn native_receipt(response: Response, is_error: bool) -> Result<CallToolResult, McpError> {
    let compact_text = if is_error {
        None
    } else {
        Some(compact::format_response(&response))
    };
    let mut value = serde_json::to_value(response)
        .map_err(|_| McpError::internal_error("Cannot encode native receipt", None))?;
    if is_error {
        return Ok(CallToolResult::structured_error(value));
    }
    let image = extract_screenshot_block(&mut value, "/body/data/screenshot")
        .or_else(|| extract_screenshot_block(&mut value, "/body/data/observation/screenshot"));
    let mut result = CallToolResult::structured(value);
    if let Some(text) = compact_text {
        result.content = vec![ContentBlock::text(text)];
    }
    if let Some(image) = image {
        result.content.push(image);
    }
    Ok(result)
}

#[tool_router]
impl Host {
    pub fn new(client: Arc<Client>, disconnected: CancellationToken) -> Self {
        Self::with_telemetry(client, disconnected, TelemetryClient::disabled())
    }

    pub fn with_telemetry(
        client: Arc<Client>,
        disconnected: CancellationToken,
        telemetry: TelemetryClient,
    ) -> Self {
        Self {
            client,
            browser_bridge: BrowserBridgeClient::new(),
            telemetry,
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
        if (matches!(&body, RequestBody::Act(act) if act.foreground)
            || matches!(&body, RequestBody::Open(open) if open.activate))
            && self.client.execution_mode() != ExecutionMode::ForegroundAllowed
        {
            return Ok(before_native_error(
                ErrorCode::AuthorityDenied,
                "Operator foreground authority is required",
            ));
        }
        let method = match &body {
            RequestBody::Capabilities(_) => "capabilities",
            RequestBody::Targets(_) => "targets",
            RequestBody::Observe(_) => "observe",
            RequestBody::Act(_) => "act",
            RequestBody::WaitFor(_) => "waitFor",
            RequestBody::Open(_) => "open",
            RequestBody::Clipboard(_) => "clipboard",
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
                native_receipt(response, is_error)
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
        description = "Read native permissions, installed execution mode, supported actions, and browser accelerator extension status without requesting permissions."
    )]
    async fn capabilities(
        &self,
        Parameters(args): Parameters<CapabilitiesArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        let mut res = self
            .execute(RequestBody::Capabilities(Empty {}), args.budget_ms, context)
            .await?;
        if res.is_error != Some(true) {
            let ext = self.browser_bridge.status().await;
            let summary = compact::format_browser_result("status", &ext);
            if let Some(Value::Object(map)) = res.structured_content.as_mut() {
                map.insert("browserExtension".into(), ext);
            }
            if let Some(first) = res.content.first_mut()
                && let Some(text_block) = first.as_text()
            {
                let mut combined = text_block.text.clone();
                combined.push_str(&summary);
                *first = ContentBlock::text(combined);
            }
        }
        Ok(res)
    }

    #[tool(
        description = "List bounded exact process/window targets. Filter by exact bundleId, case-insensitive titleContains or ownerContains, or unbundledOnly for verified window owners without a bundle ID. Optional includeOffscreen includes minimized/hidden/other-Space windows with an onScreen flag. Optional includeApps lists running and installed apps, and includeDisplays lists active displays (bounds in top-left logical coordinates, scaleFactor, isPrimary)."
    )]
    async fn targets(
        &self,
        Parameters(args): Parameters<TargetsArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Targets(TargetsRequest {
                bundle_id: args.bundle_id,
                title_contains: args.title_contains,
                owner_contains: args.owner_contains,
                unbundled_only: args.unbundled_only,
                include_offscreen: args.include_offscreen,
                include_apps: args.include_apps,
                include_displays: args.include_displays,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Observe one exact window, including Accessibility controls exposed by owners without a bundle ID. Request screenshots or OCR for controls or windows without usable AX coverage. Optional scope narrows AX reads to 'webArea' (skipping browser tabs/chrome) or 'menuBar' (inspecting native app menu items for invokeMenu). Optional interactiveOnly keeps only interactive controls. Optional query performs a case-insensitive substring search across label, identifier, subrole, url (and value when includeValues: true). Optional axSelectors (with optional role plus label, labelContains, or identifier) reads matching AX controls and reports query coverage separately from window coverage. Optional eventHistory retains bounded selected-state changes between observations; historical controls have no actionable refs. Values, screenshots, and Vision OCR are opt-in. cropWindow uses window-local points. Partial coverage cannot prove absence; history can be stale or overrun."
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
                include_ocr: args.include_ocr,
                ocr_query: args.ocr_query,
                crop_window: args.crop_window,
                max_image_dimension_px: args.max_image_dimension_px,
                ax_selectors: args.ax_selectors,
                event_history: args.event_history,
                scope: args.scope,
                interactive_only: args.interactive_only,
                query: args.query,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Run 1-16 ordered typed actions and predicate waits within one budget. Background mode supports setValue, typeText (selection replacement), press, confirm (AXConfirm), showMenu (AXShowMenu), cancel (AXCancel), invokeMenu (native AXMenuBar path), setWindowFrame (background AX move/resize), windowAction (minimize or close via AX), scroll (AXScrollArea), and scrollToVisible on live references. Foreground mode (requires operator foregroundAllowed grant and foreground: true) supports click, doubleClick, rightClick, hover, drag, scrollWheel (coordinate wheel scroll), focusWindow (persistently raise & focus target), key, hotkey (arbitrary key + command/control/option/shift modifiers), and typeKeys (focused Unicode text input). Stops at the first failed requirement. Optional feedback returns requested control updates tied to the base observation. Optional observeAfter captures and registers a fresh post-action observation (with scope, interactiveOnly, query, includeValues, includeOcr, or includeScreenshot) in the same round-trip so act + expect + observe completes in one call. No rollback or automatic replay."
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
                feedback: args.feedback,
                foreground: args.foreground,
                observe_after: args.observe_after,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        name = "waitFor",
        description = "Wait within one budget for an exact value, valueContains substring, enabled state, element presence/absence (supporting optional role, exact label, labelContains, or identifier), web URL substring (urlContains), visual OCR text substring (ocrContains, including on windows without AX), or disappearance of the exact window identity. Optional includeValues and scope ('window' or 'webArea') control the fresh observation returned on satisfaction. Partial reads cannot prove absence. Window disappearance returns timestamped evidence without creating a replacement target."
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
                include_values: args.include_values,
                scope: args.scope,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Launch an application by bundleId or appName and/or open a URL (http/https/file/mailto/custom scheme). Runs in the background by default (activate: false) without stealing foreground focus, returning the launched process PID and any visible window targets ready for observe. Optional observe captures and registers an initial observation on the first opened target in the same call. Setting activate: true requires an operator foregroundAllowed grant."
    )]
    async fn open(
        &self,
        Parameters(args): Parameters<OpenArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Open(OpenRequest {
                grant_id: String::new(),
                bundle_id: args.bundle_id,
                app_name: args.app_name,
                url: args.url,
                new_instance: args.new_instance,
                activate: args.activate,
                observe: args.observe,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Read, write, or clear the macOS system clipboard without stealing focus. Privacy-gated: action 'read' returns changeCount, UTI types, and textBytes by default, omitting clipboard text unless includeText: true is explicitly set. Action 'write' requires exactly one of text (plain UTF-8), filePath (absolute local file path), or imagePath (absolute local image path). Action 'clear' empties the clipboard."
    )]
    async fn clipboard(
        &self,
        Parameters(args): Parameters<ClipboardArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        self.execute(
            RequestBody::Clipboard(ClipboardRequest {
                grant_id: String::new(),
                action: args.action,
                include_text: args.include_text,
                text: args.text,
                file_path: args.file_path,
                image_path: args.image_path,
            }),
            args.budget_ms,
            context,
        )
        .await
    }

    #[tool(
        description = "Fast, zero-focus-stealing Chromium browser accelerator via the bundled MV3 Native Messaging extension (uses the user's real signed-in browser profile with zero open TCP ports). Automatically organizes UseUI-created tabs into a branded Chrome Tab Group (optional groupLabel/groupColor) and runs batchRead workers inside a collapsed group. Prefer this over AX observe/act for web workflows whenever capabilities reports browserExtension connected=true. Actions: 'status' (check bridge), 'listTabs', 'openTab' (background tab with optional returnSnapshot/includeText/groupLabel in one call), 'navigate' (url or history: 'back'|'forward'|'reload' + optional snapshot), 'snapshot' (fast ~20ms compact DOM outline with refs bN.M + optional includeText/query), 'act' (1-16 DOM steps: click by ref/text/selector, type, select, pressKey, scroll, waitFor urlContains/textContains/selector/ms + fresh post-action snapshot in one call), 'batchRead' (read 1-6 URLs in parallel collapsed background tabs in one call), and 'closeTab'."
    )]
    async fn browser(
        &self,
        Parameters(args): Parameters<BrowserArgs>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        if args.budget_ms == 0 || args.budget_ms > MAX_BUDGET_MS {
            return Err(McpError::invalid_params("invalid budgetMs", None));
        }
        let Ok(_permit) = self.admission.try_acquire() else {
            return Ok(before_native_error(
                ErrorCode::ResourceLimit,
                "Host request limit reached",
            ));
        };
        let action_name = args.action.as_str();
        if matches!(args.action, BrowserAction::Status) {
            let status = self.browser_bridge.status().await;
            let text = compact::format_browser_result("status", &status);
            let mut result = CallToolResult::structured(json!({
                "version": VERSION,
                "route": "browser_extension",
                "action": "status",
                "data": status,
            }));
            result.content = vec![ContentBlock::text(text)];
            return Ok(result);
        }

        let mut params = serde_json::Map::new();
        if let Some(v) = args.tab_id {
            params.insert("tabId".into(), json!(v));
        }
        if let Some(v) = args.snapshot_id {
            params.insert("snapshotId".into(), json!(v));
        }
        if let Some(v) = args.url {
            params.insert("url".into(), json!(v));
        }
        if let Some(v) = args.urls {
            params.insert("urls".into(), json!(v));
        }
        if let Some(v) = args.history {
            params.insert("history".into(), json!(v));
        }
        if let Some(v) = args.active {
            params.insert("active".into(), json!(v));
        }
        if let Some(v) = args.steps {
            params.insert("steps".into(), json!(v));
        }
        if let Some(v) = args.return_snapshot {
            params.insert("returnSnapshot".into(), json!(v));
        }
        if let Some(v) = args.interactive_only {
            params.insert("interactiveOnly".into(), json!(v));
        }
        if let Some(v) = args.include_text {
            params.insert("includeText".into(), json!(v));
        }
        if let Some(v) = args.include_links {
            params.insert("includeLinks".into(), json!(v));
        }
        if let Some(v) = args.query {
            params.insert("query".into(), json!(v));
        }
        if let Some(v) = args.max_chars {
            params.insert("maxChars".into(), json!(v));
        }
        if let Some(v) = args.max_chars_per_page {
            params.insert("maxCharsPerPage".into(), json!(v));
        }
        if let Some(v) = args.max_elements {
            params.insert("maxElements".into(), json!(v));
        }
        if let Some(v) = args.close_after {
            params.insert("closeAfter".into(), json!(v));
        }
        if let Some(v) = args.concurrency {
            params.insert("concurrency".into(), json!(v));
        }
        if let Some(v) = args.settle_ms {
            params.insert("settleMs".into(), json!(v));
        }
        if let Some(v) = args.group_label {
            params.insert("groupLabel".into(), json!(v));
        }
        if let Some(v) = args.group_color {
            params.insert("groupColor".into(), json!(v));
        }
        if let Some(v) = args.visual {
            params.insert("visual".into(), json!(v));
        }

        let summary_label = telemetry::describe_browser_call(action_name, &params);
        if action_name != "listTabs" {
            self.telemetry
                .emit_browser("active", &summary_label, Some(action_name));
        }

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
        let budget = Duration::from_millis(args.budget_ms.into());

        match self
            .browser_bridge
            .call(
                action_name,
                Value::Object(params),
                budget,
                cancellation.token.clone(),
            )
            .await
        {
            Ok(data) => {
                if action_name != "listTabs" {
                    let detail = data
                        .get("title")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty());
                    self.telemetry.emit_browser("done", &summary_label, detail);
                }
                let text = compact::format_browser_result(action_name, &data);
                let mut result = CallToolResult::structured(json!({
                    "version": VERSION,
                    "route": "browser_extension",
                    "action": action_name,
                    "data": data,
                }));
                result.content = vec![ContentBlock::text(text)];
                Ok(result)
            }
            Err(err) => {
                if action_name != "listTabs" {
                    self.telemetry
                        .emit_browser("error", &summary_label, Some(err.code));
                }
                Ok(CallToolResult::structured_error(json!({
                    "version": VERSION,
                    "route": "browser_extension",
                    "action": action_name,
                    "error": { "code": err.code, "message": err.message },
                })))
            }
        }
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Host {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("useui", env!("CARGO_PKG_VERSION")))
            .with_instructions("Background authority is installed by the operator. Read capabilities before acting. When capabilities reports browserExtension connected=true, prefer the browser tool for Chromium web workflows (fast compact DOM snapshots, compound act steps, and parallel batchRead in background tabs without stealing focus). Use targets (optionally with includeOffscreen, includeApps, includeDisplays) to discover windows, apps, and displays. Use open (optionally with observe) to launch apps or open URLs in the background (activate: true requires foregroundAllowed). Use clipboard (read/write/clear; includeText: true required to read clipboard contents) without stealing focus. Use observe (optionally with scope: webArea/menuBar, interactiveOnly, query, or role-optional axSelectors) to establish provenance. Use act with observeAfter to combine action + expect wait + fresh post-action observation in a single call. Use waitFor for AX predicates, urlContains, ocrContains (even without AX), or windowAbsent. Unknown delivery must be reconciled before retrying. Use only actions advertised by the live element. The foreground route requires an operator grant and explicit foreground: true on act. Foreground pointer operations require fresh image-backed evidence.")
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
        assert!(
            serde_json::from_value::<OpenArgs>(
                json!({"bundleId":"com.apple.TextEdit","grantId":"forged"})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<ClipboardArgs>(json!({"action":"read","grantId":"forged"}))
                .is_err()
        );
    }

    #[test]
    fn screenshot_bytes_appear_only_in_the_mcp_image_block() {
        let response = serde_json::from_value(json!({
            "version": 1, "id": "r", "epoch": "e",
            "body": { "result": "observe", "data": {
                "observationId": "obs-e-1", "target": { "pid": 1, "windowId": 1 },
                "collected": { "startedUnixMs": 1, "finishedUnixMs": 2 },
                "windowBounds": { "x": -5, "y": 0, "width": 2, "height": 3 },
                "accessibility": "unavailable", "elements": [],
                "screenshot": {
                    "mimeType": "png", "widthPx": 2, "heightPx": 3, "dataBase64": "AQID",
                    "imageToScreen": {
                        "scaleX": 1, "scaleY": 1, "offsetX": -5, "offsetY": 0,
                        "validImageBounds": { "x": 0, "y": 0, "width": 2, "height": 3 },
                        "coverage": "complete"
                    },
                    "collected": { "startedUnixMs": 1, "finishedUnixMs": 2 }
                }
            }}
        }))
        .unwrap();

        let receipt = serde_json::to_value(native_receipt(response, false).unwrap()).unwrap();
        assert_eq!(
            receipt["content"][1],
            json!({"type":"image","mimeType":"image/png","data":"AQID"})
        );
        assert_eq!(
            receipt["structuredContent"]["body"]["data"]["screenshot"]["widthPx"],
            2
        );
        assert!(
            !receipt["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("AQID")
        );
        assert_eq!(receipt.to_string().matches("AQID").count(), 1);
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
                    include_values: false,
                    include_ocr: false,
                    ocr_query: None,
                    crop_window: None,
                    max_image_dimension_px: None,
                    ax_selectors: None,
                    event_history: None,
                    scope: None,
                    interactive_only: false,
                    query: None,
                }),
                5000
            )
            .is_err()
        );
        assert!(
            validate_public(
                &RequestBody::Open(OpenRequest {
                    grant_id: String::new(),
                    bundle_id: None,
                    app_name: None,
                    url: None,
                    new_instance: false,
                    activate: false,
                    observe: None,
                }),
                5000
            )
            .is_err()
        );
        assert!(
            validate_public(
                &RequestBody::Clipboard(ClipboardRequest {
                    grant_id: String::new(),
                    action: ClipboardAction::Write,
                    include_text: false,
                    text: None,
                    file_path: None,
                    image_path: None,
                }),
                5000
            )
            .is_err()
        );
    }

    #[test]
    fn compact_formatter_shrinks_observation_and_deduplicates_static_text() {
        let mut elements = Vec::new();
        for i in 1..=120 {
            elements.push(json!({
                "reference": format!("e1.{}", i * 2 - 1),
                "role": "AXLink",
                "label": format!("Startup {i}"),
                "value": null,
                "bounds": { "x": 10.0, "y": (i * 20) as f64, "width": 200.0, "height": 18.0 },
                "enabled": true,
                "actions": ["press", "scrollToVisible", "showMenu"],
                "identifier": null,
                "subrole": null,
                "url": format!("https://startuplist.africa/startups/s-{i}")
            }));
            elements.push(json!({
                "reference": format!("e1.{}", i * 2),
                "role": "AXStaticText",
                "label": null,
                "value": format!("Startup {i}"),
                "bounds": { "x": 10.0, "y": (i * 20) as f64, "width": 200.0, "height": 18.0 },
                "enabled": true,
                "actions": ["scrollToVisible", "showMenu"],
                "identifier": null,
                "subrole": null
            }));
        }
        let response: Response = serde_json::from_value(json!({
            "version": 1, "id": "r-compact", "epoch": "ep",
            "body": { "result": "observe", "data": {
                "observationId": "obs-1",
                "target": { "pid": 100, "windowId": 200 },
                "collected": { "startedUnixMs": 1000, "finishedUnixMs": 1250 },
                "windowBounds": { "x": 0, "y": 0, "width": 1200, "height": 800 },
                "accessibility": "partial",
                "accessibilityCollected": { "startedUnixMs": 1000, "finishedUnixMs": 1250 },
                "elements": elements,
                "screenshot": null
            }}
        }))
        .unwrap();
        let raw_json_len = serde_json::to_string(&response).unwrap().len();
        let receipt = native_receipt(response, false).unwrap();
        let text = receipt.content[0].as_text().unwrap().text.as_str();
        // Compact output omits bounds, null keys, redundant AXStaticText duplicates, and showMenu noise.
        assert!(
            text.len() * 4 < raw_json_len,
            "expected >=4x compression, got compact={} vs raw={}",
            text.len(),
            raw_json_len
        );
        assert!(
            text.contains("[e1.1] Link \"Startup 1\" url=https://startuplist.africa/startups/s-1")
        );
        assert!(
            !text.contains("[e1.2] StaticText"),
            "redundant child StaticText should be deduplicated"
        );
        assert!(
            receipt.structured_content.is_some(),
            "lossless structuredContent must be preserved"
        );
    }

    #[test]
    fn browser_args_and_compact_browser_formatting_work() {
        let parsed: BrowserArgs = serde_json::from_value(json!({
            "action": "act",
            "tabId": 7,
            "snapshotId": "snap-1",
            "steps": [
                { "kind": "click", "ref": "b1.3" },
                { "kind": "waitFor", "urlContains": "country=nigeria" }
            ],
            "returnSnapshot": true,
            "includeText": true
        }))
        .unwrap();
        assert!(matches!(parsed.action, BrowserAction::Act));
        assert_eq!(parsed.steps.unwrap().len(), 2);

        let formatted = compact::format_browser_result(
            "batchRead",
            &json!({
                "elapsedMs": 1420,
                "pages": [
                    { "ok": true, "url": "https://a.test", "finalUrl": "https://a.test", "title": "OPay", "text": "Fintech in Nigeria", "elapsedMs": 620 }
                ]
            }),
        );
        assert!(formatted.contains("batchRead pages=1 ms=1420"));
        assert!(formatted.contains("OPay"));
        assert!(formatted.contains("Fintech in Nigeria"));
    }
}
