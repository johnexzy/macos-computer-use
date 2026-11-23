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
pub const MAX_FEEDBACK_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_OCR_MATCHES: usize = 256;
pub const MAX_OCR_TEXT_BYTES: usize = 1024;
pub const MAX_OCR_BYTES: usize = 256 * 1024;
pub const MAX_OCR_QUERY_BYTES: usize = 4096;
pub const MAX_AX_SELECTORS: usize = 16;
pub const MAX_TARGET_EVENTS: usize = 64;
pub const MAX_TARGET_EVENT_BYTES: usize = 64 * 1024;
pub const MAX_EVENT_CONTROLS: usize = 16;
pub const MAX_EVENT_VALUE_BYTES: usize = 4096;
pub const MAX_URL_BYTES: usize = 2048;
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
    AxPress,
    AxScroll,
    AxScrollToVisible,
    AxConfirm,
    AxShowMenu,
    AxCancel,
    AxMenu,
    ForegroundKey,
    ForegroundClick,
    ForegroundDoubleClick,
    ForegroundRightClick,
    ForegroundHover,
    ForegroundDrag,
    ForegroundHotkey,
    ForegroundTypeKeys
});
choices!(ObserveScope {
    Window,
    WebArea,
    MenuBar
});
choices!(Modifier {
    Command,
    Control,
    Option,
    Shift
});
choices!(Coverage {
    Complete,
    Partial,
    Unavailable
});
choices!(MimeType { Png, Jpeg });
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum CaptureStatus {
    Captured,
    PermissionDenied,
    Unsupported,
    Unavailable,
    GeometryChanged,
    Failed,
}
choices!(OcrStatus {
    Complete,
    Partial,
    Unavailable,
    Failed
});
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
    Down,
    SaveAs,
    FocusAddressBar,
    Reload,
    NewTab,
    CloseTab,
    NavigateBack,
    NavigateForward
});
choices!(ElementAction {
    Press,
    SetValue,
    TypeText,
    Key,
    Scroll,
    ScrollToVisible,
    Confirm,
    ShowMenu,
    Cancel
});
choices!(ActionKind {
    Press,
    SetValue,
    TypeText,
    Key,
    Scroll,
    ScrollToVisible,
    Confirm,
    ShowMenu,
    Cancel,
    InvokeMenu,
    Click,
    DoubleClick,
    RightClick,
    Hover,
    Drag,
    Hotkey,
    TypeKeys
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
    ConditionSatisfied,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Target {
    pub key: TargetKey,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    pub title: String,
    pub bounds: Rect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_name: Option<String>,
}
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TargetsRequest {
    pub bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_contains: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_contains: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub unbundled_only: bool,
}
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
record!(VisualFrame {
    width_px: u32,
    height_px: u32,
    capture_window_bounds: Rect,
    capture_screen_bounds: Rect,
    image_to_screen: ImageTransform,
    image_to_window: ImageTransform
});
record!(OcrMatch {
    text: String,
    image_bounds: Rect
});
record!(OcrEvidence { status: OcrStatus, collected: Option<CollectionInterval>, matches: Vec<OcrMatch> });
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VisualEvidence {
    pub capture_status: CaptureStatus,
    pub collected: CollectionInterval,
    #[serde(rename = "geometryMatchesAX")]
    pub geometry_matches_ax: Option<bool>,
    pub frame: Option<VisualFrame>,
    pub ocr: Option<OcrEvidence>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Element {
    pub reference: String,
    pub role: String,
    pub label: Option<String>,
    pub value: Option<String>,
    pub bounds: Rect,
    // A required nullable field: unavailable enabled state is not observed false.
    #[serde(deserialize_with = "Option::deserialize")]
    #[cfg_attr(
        feature = "schema",
        schemars(required, schema_with = "nullable_enabled_schema")
    )]
    pub enabled: Option<bool>,
    pub actions: Vec<ElementAction>,
    pub identifier: Option<String>,
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[cfg(feature = "schema")]
fn nullable_enabled_schema(generator: &mut schemars::SchemaGenerator) -> schemars::Schema {
    <Option<bool> as schemars::JsonSchema>::json_schema(generator)
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ObserveRequest {
    pub target: TargetKey,
    pub include_screenshot: bool,
    pub include_values: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub include_ocr: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ocr_query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crop_window: Option<Rect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_image_dimension_px: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ax_selectors: Option<Vec<Selector>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_history: Option<EventHistoryRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<ObserveScope>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub interactive_only: bool,
}
fn is_false(value: &bool) -> bool {
    !value
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Observation {
    pub observation_id: String,
    pub target: TargetKey,
    pub collected: CollectionInterval,
    pub window_bounds: Rect,
    pub accessibility: Coverage,
    pub accessibility_collected: Option<CollectionInterval>,
    pub elements: Vec<Element>,
    pub screenshot: Option<Screenshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visual: Option<Box<VisualEvidence>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ax_selection: Option<Box<AxSelectionEvidence>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub events: Option<Box<EventHistory>>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Selector {
    pub role: String,
    pub label: Option<String>,
    pub identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label_contains: Option<String>,
}
record!(AxSelectionEvidence { selectors: Vec<Selector>, coverage: Coverage, ambiguous: bool, visited_nodes: u32 });
record!(EventCursor {
    generation: String,
    sequence: u64
});
record!(EventHistoryRequest { cursor: Option<EventCursor> });
record!(EventControl { role: String, identifier: Option<String>, label: Option<String>, value: Option<String>, enabled: Option<bool>, bounds: Rect, subrole: Option<String> });
choices!(EventSource { Notification, Poll });
choices!(EventMode {
    NotificationsAndPolling,
    Polling,
    Unavailable
});
record!(TargetEvent { sequence: u64, source: EventSource, notification: Option<String>, observed_unix_ms: u64,
                     collected: CollectionInterval, coverage: Coverage, controls: Vec<EventControl> });
record!(EventHistory { cursor: EventCursor, oldest_sequence: Option<u64>, started_unix_ms: u64, collected: CollectionInterval,
                      stale: bool, overrun: bool, mode: EventMode, coalesced_wakes: u64, sample_count: u64, events: Vec<TargetEvent> });
record!(ElementCondition { selector: Selector });
record!(ValueCondition {
    element_ref: String,
    value: String
});
record!(ValueContainsCondition {
    element_ref: String,
    contains: String
});
record!(EnabledCondition {
    element_ref: String,
    enabled: bool
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UrlCondition {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_ref: Option<String>,
    pub contains: String,
}
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
    ValueContains(ValueContainsCondition),
    Enabled(EnabledCondition),
    UrlContains(UrlCondition),
    WindowAbsent(Empty),
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
record!(InvokeMenuOperation { path: Vec<String> });
record!(ClickOperation {
    point: Point,
    space: CoordinateSpace
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DragOperation {
    pub from: Point,
    pub to: Point,
    pub space: CoordinateSpace,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steps: Option<u8>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HotkeyOperation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_ref: Option<String>,
    pub key: String,
    #[serde(default)]
    pub modifiers: Vec<Modifier>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TypeKeysOperation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_ref: Option<String>,
    pub text: String,
}
record!(WaitOperation {
    condition: Condition
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
    ScrollToVisible(ElementOperation),
    Confirm(ElementOperation),
    ShowMenu(ElementOperation),
    Cancel(ElementOperation),
    InvokeMenu(InvokeMenuOperation),
    Click(ClickOperation),
    DoubleClick(ClickOperation),
    RightClick(ClickOperation),
    Hover(ClickOperation),
    Drag(DragOperation),
    Hotkey(HotkeyOperation),
    TypeKeys(TypeKeysOperation),
    WaitFor(WaitOperation),
}
choices!(FeedbackState {
    Changed,
    Unchanged,
    Invalidated,
    Unavailable
});
record!(FeedbackRequest { element_refs: Vec<String>, include_values: bool });
record!(ControlFeedback { element_ref: String, state: FeedbackState, element: Option<Element> });
record!(ObservationFeedback {
    base_observation_id: String, collected: CollectionInterval, controls: Vec<ControlFeedback>,
    invalidated: bool, truncated: bool
});
record!(ActionStep {
    action_id: String, operation: Operation, precondition: Option<Condition>, expect: Option<Condition>
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActRequest {
    pub grant_id: String,
    pub observation_id: String,
    pub target: TargetKey,
    pub steps: Vec<ActionStep>,
    pub feedback: Option<FeedbackRequest>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub foreground: bool,
}
record!(CheckEvidence {
    observation_id: String,
    condition: Condition,
    matched: bool, collected: Option<CollectionInterval>
});
record!(StepReceipt {
    action_id: String, delivery: Delivery, verification: Verification,
    reason: Option<ReceiptReason>, evidence: Vec<CheckEvidence>, route: Option<DeliveryRoute>
});
choices!(ForegroundInterruption {
    InputActivity,
    FocusChanged,
    WindowChanged,
    FrameChanged,
    PermissionUnavailable,
    ActivationFailed,
    Cancelled,
    DeadlineExceeded
});
choices!(FocusRestoration {
    NotNeeded,
    Pending,
    Restored,
    Skipped,
    Failed
});
record!(ForegroundEvidence {
    initial_pid: Option<u32>, last_pid: Option<u32>, activation_requested: bool,
    input_activity: bool, external_activation: bool, interruption: Option<ForegroundInterruption>,
    restoration: FocusRestoration
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActResult {
    pub observation_id: String,
    pub steps: Vec<StepReceipt>,
    pub remaining_steps: u16,
    pub stop_reason: StopReason,
    pub feedback: Option<ObservationFeedback>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<ForegroundEvidence>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WaitRequest {
    pub observation_id: String,
    pub target: TargetKey,
    pub condition: Condition,
    #[serde(default, skip_serializing_if = "is_false")]
    pub include_values: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<ObserveScope>,
}
record!(WaitResult { outcome: WaitOutcome, already_satisfied: bool, observation: Option<Observation>, evidence: Option<Box<CheckEvidence>> });
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenRequest {
    pub grant_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub new_instance: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub activate: bool,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    pub activated: bool,
    pub targets: Vec<Target>,
}
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
    Open(OpenRequest),
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
    Open(OpenResult),
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
            require(
                !act.foreground || self.authority.mode == ExecutionMode::ForegroundAllowed,
                "operator foreground authority is required",
            )?;
        }
        if let RequestBody::Open(open) = &request.body {
            require(
                open.grant_id == self.authority.grant_id,
                "unknown host authority grant",
            )?;
            require(
                !open.activate || self.authority.mode == ExecutionMode::ForegroundAllowed,
                "operator foreground authority is required",
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
fn is_foreground_route(route: DeliveryRoute) -> bool {
    matches!(
        route,
        DeliveryRoute::ForegroundKey
            | DeliveryRoute::ForegroundClick
            | DeliveryRoute::ForegroundDoubleClick
            | DeliveryRoute::ForegroundRightClick
            | DeliveryRoute::ForegroundHover
            | DeliveryRoute::ForegroundDrag
            | DeliveryRoute::ForegroundHotkey
            | DeliveryRoute::ForegroundTypeKeys
    )
}
fn is_foreground_operation(operation: &Operation) -> bool {
    matches!(
        operation,
        Operation::Key(_)
            | Operation::Click(_)
            | Operation::DoubleClick(_)
            | Operation::RightClick(_)
            | Operation::Hover(_)
            | Operation::Drag(_)
            | Operation::Hotkey(_)
            | Operation::TypeKeys(_)
    )
}
pub fn is_valid_hotkey_name(key: &str) -> bool {
    matches!(
        key,
        "a" | "b"
            | "c"
            | "d"
            | "e"
            | "f"
            | "g"
            | "h"
            | "i"
            | "j"
            | "k"
            | "l"
            | "m"
            | "n"
            | "o"
            | "p"
            | "q"
            | "r"
            | "s"
            | "t"
            | "u"
            | "v"
            | "w"
            | "x"
            | "y"
            | "z"
            | "0"
            | "1"
            | "2"
            | "3"
            | "4"
            | "5"
            | "6"
            | "7"
            | "8"
            | "9"
            | "minus"
            | "equal"
            | "leftBracket"
            | "rightBracket"
            | "backslash"
            | "semicolon"
            | "quote"
            | "comma"
            | "period"
            | "slash"
            | "grave"
            | "space"
            | "return"
            | "tab"
            | "escape"
            | "backspace"
            | "delete"
            | "left"
            | "right"
            | "up"
            | "down"
            | "home"
            | "end"
            | "pageUp"
            | "pageDown"
            | "f1"
            | "f2"
            | "f3"
            | "f4"
            | "f5"
            | "f6"
            | "f7"
            | "f8"
            | "f9"
            | "f10"
            | "f11"
            | "f12"
    )
}
fn valid_open_url(url: &str) -> Result<(), String> {
    require(
        !url.is_empty()
            && url.len() <= MAX_URL_BYTES
            && !url.bytes().any(|b| b <= 0x20 || b == 0x7f),
        "invalid open URL",
    )?;
    let Some((scheme, rest)) = url.split_once(':') else {
        return Err("open URL requires a scheme".into());
    };
    let mut chars = scheme.chars();
    require(
        chars.next().is_some_and(|c| c.is_ascii_alphabetic())
            && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')),
        "invalid open URL scheme",
    )?;
    let lower = scheme.to_ascii_lowercase();
    require(
        !matches!(lower.as_str(), "javascript" | "vbscript" | "data"),
        "forbidden open URL scheme",
    )?;
    if matches!(lower.as_str(), "http" | "https") {
        let Some(after) = rest.strip_prefix("//") else {
            return Err("http(s) URL requires authority".into());
        };
        let host = after.split(['/', '?', '#']).next().unwrap_or("");
        require(!host.is_empty(), "http(s) URL requires host")?;
    } else {
        require(!rest.is_empty(), "open URL requires target")?;
    }
    Ok(())
}
fn expectation(
    step: &ActionStep,
    receipt: &StepReceipt,
    settled: bool,
    foreground: bool,
) -> Result<(), String> {
    if let Some(route) = receipt.route {
        require(
            matches!(
                (&step.operation, route),
                (Operation::SetValue(_), DeliveryRoute::AxSetValue)
                    | (Operation::TypeText(_), DeliveryRoute::AxSelectedText)
                    | (Operation::Press(_), DeliveryRoute::AxPress)
                    | (Operation::Scroll(_), DeliveryRoute::AxScroll)
                    | (
                        Operation::ScrollToVisible(_),
                        DeliveryRoute::AxScrollToVisible
                    )
                    | (Operation::Confirm(_), DeliveryRoute::AxConfirm)
                    | (Operation::ShowMenu(_), DeliveryRoute::AxShowMenu)
                    | (Operation::Cancel(_), DeliveryRoute::AxCancel)
                    | (Operation::InvokeMenu(_), DeliveryRoute::AxMenu)
                    | (Operation::Key(_), DeliveryRoute::ForegroundKey)
                    | (Operation::Click(_), DeliveryRoute::ForegroundClick)
                    | (
                        Operation::DoubleClick(_),
                        DeliveryRoute::ForegroundDoubleClick
                    )
                    | (
                        Operation::RightClick(_),
                        DeliveryRoute::ForegroundRightClick
                    )
                    | (Operation::Hover(_), DeliveryRoute::ForegroundHover)
                    | (Operation::Drag(_), DeliveryRoute::ForegroundDrag)
                    | (Operation::Hotkey(_), DeliveryRoute::ForegroundHotkey)
                    | (Operation::TypeKeys(_), DeliveryRoute::ForegroundTypeKeys)
            ),
            "receipt route does not match operation",
        )?;
        require(
            foreground == is_foreground_route(route),
            "receipt route does not match requested foreground mode",
        )?;
    }
    let mut required = Vec::new();
    if let Operation::WaitFor(wait) = &step.operation {
        require(
            receipt.delivery == Delivery::NotDispatched && receipt.route.is_none(),
            "wait cannot dispatch input",
        )?;
        required.push(wait.condition.clone());
        if settled
            || matches!(
                receipt.reason,
                Some(ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied)
            )
        {
            require(
                matches!(
                    receipt.reason,
                    Some(ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied)
                ),
                "settled wait requires a successful wait reason",
            )?;
            require(
                receipt
                    .evidence
                    .iter()
                    .any(|e| e.condition == wait.condition && e.matched && e.collected.is_some()),
                "settled wait requires timed condition evidence",
            )?;
        }
    } else {
        require(
            receipt.reason != Some(ReceiptReason::ConditionSatisfied),
            "conditionSatisfied requires a wait operation",
        )?;
    }
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
            Self::ElementExists(v) | Self::ElementAbsent(v) => validate_selector(&v.selector),
            Self::ValueEquals(v) => id(&v.element_ref),
            Self::ValueContains(v) => {
                id(&v.element_ref)?;
                require(
                    !v.contains.is_empty() && v.contains.len() <= 4096,
                    "invalid value substring condition",
                )
            }
            Self::Enabled(v) => id(&v.element_ref),
            Self::UrlContains(v) => {
                if let Some(element_ref) = &v.element_ref {
                    id(element_ref)?;
                }
                require(
                    !v.contains.is_empty() && v.contains.len() <= MAX_URL_BYTES,
                    "invalid URL substring condition",
                )
            }
            Self::WindowAbsent(_) => Ok(()),
        }
    }
}

impl CheckEvidence {
    fn validate(&self) -> Result<(), String> {
        id(&self.observation_id)?;
        self.condition.validate()?;
        if let Some(collected) = &self.collected {
            interval(collected)?;
        }
        Ok(())
    }
}

impl ObservationFeedback {
    fn validate(&self) -> Result<(), String> {
        id(&self.base_observation_id)?;
        interval(&self.collected)?;
        require(
            self.controls.len() <= MAX_ELEMENTS,
            "too many feedback controls",
        )?;
        unique(self.controls.iter().map(|c| c.element_ref.as_str()))?;
        for control in &self.controls {
            require(
                (control.state == FeedbackState::Changed) == control.element.is_some(),
                "only changed feedback carries an element",
            )?;
            if let Some(element) = &control.element {
                require(
                    element.reference == control.element_ref,
                    "feedback must preserve the base reference",
                )?;
                id(&element.role)?;
                rect(&element.bounds)?;
                require(
                    element.label.as_ref().is_none_or(|s| s.len() <= 1024)
                        && element.identifier.as_ref().is_none_or(|s| s.len() <= 1024)
                        && element.subrole.as_ref().is_none_or(|s| s.len() <= 1024)
                        && element
                            .url
                            .as_ref()
                            .is_none_or(|s| !s.is_empty() && s.len() <= MAX_URL_BYTES)
                        && element.value.as_ref().is_none_or(|s| s.len() <= 65_536),
                    "feedback projection exceeds string limit",
                )?;
            }
        }
        require(
            !self.invalidated
                || self
                    .controls
                    .iter()
                    .all(|c| c.state == FeedbackState::Invalidated),
            "invalidated binding cannot carry live feedback",
        )?;
        require(
            serde_json::to_vec(self)
                .map_err(|_| "feedback encoding failed")?
                .len()
                <= MAX_FEEDBACK_BYTES,
            "feedback exceeds payload limit",
        )
    }
}

fn correlate_feedback(request: &ActRequest, result: &ActResult) -> Result<(), String> {
    let Some(feedback) = &result.feedback else {
        return Ok(());
    };
    let Some(requested) = &request.feedback else {
        return Err("unrequested feedback".into());
    };
    require(
        feedback.base_observation_id == request.observation_id,
        "feedback base observation mismatch",
    )?;
    require(
        feedback
            .controls
            .iter()
            .all(|c| requested.element_refs.contains(&c.element_ref)),
        "feedback contains an unrequested reference",
    )?;
    require(
        feedback.truncated || feedback.controls.len() == requested.element_refs.len(),
        "feedback omitted requested references",
    )?;
    require(
        requested.include_values
            || feedback
                .controls
                .iter()
                .all(|c| c.element.as_ref().is_none_or(|e| e.value.is_none())),
        "feedback includes unrequested values",
    )
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
fn near(a: f64, b: f64) -> bool {
    (a - b).abs() <= 0.000_001
}
fn same_rect(a: &Rect, b: &Rect) -> bool {
    near(a.x, b.x) && near(a.y, b.y) && near(a.width, b.width) && near(a.height, b.height)
}
fn inside(inner: &Rect, outer: &Rect) -> bool {
    inner.x >= outer.x - 0.000_001
        && inner.y >= outer.y - 0.000_001
        && inner.x + inner.width <= outer.x + outer.width + 0.000_001
        && inner.y + inner.height <= outer.y + outer.height + 0.000_001
}
impl ObserveRequest {
    fn validate(&self) -> Result<(), String> {
        target(&self.target)?;
        if let Some(selectors) = &self.ax_selectors {
            validate_selectors(selectors)?;
        }
        if self.scope == Some(ObserveScope::MenuBar) {
            require(
                self.event_history.is_none()
                    && !self.include_screenshot
                    && !self.include_ocr
                    && self.crop_window.is_none()
                    && self.max_image_dimension_px.is_none(),
                "menuBar scope does not support visual capture or event history",
            )?;
        }
        if let Some(history) = &self.event_history {
            require(
                self.ax_selectors.is_some(),
                "event history requires explicit AX selectors",
            )?;
            require(
                self.scope.is_none_or(|s| s == ObserveScope::Window) && !self.interactive_only,
                "event history requires full window scope",
            )?;
            if let Some(cursor) = &history.cursor {
                id(&cursor.generation)?;
                require(
                    cursor.sequence <= MAX_SAFE_INTEGER,
                    "event cursor exceeds safe integer range",
                )?;
            }
        }
        if let Some(query) = &self.ocr_query {
            require(
                self.include_ocr && !query.is_empty() && query.len() <= MAX_OCR_QUERY_BYTES,
                "invalid OCR query",
            )?;
        }
        if let Some(crop) = &self.crop_window {
            rect(crop)?;
            require(
                (self.include_screenshot || self.include_ocr) && crop.x >= 0.0 && crop.y >= 0.0,
                "invalid window crop",
            )?;
        }
        if let Some(size) = self.max_image_dimension_px {
            require(
                (self.include_screenshot || self.include_ocr) && (64..=2048).contains(&size),
                "invalid image dimension limit",
            )?;
        }
        Ok(())
    }
}
fn validate_selector(selector: &Selector) -> Result<(), String> {
    id(&selector.role)?;
    require(
        selector.label.as_ref().is_none_or(|s| s.len() <= 1024)
            && selector.identifier.as_ref().is_none_or(|s| s.len() <= 1024),
        "AX selector exceeds string limit",
    )?;
    if let Some(contains) = &selector.label_contains {
        require(
            !contains.is_empty() && contains.len() <= 1024,
            "invalid AX selector labelContains",
        )?;
    }
    Ok(())
}
fn validate_selectors(selectors: &[Selector]) -> Result<(), String> {
    require(
        !selectors.is_empty() && selectors.len() <= MAX_AX_SELECTORS,
        "invalid AX selector count",
    )?;
    for (index, selector) in selectors.iter().enumerate() {
        validate_selector(selector)?;
        require(
            !selectors[..index].contains(selector),
            "duplicate AX selector",
        )?;
    }
    Ok(())
}
fn selector_matches(element: &Element, selector: &Selector) -> bool {
    element.role == selector.role
        && selector
            .label
            .as_ref()
            .is_none_or(|s| Some(s) == element.label.as_ref())
        && selector.label_contains.as_ref().is_none_or(|sub| {
            element
                .label
                .as_deref()
                .is_some_and(|label| label.contains(sub.as_str()))
        })
        && selector
            .identifier
            .as_ref()
            .is_none_or(|s| Some(s) == element.identifier.as_ref())
}
fn historical_matches(control: &EventControl, selector: &Selector) -> bool {
    control.role == selector.role
        && selector
            .label
            .as_ref()
            .is_none_or(|s| Some(s) == control.label.as_ref())
        && selector.label_contains.as_ref().is_none_or(|sub| {
            control
                .label
                .as_deref()
                .is_some_and(|label| label.contains(sub.as_str()))
        })
        && selector
            .identifier
            .as_ref()
            .is_none_or(|s| Some(s) == control.identifier.as_ref())
}
impl EventHistory {
    fn validate(&self) -> Result<(), String> {
        id(&self.cursor.generation)?;
        require(
            self.cursor.sequence <= MAX_SAFE_INTEGER
                && self.coalesced_wakes <= MAX_SAFE_INTEGER
                && self.sample_count <= MAX_SAFE_INTEGER,
            "event counters exceed safe integer range",
        )?;
        interval(&self.collected)?;
        require(
            self.started_unix_ms <= self.collected.finished_unix_ms,
            "event history starts after collection",
        )?;
        require(
            self.events.len() <= MAX_TARGET_EVENTS,
            "too many target events",
        )?;
        if let Some(oldest) = self.oldest_sequence {
            require(
                oldest > 0 && oldest <= self.cursor.sequence,
                "invalid oldest event sequence",
            )?;
        }
        let mut previous = 0;
        for event in &self.events {
            require(
                event.sequence > previous && event.sequence <= self.cursor.sequence,
                "unordered target events",
            )?;
            previous = event.sequence;
            interval(&event.collected)?;
            require(
                event.observed_unix_ms <= event.collected.finished_unix_ms
                    && event.collected.finished_unix_ms <= self.collected.finished_unix_ms,
                "invalid historical event interval",
            )?;
            require(
                (event.source == EventSource::Notification) == event.notification.is_some(),
                "event source lacks notification provenance",
            )?;
            if let Some(notification) = &event.notification {
                id(notification)?;
            }
            require(
                event.controls.len() <= MAX_EVENT_CONTROLS,
                "too many historical controls",
            )?;
            require(
                event.coverage != Coverage::Unavailable || event.controls.is_empty(),
                "unavailable historical event has controls",
            )?;
            for control in &event.controls {
                id(&control.role)?;
                rect(&control.bounds)?;
                require(
                    control.identifier.as_ref().is_none_or(|s| s.len() <= 1024)
                        && control.label.as_ref().is_none_or(|s| s.len() <= 1024)
                        && control.subrole.as_ref().is_none_or(|s| s.len() <= 1024)
                        && control
                            .value
                            .as_ref()
                            .is_none_or(|s| s.len() <= MAX_EVENT_VALUE_BYTES),
                    "historical control exceeds string limit",
                )?;
            }
        }
        require(
            serde_json::to_vec(self)
                .map_err(|_| "cannot encode event history")?
                .len()
                <= MAX_TARGET_EVENT_BYTES,
            "event history exceeds payload limit",
        )
    }
}
impl VisualFrame {
    fn validate(&self) -> Result<(), String> {
        rect(&self.capture_window_bounds)?;
        rect(&self.capture_screen_bounds)?;
        require(
            self.width_px > 0
                && self.height_px > 0
                && inside(&self.capture_screen_bounds, &self.capture_window_bounds),
            "invalid visual capture bounds",
        )?;
        let domain = Rect {
            x: 0.0,
            y: 0.0,
            width: self.width_px.into(),
            height: self.height_px.into(),
        };
        let screen = &self.image_to_screen;
        let window = &self.image_to_window;
        for transform in [screen, window] {
            require(
                transform.coverage == Coverage::Complete
                    && same_rect(&transform.valid_image_bounds, &domain),
                "visual frame mapping must cover returned image",
            )?;
            transform.to_screen(&Point { x: 0.0, y: 0.0 })?;
        }
        let mapped = Rect {
            x: screen.offset_x,
            y: screen.offset_y,
            width: domain.width * screen.scale_x,
            height: domain.height * screen.scale_y,
        };
        require(
            same_rect(&mapped, &self.capture_screen_bounds),
            "image mapping disagrees with capture bounds",
        )?;
        require(
            near(window.scale_x, screen.scale_x)
                && near(window.scale_y, screen.scale_y)
                && near(
                    window.offset_x,
                    screen.offset_x - self.capture_window_bounds.x,
                )
                && near(
                    window.offset_y,
                    screen.offset_y - self.capture_window_bounds.y,
                ),
            "window and desktop mappings disagree",
        )
    }
}
impl OcrEvidence {
    fn validate(&self) -> Result<(), String> {
        if let Some(time) = &self.collected {
            interval(time)?;
        }
        require(
            self.matches.len() <= MAX_OCR_MATCHES,
            "too many OCR matches",
        )?;
        match self.status {
            OcrStatus::Complete | OcrStatus::Partial => require(
                self.collected.is_some(),
                "available OCR requires collection interval",
            )?,
            OcrStatus::Failed => require(
                self.collected.is_some() && self.matches.is_empty(),
                "failed OCR requires interval and no matches",
            )?,
            OcrStatus::Unavailable => require(
                self.matches.is_empty(),
                "unavailable OCR cannot include matches",
            )?,
        }
        for value in &self.matches {
            require(
                !value.text.is_empty() && value.text.len() <= MAX_OCR_TEXT_BYTES,
                "invalid OCR text",
            )?;
            rect(&value.image_bounds)?;
        }
        require(
            serde_json::to_vec(self)
                .map_err(|_| "cannot encode OCR")?
                .len()
                <= MAX_OCR_BYTES,
            "OCR exceeds payload limit",
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
            require(
                element.subrole.as_ref().is_none_or(|s| s.len() <= 1024),
                "element subrole exceeds string limit",
            )?;
            require(
                element
                    .url
                    .as_ref()
                    .is_none_or(|s| !s.is_empty() && s.len() <= MAX_URL_BYTES),
                "element URL exceeds string limit",
            )?;
        }
        if let Some(selection) = &self.ax_selection {
            validate_selectors(&selection.selectors)?;
            require(
                self.accessibility != Coverage::Complete && selection.visited_nodes <= 1024,
                "selected AX scope cannot imply a complete window",
            )?;
            require(
                self.elements.iter().all(|element| {
                    selection
                        .selectors
                        .iter()
                        .any(|selector| selector_matches(element, selector))
                }),
                "selected AX result is outside its query",
            )?;
            let duplicates = selection.selectors.iter().any(|selector| {
                self.elements
                    .iter()
                    .filter(|e| selector_matches(e, selector))
                    .count()
                    > 1
            });
            require(
                !duplicates || selection.ambiguous,
                "selected AX result hides ambiguity",
            )?;
            if selection.coverage == Coverage::Complete {
                require(
                    selection.ambiguous == duplicates,
                    "inconsistent selected AX ambiguity",
                )?;
            }
            if selection.coverage == Coverage::Unavailable {
                require(
                    self.elements.is_empty() && !selection.ambiguous,
                    "unavailable AX selection has results",
                )?;
            }
        }
        if let Some(events) = &self.events {
            events.validate()?;
            channel_interval(&events.collected, &self.collected)?;
            require(
                self.ax_selection.is_some(),
                "event history lacks query provenance",
            )?;
        }
        if let Some(screenshot) = &self.screenshot {
            screenshot.validate()?;
            channel_interval(&screenshot.collected, &self.collected)?;
        }
        if let Some(visual) = &self.visual {
            channel_interval(&visual.collected, &self.collected)?;
            let captured = visual.capture_status == CaptureStatus::Captured;
            require(
                captured == visual.frame.is_some(),
                "capture status and visual frame disagree",
            )?;
            if let Some(frame) = &visual.frame {
                frame.validate()?;
                if self.accessibility != Coverage::Unavailable {
                    require(
                        visual.geometry_matches_ax
                            == Some(same_rect(&frame.capture_window_bounds, &self.window_bounds)),
                        "missing or inconsistent AX geometry agreement",
                    )?;
                } else {
                    require(
                        visual.geometry_matches_ax.is_none(),
                        "unavailable AX cannot establish geometry agreement",
                    )?;
                }
                if let Some(image) = &self.screenshot {
                    require(
                        image.width_px == frame.width_px
                            && image.height_px == frame.height_px
                            && image.image_to_screen == frame.image_to_screen
                            && image.collected == visual.collected,
                        "screenshot and visual provenance disagree",
                    )?;
                }
                if let Some(ocr) = &visual.ocr {
                    let domain = Rect {
                        x: 0.0,
                        y: 0.0,
                        width: frame.width_px.into(),
                        height: frame.height_px.into(),
                    };
                    require(
                        ocr.matches.iter().all(|m| inside(&m.image_bounds, &domain)),
                        "OCR bounds outside returned image",
                    )?;
                }
            } else {
                require(
                    self.screenshot.is_none(),
                    "failed capture cannot include screenshot",
                )?;
                require(
                    visual.geometry_matches_ax.is_none()
                        || (visual.capture_status == CaptureStatus::GeometryChanged
                            && visual.geometry_matches_ax == Some(false)
                            && self.accessibility != Coverage::Unavailable),
                    "failed capture has unsupported geometry agreement",
                )?;
            }
            if let Some(ocr) = &visual.ocr {
                ocr.validate()?;
                if let Some(time) = &ocr.collected {
                    channel_interval(time, &self.collected)?;
                    require(
                        time.started_unix_ms >= visual.collected.finished_unix_ms,
                        "OCR precedes capture completion",
                    )?;
                }
                require(
                    captured || ocr.status == OcrStatus::Unavailable,
                    "OCR requires a captured frame",
                )?;
            }
        }
        Ok(())
    }
}
impl OpenRequest {
    fn validate(&self) -> Result<(), String> {
        id(&self.grant_id)?;
        require(
            self.bundle_id.is_some() || self.app_name.is_some() || self.url.is_some(),
            "open requires bundleId, appName, or url",
        )?;
        require(
            !(self.bundle_id.is_some() && self.app_name.is_some()),
            "specify either bundleId or appName, not both",
        )?;
        if let Some(bundle_id) = &self.bundle_id {
            id(bundle_id)?;
        }
        if let Some(app_name) = &self.app_name {
            require(
                !app_name.trim().is_empty()
                    && app_name.len() <= 256
                    && !app_name.contains('/')
                    && !app_name.contains('\\')
                    && !app_name.contains("..")
                    && !app_name.bytes().any(|b| b < 0x20 || b == 0x7f),
                "invalid app name",
            )?;
        }
        if let Some(url) = &self.url {
            valid_open_url(url)?;
        }
        if self.new_instance {
            require(
                self.bundle_id.is_some() || self.app_name.is_some(),
                "newInstance requires bundleId or appName",
            )?;
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
        if self.foreground {
            require(
                self.steps.iter().all(|step| {
                    is_foreground_operation(&step.operation)
                        || matches!(step.operation, Operation::WaitFor(_))
                }) && self
                    .steps
                    .iter()
                    .any(|step| is_foreground_operation(&step.operation)),
                "foreground sequences require a foreground action and may include waits",
            )?;
        }
        for step in &self.steps {
            match &step.operation {
                Operation::Press(v)
                | Operation::ScrollToVisible(v)
                | Operation::Confirm(v)
                | Operation::ShowMenu(v)
                | Operation::Cancel(v) => id(&v.element_ref)?,
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
                Operation::InvokeMenu(v) => {
                    require(
                        (2..=6).contains(&v.path.len()),
                        "menu path requires 2 to 6 segments",
                    )?;
                    for segment in &v.path {
                        require(
                            !segment.trim().is_empty() && segment.len() <= 256,
                            "invalid menu path segment",
                        )?;
                    }
                }
                Operation::Click(v)
                | Operation::DoubleClick(v)
                | Operation::RightClick(v)
                | Operation::Hover(v) => require(
                    v.point.x.is_finite() && v.point.y.is_finite(),
                    "invalid point",
                )?,
                Operation::Drag(v) => {
                    require(
                        v.from.x.is_finite()
                            && v.from.y.is_finite()
                            && v.to.x.is_finite()
                            && v.to.y.is_finite()
                            && v.from != v.to,
                        "invalid drag endpoints",
                    )?;
                    if let Some(steps) = v.steps {
                        require((1..=50).contains(&steps), "invalid drag step count")?;
                    }
                }
                Operation::Hotkey(v) => {
                    if let Some(element_ref) = &v.element_ref {
                        id(element_ref)?;
                    }
                    require(is_valid_hotkey_name(&v.key), "invalid hotkey name")?;
                    require(v.modifiers.len() <= 4, "too many modifiers")?;
                    for (index, modifier) in v.modifiers.iter().enumerate() {
                        require(
                            !v.modifiers[..index].contains(modifier),
                            "duplicate modifier",
                        )?;
                    }
                }
                Operation::TypeKeys(v) => {
                    if let Some(element_ref) = &v.element_ref {
                        id(element_ref)?;
                    }
                    require(
                        !v.text.is_empty()
                            && v.text.len() <= 4096
                            && !v.text.bytes().any(|b| b == 0),
                        "invalid foreground text",
                    )?;
                }
                Operation::WaitFor(v) => {
                    v.condition.validate()?;
                    require(
                        step.precondition.is_none() && step.expect.is_none(),
                        "wait steps cannot carry guards or expectations",
                    )?;
                }
            }
            if let Some(c) = &step.precondition {
                c.validate()?;
            }
            if let Some(c) = &step.expect {
                c.validate()?;
            }
        }
        if let Some(feedback) = &self.feedback {
            require(
                feedback.element_refs.len() <= MAX_ELEMENTS,
                "too many feedback references",
            )?;
            unique(feedback.element_refs.iter().map(String::as_str))?;
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
                evidence.validate()?;
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
            if matches!(
                step.reason,
                Some(ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied)
            ) {
                require(
                    step.delivery == Delivery::NotDispatched
                        && step.verification == Verification::Confirmed,
                    "alreadySatisfied requires confirmed evidence without dispatch",
                )?;
            }
            if step.delivery == Delivery::NotDispatched
                && !matches!(
                    step.reason,
                    Some(ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied)
                )
            {
                require(
                    index + 1 == self.steps.len()
                        && step.reason.is_some()
                        && self.stop_reason != StopReason::Completed,
                    "rejected step must stop sequence",
                )?;
            }
            if let Some(reason) = step.reason.filter(|r| {
                !matches!(
                    r,
                    ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied
                )
            }) {
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
                    ReceiptReason::AlreadySatisfied | ReceiptReason::ConditionSatisfied => {
                        unreachable!()
                    }
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
                            || matches!(
                                v.reason,
                                Some(
                                    ReceiptReason::AlreadySatisfied
                                        | ReceiptReason::ConditionSatisfied
                                )
                            )
                    }),
                "completed sequence cannot include rejected steps",
            )?;
        }
        if let Some(feedback) = &self.feedback {
            feedback.validate()?;
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
                    feedback: None,
                    foreground: None,
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
                    RequestBody::Targets(v) => {
                        if let Some(title) = &v.title_contains {
                            require(
                                !title.trim().is_empty() && title.len() <= 1024,
                                "invalid title filter",
                            )?;
                        }
                        if let Some(owner) = &v.owner_contains {
                            require(
                                !owner.trim().is_empty() && owner.len() <= 1024,
                                "invalid owner filter",
                            )?;
                        }
                    }
                    RequestBody::Observe(v) => v.validate()?,
                    RequestBody::Act(v) => v.validate()?,
                    RequestBody::WaitFor(v) => {
                        id(&v.observation_id)?;
                        target(&v.target)?;
                        v.condition.validate()?;
                        require(
                            v.scope != Some(ObserveScope::MenuBar),
                            "menuBar scope is not supported for waitFor",
                        )?;
                    }
                    RequestBody::Open(v) => v.validate()?,
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
                            if let Some(bundle_id) = &t.bundle_id {
                                id(bundle_id)?;
                            }
                            if let Some(owner_name) = &t.owner_name {
                                require(
                                    !owner_name.trim().is_empty() && owner_name.len() <= 1024,
                                    "invalid target owner name",
                                )?;
                            }
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
                        if let Some(evidence) = &v.evidence {
                            evidence.validate()?;
                        }
                        let closed = v.evidence.as_ref().is_some_and(|e| {
                            matches!(e.condition, Condition::WindowAbsent(_))
                                && e.matched
                                && e.collected.is_some()
                        });
                        require(
                            v.outcome != WaitOutcome::Satisfied
                                || v.observation.is_some()
                                || closed,
                            "satisfied wait needs observation or timed window-absence evidence",
                        )?;
                        if let Some(o) = &v.observation {
                            o.validate()?;
                        }
                    }
                    ResponseBody::Open(v) => {
                        if let Some(pid) = v.pid {
                            require(pid > 0, "open pid must be positive")?;
                        }
                        if let Some(bundle_id) = &v.bundle_id {
                            id(bundle_id)?;
                        }
                        require(v.targets.len() <= MAX_TARGETS, "too many targets")?;
                        for t in &v.targets {
                            target(&t.key)?;
                            if let Some(bundle_id) = &t.bundle_id {
                                id(bundle_id)?;
                            }
                            if let Some(owner_name) = &t.owner_name {
                                require(
                                    !owner_name.trim().is_empty() && owner_name.len() <= 1024,
                                    "invalid target owner name",
                                )?;
                            }
                            rect(&t.bounds)?;
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
            expectation(step, receipt, true, act.foreground)?;
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
                let scoped = matches!(
                    request.scope,
                    Some(ObserveScope::WebArea | ObserveScope::MenuBar)
                ) || request.interactive_only;
                require(
                    !scoped || observation.accessibility != Coverage::Complete,
                    "scoped observation cannot imply a complete window",
                )?;
                require(
                    request.include_values
                        || observation.elements.iter().all(|e| e.value.is_none()),
                    "observation includes unrequested values",
                )?;
                require(
                    request.ax_selectors.as_ref()
                        == observation.ax_selection.as_ref().map(|s| &s.selectors),
                    "AX selection does not match request",
                )?;
                require(
                    request.event_history.is_some() == observation.events.is_some(),
                    "event history inclusion does not match request",
                )?;
                if let Some(history) = &observation.events {
                    require(
                        request.include_values
                            || history
                                .events
                                .iter()
                                .all(|e| e.controls.iter().all(|c| c.value.is_none())),
                        "event history includes unrequested values",
                    )?;
                    require(
                        history.events.iter().all(|event| {
                            event.controls.iter().all(|control| {
                                request.ax_selectors.as_ref().is_some_and(|selectors| {
                                    selectors
                                        .iter()
                                        .any(|selector| historical_matches(control, selector))
                                })
                            })
                        }),
                        "event history contains controls outside the query",
                    )?;
                    if let Some(cursor) = request
                        .event_history
                        .as_ref()
                        .and_then(|h| h.cursor.as_ref())
                    {
                        if cursor.generation != history.cursor.generation {
                            require(
                                history.stale,
                                "history generation changed without a stale marker",
                            )?;
                        } else {
                            require(
                                history.cursor.sequence >= cursor.sequence
                                    && history.events.iter().all(|e| e.sequence > cursor.sequence),
                                "event cursor replay or regression",
                            )?;
                            if let Some(oldest) = history.oldest_sequence
                                && cursor.sequence < oldest - 1
                            {
                                require(history.overrun, "history hides an event-buffer overrun")?;
                            }
                        }
                    }
                }
                require(
                    request.include_screenshot || observation.screenshot.is_none(),
                    "observation includes unrequested image",
                )?;
                require(
                    request.include_screenshot
                        || request.include_ocr
                        || observation.visual.is_none(),
                    "observation includes unrequested visual evidence",
                )?;
                require(
                    !(request.include_ocr
                        || request.crop_window.is_some()
                        || request.max_image_dimension_px.is_some())
                        || observation.visual.is_some(),
                    "requested visual evidence is missing",
                )?;
                if let Some(visual) = &observation.visual {
                    require(
                        request.include_ocr == visual.ocr.is_some(),
                        "OCR inclusion does not match request",
                    )?;
                    if let Some(frame) = &visual.frame {
                        require(
                            !request.include_screenshot || observation.screenshot.is_some(),
                            "requested bitmap is missing",
                        )?;
                        if let Some(limit) = request.max_image_dimension_px {
                            require(
                                frame.width_px.max(frame.height_px) <= limit,
                                "image exceeds requested dimensions",
                            )?;
                        }
                        let expected = request
                            .crop_window
                            .as_ref()
                            .map(|r| Rect {
                                x: frame.capture_window_bounds.x + r.x,
                                y: frame.capture_window_bounds.y + r.y,
                                width: r.width,
                                height: r.height,
                            })
                            .unwrap_or_else(|| frame.capture_window_bounds.clone());
                        let actual = &frame.capture_screen_bounds;
                        let matches = if request.crop_window.is_some() {
                            inside(actual, &expected)
                                && (actual.x - expected.x).abs()
                                    <= frame.image_to_screen.scale_x + 0.000_001
                                && (actual.y - expected.y).abs()
                                    <= frame.image_to_screen.scale_y + 0.000_001
                                && ((actual.x + actual.width) - (expected.x + expected.width)).abs()
                                    <= frame.image_to_screen.scale_x + 0.000_001
                                && ((actual.y + actual.height) - (expected.y + expected.height))
                                    .abs()
                                    <= frame.image_to_screen.scale_y + 0.000_001
                        } else {
                            same_rect(&expected, actual)
                        };
                        require(matches, "capture does not match requested window crop")?;
                    }
                }
                Ok(())
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
                    expectation(step, receipt, settled, request.foreground)?;
                }
                require(
                    request.foreground || result.foreground.is_none(),
                    "unrequested foreground evidence",
                )?;
                correlate_feedback(request, result)
            }
            (RequestBody::WaitFor(request), ResponseBody::WaitFor(result)) => {
                if let Some(evidence) = &result.evidence {
                    require(
                        evidence.condition == request.condition,
                        "wait evidence condition mismatch",
                    )?;
                    require(
                        result.outcome != WaitOutcome::Satisfied || evidence.matched,
                        "satisfied wait has negative evidence",
                    )?;
                }
                if result.outcome == WaitOutcome::Satisfied {
                    if matches!(request.condition, Condition::WindowAbsent(_)) {
                        require(
                            result.observation.is_none()
                                && result
                                    .evidence
                                    .as_ref()
                                    .is_some_and(|e| e.matched && e.collected.is_some()),
                            "window absence requires timed evidence without a new observation",
                        )?;
                    } else {
                        require(
                            result.observation.is_some(),
                            "satisfied element wait requires an observation",
                        )?;
                    }
                }
                if let Some(observation) = &result.observation {
                    require(
                        request.target == observation.target,
                        "wait observation target mismatch",
                    )?;
                    require(
                        request.include_values
                            || observation.elements.iter().all(|e| e.value.is_none()),
                        "wait observation includes private values",
                    )?;
                    require(
                        request.scope != Some(ObserveScope::WebArea)
                            || observation.accessibility != Coverage::Complete,
                        "scoped wait observation cannot imply a complete window",
                    )?;
                }
                Ok(())
            }
            (RequestBody::Open(request), ResponseBody::Open(result)) => require(
                request.activate || !result.activated,
                "unrequested foreground activation",
            ),
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
