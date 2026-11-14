//! Internal Rust–Swift wire contract. This crate neither executes input nor grants authority.
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};

pub const VERSION: u16 = 1;
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_STEPS: usize = 16;
pub const MAX_ELEMENTS: usize = 256;
pub const MAX_TARGETS: usize = 256;
pub const MAX_RETAINED_OBSERVATIONS: usize = 32;
pub const OBSERVATION_TTL_MS: u32 = 60_000;
pub const MAX_BUDGET_MS: u32 = 60_000;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

macro_rules! record {
    ($name:ident { $($field:ident: $ty:ty),* $(,)? }) => {
        #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
        #[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        pub struct $name { $(pub $field: $ty),* }
    };
}
macro_rules! choices {
    ($name:ident { $($variant:ident),* $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
        #[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
        #[serde(rename_all = "camelCase")]
        pub enum $name { $($variant),* }
    };
}

choices!(ExecutionMode {
    BackgroundRequired,
    ForegroundAllowed
});
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum Delivery {
    NotDispatched,
    Dispatched,
    Unknown,
}
choices!(Verification {
    Confirmed,
    Mismatch,
    Unverified
});
choices!(DeliveryRoute {
    AxSetValue,
    AxSelectedText,
    AxPress
});
choices!(Coverage {
    Complete,
    Partial,
    Unavailable
});
choices!(MimeType { Png, Jpeg });
choices!(CoordinateSpace {
    ScreenPoints,
    WindowPoints,
    ImagePixels
});
choices!(Axis {
    Vertical,
    Horizontal
});
choices!(Key {
    Return,
    Tab,
    Escape,
    Backspace,
    Left,
    Right,
    Up,
    Down
});
choices!(ElementAction {
    Press,
    SetValue,
    TypeText,
    Key,
    Scroll
});
choices!(ActionKind {
    Press,
    SetValue,
    TypeText,
    Key,
    Scroll,
    Click
});
choices!(StopReason {
    Completed,
    PreconditionFailed,
    VerificationFailed,
    Cancelled,
    DeadlineExceeded,
    HelperDied,
    TargetStale,
    AmbiguousTarget,
    Unsupported,
    Failed
});
choices!(ReceiptReason {
    AlreadySatisfied,
    PreconditionFailed,
    VerificationFailed,
    Cancelled,
    DeadlineExceeded,
    HelperDied,
    TargetStale,
    AmbiguousTarget,
    Unsupported,
    NativeFailed
});
choices!(ErrorCode {
    InvalidRequest,
    UnsupportedVersion,
    StaleEpoch,
    PermissionDenied,
    AuthorityDenied,
    TargetNotFound,
    AmbiguousTarget,
    StaleObservation,
    StaleElement,
    Unsupported,
    NativeFailed,
    DeadlineExceeded,
    Cancelled,
    ResourceLimit
});
choices!(WaitOutcome {
    Satisfied,
    TimedOut,
    Cancelled
});
choices!(CancelStatus {
    Requested,
    NotFound,
    AlreadyFinished
});

record!(Authority {
    grant_id: String,
    mode: ExecutionMode
});
record!(HelloRequest { client_name: String, supported_versions: Vec<u16>, authority: Authority });
record!(HelloResult {
    helper_version: String,
    selected_version: u16
});
record!(Empty {});
record!(Permissions {
    accessibility: bool,
    screen_recording: bool,
    input_posting: bool
});
record!(Capabilities { permissions: Permissions, mode: ExecutionMode, actions: Vec<ActionKind> });
record!(TargetKey {
    pid: u32,
    window_id: u32
});
record!(Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64
});
record!(Point { x: f64, y: f64 });
record!(Target {
    key: TargetKey,
    bundle_id: String,
    title: String,
    bounds: Rect
});
record!(TargetsRequest { bundle_id: Option<String> });
record!(TargetsResult { targets: Vec<Target>, truncated: bool });
record!(CollectionInterval {
    started_unix_ms: u64,
    finished_unix_ms: u64
});
record!(ImageTransform {
    scale_x: f64,
    scale_y: f64,
    offset_x: f64,
    offset_y: f64,
    valid_image_bounds: Rect,
    coverage: Coverage
});
record!(Screenshot {
    mime_type: MimeType,
    width_px: u32,
    height_px: u32,
    data_base64: String,
    image_to_screen: ImageTransform,
    collected: CollectionInterval
});
record!(Element {
    reference: String, role: String, label: Option<String>, value: Option<String>,
    bounds: Rect, enabled: bool, actions: Vec<ElementAction>, identifier: Option<String>
});
record!(ObserveRequest {
    target: TargetKey,
    include_screenshot: bool,
    include_values: bool
});
record!(Observation {
    observation_id: String, target: TargetKey, collected: CollectionInterval,
    window_bounds: Rect, accessibility: Coverage, accessibility_collected: Option<CollectionInterval>, elements: Vec<Element>,
    screenshot: Option<Screenshot>
});
record!(Selector { role: String, label: Option<String>, identifier: Option<String> });
record!(ElementCondition { selector: Selector });
record!(ValueCondition {
    element_ref: String,
    value: String
});
record!(EnabledCondition {
    element_ref: String,
    enabled: bool
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(
    tag = "kind",
    content = "params",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Condition {
    ElementExists(ElementCondition),
    ElementAbsent(ElementCondition),
    ValueEquals(ValueCondition),
    Enabled(EnabledCondition),
}
record!(ElementOperation {
    element_ref: String
});
record!(SetValueOperation {
    element_ref: String,
    value: String
});
record!(TypeTextOperation {
    element_ref: String,
    text: String
});
record!(KeyOperation {
    element_ref: String,
    key: Key
});
record!(ScrollOperation {
    element_ref: String,
    axis: Axis,
    amount: i32
});
record!(ClickOperation {
    point: Point,
    space: CoordinateSpace
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(
    tag = "kind",
    content = "params",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Operation {
    Press(ElementOperation),
    SetValue(SetValueOperation),
    TypeText(TypeTextOperation),
    Key(KeyOperation),
    Scroll(ScrollOperation),
    Click(ClickOperation),
}
record!(ActionStep {
    action_id: String, operation: Operation, precondition: Option<Condition>, expect: Option<Condition>
});
record!(ActRequest {
    grant_id: String, observation_id: String, target: TargetKey, steps: Vec<ActionStep>
});
record!(CheckEvidence {
    observation_id: String,
    condition: Condition,
    matched: bool
});
record!(StepReceipt {
    action_id: String, delivery: Delivery, verification: Verification,
    reason: Option<ReceiptReason>, evidence: Vec<CheckEvidence>, route: Option<DeliveryRoute>
});
record!(ActResult {
    observation_id: String, steps: Vec<StepReceipt>, remaining_steps: u16, stop_reason: StopReason
});
record!(WaitRequest {
    observation_id: String,
    target: TargetKey,
    condition: Condition
});
record!(WaitResult { outcome: WaitOutcome, already_satisfied: bool, observation: Option<Observation> });
record!(CancelRequest { request_id: String });
record!(CancelResult {
    request_id: String,
    status: CancelStatus
});
record!(Failure {
    code: ErrorCode,
    message: String
});

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(
    tag = "method",
    content = "params",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum RequestBody {
    Hello(HelloRequest),
    Capabilities(Empty),
    Targets(TargetsRequest),
    Observe(ObserveRequest),
    Act(ActRequest),
    WaitFor(WaitRequest),
    Cancel(CancelRequest),
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(
    tag = "result",
    content = "data",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum ResponseBody {
    Hello(HelloResult),
    Capabilities(Capabilities),
    Targets(TargetsResult),
    Observe(Observation),
    Act(ActResult),
    WaitFor(WaitResult),
    Cancel(CancelResult),
    Error(Failure),
}
record!(Request { version: u16, id: String, epoch: Option<String>, budget_ms: u32, body: RequestBody });
record!(Response {
    version: u16,
    id: String,
    epoch: String,
    body: ResponseBody
});
record!(Progress {
    version: u16, id: String, epoch: String, observation_id: String, steps: Vec<StepReceipt>
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(
    tag = "kind",
    content = "message",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Frame {
    Request(Request),
    Response(Response),
    Progress(Progress),
}

/// Installed by the trusted host handshake, never copied from public tool arguments.
pub struct SessionContext {
    pub epoch: String,
    pub authority: Authority,
}
impl SessionContext {
    pub fn authorize(&self, request: &Request) -> Result<(), String> {
        Frame::Request(request.clone()).validate()?;
        require(
            !matches!(request.body, RequestBody::Hello(_)),
            "session already initialized",
        )?;
        require(
            request.epoch.as_deref() == Some(self.epoch.as_str()),
            "stale helper epoch",
        )?;
        if let RequestBody::Act(act) = &request.body {
            require(
                act.grant_id == self.authority.grant_id,
                "unknown host authority grant",
            )?;
        }
        Ok(())
    }
}

fn require(ok: bool, message: &str) -> Result<(), String> {
    if ok { Ok(()) } else { Err(message.into()) }
}
fn id(value: &str) -> Result<(), String> {
    require(
        !value.trim().is_empty() && value.len() <= 128,
        "invalid identifier",
    )
}
fn target(value: &TargetKey) -> Result<(), String> {
    require(
        value.pid > 0 && value.window_id > 0,
        "target IDs must be positive",
    )
}
fn rect(value: &Rect) -> Result<(), String> {
    require(
        [value.x, value.y, value.width, value.height]
            .iter()
            .all(|v| v.is_finite())
            && value.width > 0.0
            && value.height > 0.0
            && (value.x + value.width).is_finite()
            && (value.y + value.height).is_finite(),
        "invalid rectangle",
    )
}
fn interval(value: &CollectionInterval) -> Result<(), String> {
    require(
        value.started_unix_ms <= value.finished_unix_ms
            && value.finished_unix_ms <= MAX_SAFE_INTEGER,
        "invalid collection interval",
    )
}
fn channel_interval(
    channel: &CollectionInterval,
    total: &CollectionInterval,
) -> Result<(), String> {
    interval(channel)?;
    require(
        channel.started_unix_ms >= total.started_unix_ms
            && channel.finished_unix_ms <= total.finished_unix_ms,
        "channel interval outside observation",
    )
}
fn expectation(step: &ActionStep, receipt: &StepReceipt, settled: bool) -> Result<(), String> {
    if let Some(route) = receipt.route {
        require(
            matches!(
                (&step.operation, route),
                (Operation::SetValue(_), DeliveryRoute::AxSetValue)
                    | (Operation::TypeText(_), DeliveryRoute::AxSelectedText)
                    | (Operation::Press(_), DeliveryRoute::AxPress)
            ),
            "receipt route does not match operation",
        )?;
    }
    let mut required = Vec::new();
    if let Operation::SetValue(value) = &step.operation {
        required.push(Condition::ValueEquals(ValueCondition {
            element_ref: value.element_ref.clone(),
            value: value.value.clone(),
        }));
    }
    if let Some(expected) = &step.expect
        && !required.contains(expected)
    {
        required.push(expected.clone());
    }
    if !required.is_empty() {
        let matches = |condition: &Condition, matched| {
            receipt
                .evidence
                .iter()
                .any(|e| e.condition == *condition && e.matched == matched)
        };
        match receipt.verification {
            Verification::Confirmed => require(
                required.iter().all(|condition| matches(condition, true)),
                "confirmation does not match requested expectation",
            )?,
            Verification::Mismatch => require(
                required.iter().any(|condition| matches(condition, false)),
                "mismatch does not match requested expectation",
            )?,
            Verification::Unverified => {
                require(!settled, "settled step has unverified required expectation")?
            }
        }
    } else {
        require(
            receipt.reason != Some(ReceiptReason::AlreadySatisfied),
            "alreadySatisfied requires an expectation",
        )?;
    }
    Ok(())
}
fn unique<'a>(values: impl Iterator<Item = &'a str>) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    for value in values {
        id(value)?;
        require(seen.insert(value), "duplicate identifier")?;
    }
    Ok(())
}
impl Condition {
    fn validate(&self) -> Result<(), String> {
        match self {
            Self::ElementExists(v) | Self::ElementAbsent(v) => id(&v.selector.role),
            Self::ValueEquals(v) => id(&v.element_ref),
            Self::Enabled(v) => id(&v.element_ref),
        }
    }
}
impl ImageTransform {
    /// A missing or out-of-domain mapping must not be guessed from display scaling.
    pub fn to_screen(&self, point: &Point) -> Result<Point, String> {
        let r = &self.valid_image_bounds;
        rect(r)?;
        require(
            [self.scale_x, self.scale_y, self.offset_x, self.offset_y]
                .iter()
                .all(|v| v.is_finite())
                && self.scale_x > 0.0
                && self.scale_y > 0.0,
            "invalid image transform",
        )?;
        require(
            self.coverage != Coverage::Unavailable
                && point.x.is_finite()
                && point.y.is_finite()
                && point.x >= r.x
                && point.y >= r.y
                && point.x < r.x + r.width
                && point.y < r.y + r.height,
            "point outside valid image transform",
        )?;
        let mapped = Point {
            x: point.x * self.scale_x + self.offset_x,
            y: point.y * self.scale_y + self.offset_y,
        };
        require(
            mapped.x.is_finite() && mapped.y.is_finite(),
            "mapped point overflow",
        )?;
        Ok(mapped)
    }
}
impl Screenshot {
    fn validate(&self) -> Result<(), String> {
        interval(&self.collected)?;
        require(
            self.width_px > 0 && self.height_px > 0,
            "image dimensions must be positive",
        )?;
        let t = &self.image_to_screen;
        rect(&t.valid_image_bounds)?;
        require(
            [t.scale_x, t.scale_y, t.offset_x, t.offset_y]
                .iter()
                .all(|v| v.is_finite())
                && t.scale_x > 0.0
                && t.scale_y > 0.0
                && t.coverage != Coverage::Unavailable,
            "invalid image transform",
        )?;
        let r = &t.valid_image_bounds;
        require(
            r.x >= 0.0
                && r.y >= 0.0
                && r.x + r.width <= f64::from(self.width_px)
                && r.y + r.height <= f64::from(self.height_px),
            "transform domain outside image",
        )?;
        require(
            [
                r.x * t.scale_x + t.offset_x,
                (r.x + r.width) * t.scale_x + t.offset_x,
                r.y * t.scale_y + t.offset_y,
                (r.y + r.height) * t.scale_y + t.offset_y,
            ]
            .iter()
            .all(|v| v.is_finite()),
            "mapped rectangle overflow",
        )?;
        if t.coverage == Coverage::Complete {
            require(
                r.x == 0.0
                    && r.y == 0.0
                    && r.width == f64::from(self.width_px)
                    && r.height == f64::from(self.height_px),
                "complete transform must cover image",
            )?;
        }
        require(
            !self.data_base64.is_empty()
                && self.data_base64.len() <= MAX_IMAGE_BYTES.div_ceil(3) * 4,
            "image exceeds payload limit",
        )?;
        let bytes = STANDARD
            .decode(&self.data_base64)
            .map_err(|_| "invalid image base64")?;
        require(
            !bytes.is_empty() && bytes.len() <= MAX_IMAGE_BYTES,
            "image exceeds payload limit",
        )
    }
}
impl Observation {
    fn validate(&self) -> Result<(), String> {
        id(&self.observation_id)?;
        target(&self.target)?;
        rect(&self.window_bounds)?;
        interval(&self.collected)?;
        require(
            self.accessibility == Coverage::Unavailable || self.accessibility_collected.is_some(),
            "available accessibility requires collection interval",
        )?;
        if let Some(ax) = &self.accessibility_collected {
            channel_interval(ax, &self.collected)?;
        }
        require(self.elements.len() <= MAX_ELEMENTS, "too many elements")?;
        unique(self.elements.iter().map(|v| v.reference.as_str()))?;
        require(
            self.accessibility != Coverage::Unavailable || self.elements.is_empty(),
            "unavailable accessibility cannot include elements",
        )?;
        for element in &self.elements {
            id(&element.role)?;
            rect(&element.bounds)?;
        }
        if let Some(screenshot) = &self.screenshot {
            screenshot.validate()?;
            channel_interval(&screenshot.collected, &self.collected)?;
        }
        Ok(())
    }
}
impl ActRequest {
    fn validate(&self) -> Result<(), String> {
        id(&self.grant_id)?;
        id(&self.observation_id)?;
        target(&self.target)?;
        require(
            !self.steps.is_empty() && self.steps.len() <= MAX_STEPS,
            "invalid action count",
        )?;
        unique(self.steps.iter().map(|v| v.action_id.as_str()))?;
        for step in &self.steps {
            match &step.operation {
                Operation::Press(v) => id(&v.element_ref)?,
                Operation::SetValue(v) => id(&v.element_ref)?,
                Operation::TypeText(v) => {
                    id(&v.element_ref)?;
                    require(!v.text.is_empty(), "empty typing")?;
                }
                Operation::Key(v) => id(&v.element_ref)?,
                Operation::Scroll(v) => {
                    id(&v.element_ref)?;
                    require(
                        v.amount != 0 && (-1000..=1000).contains(&v.amount),
                        "invalid scroll amount",
                    )?;
                }
                Operation::Click(v) => require(
                    v.point.x.is_finite() && v.point.y.is_finite(),
                    "invalid point",
                )?,
            }
            if let Some(c) = &step.precondition {
                c.validate()?;
            }
            if let Some(c) = &step.expect {
                c.validate()?;
            }
        }
        Ok(())
    }
}
impl ActResult {
    fn validate(&self) -> Result<(), String> {
        id(&self.observation_id)?;
        require(
            !self.steps.is_empty()
                && self.steps.len() + usize::from(self.remaining_steps) <= MAX_STEPS,
            "invalid receipt prefix",
        )?;
        unique(self.steps.iter().map(|v| v.action_id.as_str()))?;
        for (index, step) in self.steps.iter().enumerate() {
            for evidence in &step.evidence {
                id(&evidence.observation_id)?;
                evidence.condition.validate()?;
            }
            match step.verification {
                Verification::Confirmed => require(
                    !step.evidence.is_empty() && step.evidence.iter().all(|v| v.matched),
                    "confirmation needs evidence",
                )?,
                Verification::Mismatch => require(
                    step.evidence.iter().any(|v| !v.matched),
                    "mismatch needs evidence",
                )?,
                Verification::Unverified => (),
            }
            if step.reason == Some(ReceiptReason::AlreadySatisfied) {
                require(
                    step.delivery == Delivery::NotDispatched
                        && step.verification == Verification::Confirmed,
                    "alreadySatisfied requires confirmed evidence without dispatch",
                )?;
            }
            if step.delivery == Delivery::NotDispatched
                && step.reason != Some(ReceiptReason::AlreadySatisfied)
            {
                require(
                    index + 1 == self.steps.len()
                        && step.reason.is_some()
                        && self.stop_reason != StopReason::Completed,
                    "rejected step must stop sequence",
                )?;
            }
            if let Some(reason) = step
                .reason
                .filter(|r| *r != ReceiptReason::AlreadySatisfied)
            {
                let expected = match reason {
                    ReceiptReason::PreconditionFailed => StopReason::PreconditionFailed,
                    ReceiptReason::VerificationFailed => StopReason::VerificationFailed,
                    ReceiptReason::Cancelled => StopReason::Cancelled,
                    ReceiptReason::DeadlineExceeded => StopReason::DeadlineExceeded,
                    ReceiptReason::HelperDied => StopReason::HelperDied,
                    ReceiptReason::TargetStale => StopReason::TargetStale,
                    ReceiptReason::AmbiguousTarget => StopReason::AmbiguousTarget,
                    ReceiptReason::Unsupported => StopReason::Unsupported,
                    ReceiptReason::NativeFailed => StopReason::Failed,
                    ReceiptReason::AlreadySatisfied => unreachable!(),
                };
                require(
                    index + 1 == self.steps.len() && self.stop_reason == expected,
                    "failed step must be terminal with matching stop reason",
                )?;
            }
            if step.delivery == Delivery::Unknown {
                require(
                    index + 1 == self.steps.len() && self.stop_reason != StopReason::Completed,
                    "unknown dispatch must stop sequence",
                )?;
            }
            if step.verification == Verification::Mismatch {
                require(
                    index + 1 == self.steps.len() && self.stop_reason != StopReason::Completed,
                    "verification mismatch must stop sequence",
                )?;
            }
        }
        if self.stop_reason == StopReason::Completed {
            require(
                self.remaining_steps == 0
                    && self.steps.iter().all(|v| {
                        v.delivery == Delivery::Dispatched
                            || v.reason == Some(ReceiptReason::AlreadySatisfied)
                    }),
                "completed sequence cannot include rejected steps",
            )?;
        }
        Ok(())
    }
}
impl Frame {
    pub fn validate(&self) -> Result<(), String> {
        match self {
            Self::Progress(progress) => {
                require(progress.version == VERSION, "unsupported envelope version")?;
                id(&progress.id)?;
                id(&progress.epoch)?;
                ActResult {
                    observation_id: progress.observation_id.clone(),
                    steps: progress.steps.clone(),
                    remaining_steps: 0,
                    stop_reason: StopReason::Completed,
                }
                .validate()?;
            }
            Self::Request(request) => {
                require(request.version == VERSION, "unsupported envelope version")?;
                id(&request.id)?;
                require(
                    request.budget_ms > 0 && request.budget_ms <= MAX_BUDGET_MS,
                    "invalid deadline budget",
                )?;
                if let RequestBody::Hello(hello) = &request.body {
                    require(request.epoch.is_none(), "hello must not reuse an epoch")?;
                    id(&hello.client_name)?;
                    id(&hello.authority.grant_id)?;
                    require(
                        hello.supported_versions.contains(&VERSION),
                        "no compatible protocol version",
                    )?;
                } else {
                    id(request.epoch.as_deref().ok_or("epoch required")?)?;
                }
                match &request.body {
                    RequestBody::Observe(v) => target(&v.target)?,
                    RequestBody::Act(v) => v.validate()?,
                    RequestBody::WaitFor(v) => {
                        id(&v.observation_id)?;
                        target(&v.target)?;
                        v.condition.validate()?;
                    }
                    RequestBody::Cancel(v) => {
                        id(&v.request_id)?;
                        require(v.request_id != request.id, "cancel cannot target itself")?;
                    }
                    _ => (),
                }
            }
            Self::Response(response) => {
                require(response.version == VERSION, "unsupported envelope version")?;
                id(&response.id)?;
                id(&response.epoch)?;
                match &response.body {
                    ResponseBody::Hello(v) => {
                        id(&v.helper_version)?;
                        require(
                            v.selected_version == VERSION,
                            "unsupported selected version",
                        )?;
                    }
                    ResponseBody::Targets(v) => {
                        require(v.targets.len() <= MAX_TARGETS, "too many targets")?;
                        for t in &v.targets {
                            target(&t.key)?;
                            id(&t.bundle_id)?;
                            rect(&t.bounds)?;
                        }
                    }
                    ResponseBody::Observe(v) => v.validate()?,
                    ResponseBody::Act(v) => v.validate()?,
                    ResponseBody::WaitFor(v) => {
                        require(
                            !v.already_satisfied || v.outcome == WaitOutcome::Satisfied,
                            "invalid alreadySatisfied wait",
                        )?;
                        require(
                            v.outcome != WaitOutcome::Satisfied || v.observation.is_some(),
                            "satisfied wait needs observation",
                        )?;
                        if let Some(o) = &v.observation {
                            o.validate()?;
                        }
                    }
                    ResponseBody::Cancel(v) => id(&v.request_id)?,
                    ResponseBody::Error(v) => {
                        require(!v.message.is_empty(), "empty error message")?
                    }
                    ResponseBody::Capabilities(_) => (),
                }
            }
        }
        Ok(())
    }
}

impl Progress {
    pub fn validate_for(&self, request: &Request, expected_epoch: &str) -> Result<(), String> {
        Frame::Request(request.clone()).validate()?;
        Frame::Progress(self.clone()).validate()?;
        require(
            self.id == request.id
                && self.epoch == expected_epoch
                && request.epoch.as_deref() == Some(expected_epoch),
            "progress correlation mismatch",
        )?;
        let RequestBody::Act(act) = &request.body else {
            return Err("progress requires act request".into());
        };
        require(
            self.observation_id == act.observation_id,
            "progress observation provenance mismatch",
        )?;
        require(
            self.steps.len() <= act.steps.len()
                && self
                    .steps
                    .iter()
                    .zip(&act.steps)
                    .all(|(receipt, step)| receipt.action_id == step.action_id),
            "progress does not match requested action prefix",
        )?;
        for (receipt, step) in self.steps.iter().zip(&act.steps) {
            expectation(step, receipt, true)?;
        }
        Ok(())
    }
}

impl Response {
    /// Check a decoded reply against the pending request before consuming its evidence.
    pub fn validate_for(&self, request: &Request, expected_epoch: &str) -> Result<(), String> {
        Frame::Request(request.clone()).validate()?;
        Frame::Response(self.clone()).validate()?;
        require(self.id == request.id, "response request ID mismatch")?;
        require(
            self.epoch == expected_epoch,
            "response helper epoch mismatch",
        )?;
        if !matches!(request.body, RequestBody::Hello(_)) {
            require(
                request.epoch.as_deref() == Some(expected_epoch),
                "pending request epoch mismatch",
            )?;
        }
        match (&request.body, &self.body) {
            (_, ResponseBody::Error(_))
            | (RequestBody::Hello(_), ResponseBody::Hello(_))
            | (RequestBody::Capabilities(_), ResponseBody::Capabilities(_))
            | (RequestBody::Targets(_), ResponseBody::Targets(_)) => Ok(()),
            (RequestBody::Observe(request), ResponseBody::Observe(observation)) => {
                require(
                    request.target == observation.target,
                    "observation target mismatch",
                )?;
                require(
                    request.include_values
                        || observation.elements.iter().all(|e| e.value.is_none()),
                    "observation includes unrequested values",
                )?;
                require(
                    request.include_screenshot || observation.screenshot.is_none(),
                    "observation includes unrequested image",
                )
            }
            (RequestBody::Act(request), ResponseBody::Act(result)) => {
                require(
                    result.observation_id == request.observation_id,
                    "act observation provenance mismatch",
                )?;
                require(
                    result.steps.len() + usize::from(result.remaining_steps) == request.steps.len(),
                    "receipt prefix does not account for requested steps",
                )?;
                require(
                    result
                        .steps
                        .iter()
                        .zip(&request.steps)
                        .all(|(receipt, step)| receipt.action_id == step.action_id),
                    "receipt does not match requested action prefix",
                )?;
                for (index, (receipt, step)) in result.steps.iter().zip(&request.steps).enumerate()
                {
                    let settled = result.stop_reason == StopReason::Completed
                        || index + 1 < result.steps.len();
                    expectation(step, receipt, settled)?;
                }
                Ok(())
            }
            (RequestBody::WaitFor(request), ResponseBody::WaitFor(result)) => {
                if let Some(observation) = &result.observation {
                    require(
                        request.target == observation.target,
                        "wait observation target mismatch",
                    )?;
                    require(
                        observation.elements.iter().all(|e| e.value.is_none()),
                        "wait observation includes private values",
                    )?;
                }
                Ok(())
            }
            (RequestBody::Cancel(request), ResponseBody::Cancel(result)) => require(
                request.request_id == result.request_id,
                "cancel target mismatch",
            ),
            _ => Err("response method mismatch".into()),
        }
    }
}

/// Decode exactly one JSONL frame, excluding the optional final LF. Embedded newlines are rejected.
pub fn decode_line(bytes: &[u8]) -> Result<Frame, String> {
    require(bytes.len() <= MAX_FRAME_BYTES, "frame exceeds limit")?;
    let content = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    require(content.len() < MAX_FRAME_BYTES, "frame exceeds limit")?;
    require(
        !content.contains(&b'\n') && !content.contains(&b'\r'),
        "one JSON object per line required",
    )?;
    let frame: Frame = serde_json::from_slice(content).map_err(|error| error.to_string())?;
    frame.validate()?;
    Ok(frame)
}

pub fn encode_line(frame: &Frame) -> Result<Vec<u8>, String> {
    frame.validate()?;
    let mut bytes = serde_json::to_vec(frame).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    require(bytes.len() <= MAX_FRAME_BYTES, "frame exceeds limit")?;
    Ok(bytes)
}
