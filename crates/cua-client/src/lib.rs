//! Persistent native-process client. It does not implement MCP or native UI input.
mod coordinator;
mod process;

use cua_protocol::{
    Authority, Delivery, Frame, MAX_BUDGET_MS, Request, RequestBody, Response, StepReceipt,
    VERSION, Verification,
};
use serde::Serialize;
use std::{
    collections::VecDeque,
    ffi::OsString,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone)]
pub struct Config {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub authority: Authority,
    pub handshake_budget: Duration,
}
impl Config {
    pub fn new(program: impl Into<PathBuf>, authority: Authority) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            authority,
            handshake_budget: Duration::from_secs(5),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientErrorKind {
    InvalidConfig,
    SpawnFailed,
    HandshakeFailed,
    InvalidRequest,
    ForbiddenControl,
    DeadlineExceeded,
    Cancelled,
    HelperDied,
    ProtocolError,
    Closed,
}
impl ClientErrorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidConfig => "invalid_config",
            Self::SpawnFailed => "spawn_failed",
            Self::HandshakeFailed => "handshake_failed",
            Self::InvalidRequest => "invalid_request",
            Self::ForbiddenControl => "forbidden_control",
            Self::DeadlineExceeded => "deadline_exceeded",
            Self::Cancelled => "cancelled",
            Self::HelperDied => "helper_died",
            Self::ProtocolError => "protocol_error",
            Self::Closed => "closed",
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct UncertainAct {
    pub observation_id: String,
    pub settled_steps: Vec<StepReceipt>,
    pub unacknowledged_action_ids: Vec<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct ClientError {
    pub kind: ClientErrorKind,
    pub message: &'static str,
    pub uncertainty: Option<UncertainAct>,
}
impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.kind.as_str(), self.message)
    }
}
impl std::error::Error for ClientError {}

impl ClientError {
    pub(crate) fn new(kind: ClientErrorKind, message: &'static str) -> Self {
        Self {
            kind,
            message,
            uncertainty: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Trace {
    pub request_id: String,
    pub route: &'static str,
    pub elapsed_ms: f64,
    pub outcome: &'static str,
    pub delivery: Option<Delivery>,
    pub verification: Option<Verification>,
}
#[derive(Debug, Clone, Serialize)]
pub struct HelperExit {
    pub success: bool,
    pub code: Option<i32>,
}
#[derive(Debug, Clone, Serialize)]
pub struct Diagnostics {
    pub stderr_bytes: u64,
    pub traces: Vec<Trace>,
    pub helper_exit: Option<HelperExit>,
}
pub(crate) struct Shared {
    stderr_bytes: Arc<AtomicU64>,
    closed: AtomicBool,
    traces: Mutex<VecDeque<Trace>>,
    helper_exit: Mutex<Option<HelperExit>>,
}
impl Shared {
    pub(crate) fn record(
        &self,
        request: &Request,
        started: Instant,
        result: &Result<Response, ClientError>,
    ) {
        let route = match request.body {
            RequestBody::Hello(_) => "hello",
            RequestBody::Capabilities(_) => "capabilities",
            RequestBody::Targets(_) => "targets",
            RequestBody::Observe(_) => "observe",
            RequestBody::Act(_) => "act",
            RequestBody::WaitFor(_) => "waitFor",
            RequestBody::Cancel(_) => "cancel",
        };
        let (outcome, delivery, verification) = match result {
            Ok(Response {
                body: cua_protocol::ResponseBody::Act(result),
                ..
            }) => (
                match result.stop_reason {
                    cua_protocol::StopReason::Completed => "completed",
                    cua_protocol::StopReason::DeadlineExceeded => "deadline_exceeded",
                    cua_protocol::StopReason::Cancelled => "cancelled",
                    cua_protocol::StopReason::HelperDied => "helper_died",
                    _ => "stopped",
                },
                result.steps.last().map(|s| s.delivery),
                result.steps.last().map(|s| s.verification),
            ),
            Ok(Response {
                body: cua_protocol::ResponseBody::Error(_),
                ..
            }) => ("rejected", None, None),
            Ok(_) => ("completed", None, None),
            Err(error) => (error.kind.as_str(), None, None),
        };
        let mut traces = self.traces.lock().expect("trace mutex");
        if traces.len() == 64 {
            traces.pop_front();
        }
        traces.push_back(Trace {
            request_id: request.id.clone(),
            route,
            elapsed_ms: started.elapsed().as_secs_f64() * 1000.0,
            outcome,
            delivery,
            verification,
        });
    }
}

const QUEUED: u8 = 0;
const ACTIVE: u8 = 1;
const WITHDRAWN: u8 = 2;

pub(crate) struct Call {
    request: Request,
    deadline: Instant,
    started: Instant,
    cancel: CancellationToken,
    admission: Arc<AtomicU8>,
    reply: oneshot::Sender<Result<Response, ClientError>>,
}

struct CallGuard {
    cancel: CancellationToken,
    admission: Arc<AtomicU8>,
}
impl Drop for CallGuard {
    fn drop(&mut self) {
        let _ =
            self.admission
                .compare_exchange(QUEUED, WITHDRAWN, Ordering::SeqCst, Ordering::SeqCst);
        self.cancel.cancel();
    }
}

pub struct Client {
    commands: mpsc::Sender<Call>,
    stop: CancellationToken,
    worker: Mutex<Option<JoinHandle<()>>>,
    epoch: String,
    pid: u32,
    authority: Authority,
    ids: Arc<AtomicU64>,
    shared: Arc<Shared>,
}
impl Client {
    pub async fn spawn(config: Config) -> Result<Self, ClientError> {
        Self::spawn_with_cancellation(config, CancellationToken::new()).await
    }

    /// Cancellation during startup waits for the child to be killed and reaped before returning.
    pub async fn spawn_with_cancellation(
        config: Config,
        cancel: CancellationToken,
    ) -> Result<Self, ClientError> {
        if !valid_budget(config.handshake_budget) {
            return Err(ClientError::new(
                ClientErrorKind::InvalidConfig,
                "invalid handshake budget",
            ));
        }
        if cancel.is_cancelled() {
            return Err(ClientError::new(
                ClientErrorKind::Cancelled,
                "native startup cancelled",
            ));
        }
        let shared = Arc::new(Shared {
            stderr_bytes: Arc::new(AtomicU64::new(0)),
            closed: AtomicBool::new(false),
            traces: Mutex::new(VecDeque::new()),
            helper_exit: Mutex::new(None),
        });
        let mut transport = process::Transport::spawn(&config, shared.stderr_bytes.clone())?;
        let pid = transport.pid();
        let handshake = tokio::select! { biased;
            _ = cancel.cancelled() => {
                transport.stop();
                Err(ClientError::new(ClientErrorKind::Cancelled, "native startup cancelled"))
            }
            result = coordinator::handshake(&mut transport, &config) => result,
        };
        let epoch = match handshake {
            Ok(epoch) => epoch,
            Err(error) => {
                let _ = transport.shutdown().await;
                return Err(error);
            }
        };
        let (commands, receiver) = mpsc::channel(8);
        let stop = CancellationToken::new();
        let ids = Arc::new(AtomicU64::new(2));
        let worker = tokio::spawn(coordinator::run(
            transport,
            receiver,
            stop.clone(),
            shared.clone(),
            config.authority.clone(),
            ids.clone(),
        ));
        Ok(Self {
            commands,
            stop,
            worker: Mutex::new(Some(worker)),
            epoch,
            pid,
            authority: config.authority,
            ids,
            shared,
        })
    }

    pub async fn call(
        &self,
        mut body: RequestBody,
        budget: Duration,
        cancel: CancellationToken,
    ) -> Result<Response, ClientError> {
        if matches!(body, RequestBody::Hello(_) | RequestBody::Cancel(_)) {
            return Err(ClientError::new(
                ClientErrorKind::ForbiddenControl,
                "session control belongs to the host",
            ));
        }
        if !valid_budget(budget) {
            return Err(ClientError::new(
                ClientErrorKind::InvalidRequest,
                "invalid request budget",
            ));
        }
        if let RequestBody::Act(act) = &mut body {
            if act.foreground
                && self.authority.mode != cua_protocol::ExecutionMode::ForegroundAllowed
            {
                return Err(ClientError::new(
                    ClientErrorKind::ForbiddenControl,
                    "operator foreground authority is required",
                ));
            }
            act.grant_id = self.authority.grant_id.clone();
        }
        let started = Instant::now();
        let deadline = started + budget;
        let request = Request {
            version: VERSION,
            id: next_id(&self.ids),
            epoch: Some(self.epoch.clone()),
            budget_ms: budget.as_millis() as u32,
            body,
        };
        cua_protocol::encode_line(&Frame::Request(request.clone())).map_err(|_| {
            ClientError::new(
                ClientErrorKind::InvalidRequest,
                "request violates native contract",
            )
        })?;
        let cancel = cancel.child_token();
        let admission = Arc::new(AtomicU8::new(QUEUED));
        let _guard = CallGuard {
            cancel: cancel.clone(),
            admission: admission.clone(),
        };
        let (reply, mut result) = oneshot::channel();
        let permit = tokio::select! { biased;
            _ = self.stop.cancelled() => return Err(ClientError::new(ClientErrorKind::Closed, "native connection closed")),
            _ = cancel.cancelled() => return self.withdrawn(&request, started, ClientErrorKind::Cancelled),
            _ = tokio::time::sleep_until(deadline) => return self.withdrawn(&request, started, ClientErrorKind::DeadlineExceeded),
            permit = self.commands.reserve() => permit.map_err(|_| ClientError::new(ClientErrorKind::Closed, "native connection closed"))?,
        };
        permit.send(Call {
            request: request.clone(),
            deadline,
            started,
            cancel: cancel.clone(),
            admission: admission.clone(),
            reply,
        });
        let waiting = tokio::select! { biased;
            output = &mut result => return output.unwrap_or_else(|_| Err(coordinator::lost_coordinator(&request))),
            _ = self.stop.cancelled() => ClientErrorKind::Closed,
            _ = cancel.cancelled() => ClientErrorKind::Cancelled,
            _ = tokio::time::sleep_until(deadline) => ClientErrorKind::DeadlineExceeded,
        };
        if admission
            .compare_exchange(QUEUED, WITHDRAWN, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            return self.withdrawn(&request, started, waiting);
        }
        if waiting == ClientErrorKind::Cancelled {
            cancel.cancel();
        }
        result
            .await
            .unwrap_or_else(|_| Err(coordinator::lost_coordinator(&request)))
    }

    fn withdrawn(
        &self,
        request: &Request,
        started: Instant,
        kind: ClientErrorKind,
    ) -> Result<Response, ClientError> {
        let result = coordinator::interrupted(request, &[], kind, false);
        self.shared.record(request, started, &result);
        result
    }

    pub async fn shutdown(&self) {
        self.stop.cancel();
        let worker = self.worker.lock().expect("worker mutex").take();
        if let Some(worker) = worker {
            let _ = worker.await;
        }
    }
    pub fn execution_mode(&self) -> cua_protocol::ExecutionMode {
        self.authority.mode
    }
    pub fn epoch(&self) -> &str {
        &self.epoch
    }
    pub fn helper_pid(&self) -> u32 {
        self.pid
    }
    pub fn diagnostics(&self) -> Diagnostics {
        Diagnostics {
            stderr_bytes: self.shared.stderr_bytes.load(Ordering::Relaxed),
            traces: self
                .shared
                .traces
                .lock()
                .expect("trace mutex")
                .iter()
                .cloned()
                .collect(),
            helper_exit: self.shared.helper_exit.lock().expect("exit mutex").clone(),
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

pub(crate) fn next_id(ids: &AtomicU64) -> String {
    format!("host-{}", ids.fetch_add(1, Ordering::Relaxed))
}
fn valid_budget(budget: Duration) -> bool {
    budget >= Duration::from_millis(1) && budget <= Duration::from_millis(u64::from(MAX_BUDGET_MS))
}
