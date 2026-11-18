# Rust host and persistent Swift runtime

The rebuild has a standalone Rust MCP executable and one persistent Swift child
per connection. PER-3/PER-4 provide coordination and lifecycle; PER-5/PER-6 add
retained semantic observations and background actions. PER-8 adds bounded linear
composition, typed waits, and requested compact feedback. PER-9 adds on-demand
window capture and Vision OCR. These executables use protocol v1 from [protocol.md](protocol.md).

## Build and run from the checkout

Requires macOS 13+, the macOS SDK/Swift 6 toolchain and Rust 1.88+:

```sh
npm run build:runtime
npm run start:rust
```

The build installs a matching-architecture pair under `.artifacts/runtime-install`.
It can run outside the checkout without Node or a SwiftPM working directory:

```sh
/absolute/path/to/.artifacts/runtime-install/cua-host
```

The host locates `cua-runtime` beside itself. `--helper PATH` overrides that location.
Background execution is the default. Only the operator's `--allow-foreground` flag
installs a foreground grant; MCP arguments cannot install or upgrade authority.
Universal distribution and the default npm entry-point migration follow later.
The existing Node/Swift npm entry point remains available for the PER-1 comparison.

The official [rmcp 3.10.0 SDK](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.10.0)
is pinned. It supports MCP revision 2026-07-28 with per-request metadata/discovery
and older initialization sessions including 2025-11-25. The SDK handles negotiation;
the private Rust–Swift protocol has its own version and epoch.

## Implemented operations

| MCP tool | Current native behavior |
| --- | --- |
| `capabilities` | Read permission booleans and installed mode without permission prompts; advertise `setValue`, `typeText`, and `press` when the AX mutation backend and Accessibility permission are available. |
| `targets` | Return at most 256 visible, layer-zero windows with bundle IDs and exact process/window keys. |
| `observe` | Associate the exact CG target with one AX window; return at most 256 controls with retained opaque references, bounds, actions, labels, and optional identifiers. Values, screenshots, and OCR are opt-in. |
| `act` | Execute 1–16 ordered `setValue`, `typeText`, `press`, or read-only `waitFor` steps against the same target and original observation. Revalidate before every mutation; stop on failure or unknown delivery. |
| `waitFor` | Poll `elementExists`, `elementAbsent`, `enabled`, `valueEquals`, or `windowAbsent` within the original budget. Element waits return a fresh value-private observation; exact window absence returns its timed witness without a new observation. |

Keys, scrolling, and coordinate input remain unsupported in the new runtime. Composition has no branching, nested sequences, or target switching.
All mutations use the original retained refs; a presence wait does not issue refs
for newly discovered controls. The wire format can
represent more operations than this implementation executes. It does not route
around missing capabilities through legacy selectors, activation, or global input.

## Screenshot and OCR evidence

On macOS 14+, `observe` can capture a single exact window in the background
with ScreenCaptureKit. Both `includeScreenshot` and `includeOcr` default to
`false`. Visual collection checks Screen Recording permission without prompting.
macOS 13 returns `unsupported` for the visual channel and can still return AX.
Use the matching installed host and runtime for the new fields.

- `includeScreenshot: true` returns a JPEG as an MCP image block. The text and
  structured result contain dimensions, timing and mapping without duplicating
  the image bytes. The private Rust–Swift transport carries the encoded bytes.
- `includeOcr: true` can return text without exposing the bitmap. With
  `ocrQuery`, Vision supplies boxes for the matched ranges. Without a query,
  OCR returns line boxes. OCR reads visible pixels independently of
  `includeValues`, which controls semantic AX values.
- `cropWindow` is a rectangle in window-local logical points, with its origin
  at the top left. `maxImageDimensionPx` bounds the longest image side, defaults
  to 1600, and accepts 64 through 2048. The result describes the actual pixel
  dimensions and crop, including pixel-edge rounding.
- The frame provides both `imageToWindow` and `imageToScreen`. Use those
  transforms for OCR bounds, including on displays with negative origins.
  AX, capture, and OCR have separate collection intervals. If capture geometry
  changed during collection, the visual channel discards the frame. A stable
  frame can disagree with the earlier AX bounds, indicated by
  `geometryMatchesAX: false`.

Run the live check against the disposable AppKit fixture with
`npm run test:visual:live`.

Visual evidence grants no input authority. A future coordinate input path
must validate the relevant frame and layout at the dispatch boundary. An
observation reference or TTL alone cannot establish visual freshness.

Apple documentation covers [ScreenCaptureKit window capture](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
and [Vision text range boxes](https://developer.apple.com/documentation/vision/recognizing-text-in-images).

## Observation and reference validity

The public AX API does not expose an OS-attested mapping from `CGWindowID` to an
AX window. Association therefore requires the same PID, exact logical bounds, and
compatible titles when available. Both AX candidate ties and equivalent CG
siblings are rejected. A missing AX title cannot distinguish equal-bounds CG
siblings with different titles. There is no nearest-window scoring or private API.

Each catalog read takes one visible CG-window list and shares one PID-to-bundle
map across its rows. Immutable bundle metadata is retained in a 256-entry cache
with an absolute, non-refreshing 60-second lifetime. Every use and fill checks the
public kernel process-birth time and executable UUID before and after resolution;
changed, exited, unavailable or zero-image signatures invalidate the entry. Missing
metadata is not negatively cached or retried. Initial bundle lookup runs on AppKit's
main queue; repeated reads reuse it only for the same live birth/image signature.
This signature cannot distinguish every exec, including same-image exec, and is not
an OS identity attestation. Apps without a usable signature remain unavailable.

This cache stores no AX control references and does not refresh observation TTLs.
Process association rejects incomplete owned layer-zero rows instead of silently
dropping a sibling. An absent exact CG pair is `targetNotFound`; an existing pair
with unavailable process metadata is a native metadata failure. These per-call
inputs and the later AX reads still do not form an atomic cross-API snapshot.

Each issued reference retains the actual AX control, its observed role/subrole,
and its raw AX identifier. Before a read or action, the runtime rechecks the exact CG target
and metadata, the retained window's `CFEqual` membership in current AX windows,
the control's PID and owning-window link or parent chain, bounded live-tree
membership, and its role/subrole/identifier. Recreated objects, changed identity metadata,
wrong-window refs, and stale session refs are refused. A genuine in-place reorder
may move a control without invalidating it; mutable labels, values, and control
bounds are not treated as identity. Same-role reuse with no changed identifier is
not an observable native generation guarantee.

Collection is bounded to 1,024 tree nodes and depth 32, with at most 256 returned
elements. Unreadable metadata, unknown enabled states, traversal limits, and
export limits produce partial coverage. Enabled state is a required nullable field:
`null` means unavailable, rather than observed disabled. Optional `subrole` identifies
controls such as an unlabelled `AXCloseButton`. Exported labels, identifiers and subroles are capped
at 1 KiB each and values at 64 KiB; oversized strings are omitted rather than
fabricated or truncated into exact values. Encoded elements are bounded to 2 MiB.
An absent value remains distinct from an actual empty string. With
`includeValues: false`, observation does not request `AXValue`.

Missing Accessibility permission produces unavailable coverage. A target with no
unique AX association returns a typed target/ambiguity error. Total and AX-channel
collection intervals describe real read intervals, not an atomic UI snapshot.
Revalidation reduces stale targeting but cannot make public AX validation and
dispatch atomic against an independently changing application.

## Native actions and evidence

`setValue` calls the retained control's settable `AXValue` attribute. `typeText`
requires settable `AXSelectedText` and replaces the existing selection directly;
it does not rewrite the whole value, change selection, post keys, or activate the
app. Expected text edits use the current UTF-16 selection and are rechecked before
dispatch. `press` requires the control to advertise `AXPress`. Each native call
installs a timeout on the exact AX object using the remaining whole-operation
budget. Explicitly disabled controls are refused. A text setter on `AXTextField`
or `AXTextArea` may use a confirmed settable attribute when `AXEnabled` is
specifically unsupported; this proves a
programmatic capability, not enabled state or successful effect. Other unknown
enabled reads remain unsupported, and `press` requires positive enabled state.
An `enabled` predicate stays unknown when the attribute is unsupported.

Explicitly unsupported enabled metadata makes the exported state partial, but
does not by itself make an otherwise fully visited tree incomplete for absence
checks. Unreadable nodes still make negative traversal evidence incomplete.

Action guards and explicit expectations support the same typed conditions as
waits. Every `setValue` also requires an intrinsic exact readback of its
requested value; a caller's explicit expectation is an additional check, including
when it concerns another control. If all required checks are already satisfied,
the receipt can be confirmed with `not_dispatched` and `alreadySatisfied`.

An in-sequence wait is `operation: {kind: "waitFor", params: {condition: ...}}`;
its step-level `precondition` and `expect` must be absent or null. It never sends
input and has no delivery route. If the first check matches, it returns
`alreadySatisfied`; success after polling returns `conditionSatisfied`. Both use
`not_dispatched`, `confirmed`, and timed condition evidence. A zero-match partial
scan does not prove absence; unknown values, enabled states, or incomplete
negative scans remain unavailable. A positive match can establish presence even
when another subtree is unreadable.

An AX `cannotComplete` read can be sampled again only at an existing wait or
post-dispatch readback boundary, within the original deadline and reference TTL.
An unavailable sample is not a false predicate witness. Setters stay outside
these polling loops and are never repeated. Pre-dispatch failures and native
setter errors remain terminal; a later readable value cannot upgrade failed
delivery. Observation preserves readable siblings when one node is unavailable.

`windowAbsent` has empty parameters and refers only to the request's exact
`(pid, windowId)`. It checks a complete `.optionAll` CG list without requiring a
live AX window or app metadata. A hidden/offscreen window that still exists does
not satisfy it. Satisfied standalone window-absence waits return a timed witness
and `observation: null`; creating a replacement observation of a closed window
would be false evidence.

The executor settles an immutable receipt prefix and writes each progress frame
fully before permitting the next input step. A blocked stdout write does not
block cancellation/deadline control. A timer during that barrier preserves the
settled prefix and leaves the next step not dispatched. Cancellation or helper
death after a native handoff still preserves uncertainty; a sequence is not a
transaction and earlier effects are not rolled back.

Delivery (`not_dispatched`, `dispatched`, `unknown`) and verification
(`confirmed`, `mismatch`, `unverified`) remain independent. A successful AX return
establishes dispatch, not effect. The optional `route` records `axSetValue`,
`axSelectedText`, or `axPress` when the native dispatch boundary is entered; it is
absent when no route was used. Confirmed checks establish observed post-state, not
causality. A press without an explicit observable expectation remains unverified.

Actions can read values internally for exact proof without returning those values.
For private-value `typeText`, the runtime does not expose a derived full-value
condition or evidence containing the existing text. It may check the edit
internally and return unverified delivery. Exposed exact-edit evidence requires an
observation that included values or a caller-supplied exact resulting-value
expectation. An incompatible explicit expectation is refused before dispatch.
Explicit caller-supplied `setValue` values remain eligible for exact evidence.

Cooperating helpers for the same OS user share a stable advisory `flock` in that
user's cache directory. A sequence containing mutations holds it across all its
steps, including intervening waits; a pure-wait sequence acquires no mutation lock.
Ownership spans revalidation, native dispatch, and critical
readback, and lasts until physical work returns even if a logical timeout or
cancellation has already sealed its receipt. Closing/crashing the owner releases
the lock; the lockfile is not unlinked. This does not exclude the human user,
legacy helpers, or unrelated automation. No lock spans a model call.

The runtime samples foreground PID before, around, and after background work.
When the controlled app begins in the background, observed activation of that app
stops the sequence. Switching between unrelated apps is allowed and does not
invalidate targeted AX effects. An already foreground target carries no promise
to preserve focus. Unknown foreground samples are refused; samples alone cannot
exclude transient activation or identify the actor. Benchmarks separately record
activation counters or workspace activation events. Cleanup does not overwrite a
known deadline or cancellation with a secondary foreground failure.

## Requested compact feedback

`act.feedback` optionally requests `{elementRefs: [...], includeValues: false}`
for up to 256 unique refs from the original observation. The response's
`feedback` is best effort and independent of settled receipts. `null` means
collection was unavailable or not returned, even if the action completed; it
never means all requested controls were unchanged.

Present feedback names `baseObservationId`, its collection interval, and one
per-control state: `changed`, `unchanged`, `invalidated`, or `unavailable`. Only
`changed` carries an `element`, using the same original reference. The comparison
uses the requested public projection: redacting a value excludes it from the
comparison; explicitly revealing a previously private value can produce
`changed` even when no UI mutation occurred. These states do not establish
causality or add action proof.

The top-level `invalidated` flag means the whole original window/observation
binding is invalid. A removed or reused individual control is marked invalidated
without discarding unrelated refs. Unknown native/read failures are unavailable.
`truncated` reports omitted bounded projection data or an incomplete collection;
it must not be read as unchanged state. Encoded feedback is capped at 2 MiB, and
exported values retain the 64 KiB bound and require explicit `includeValues`.

Feedback neither publishes a new observation nor refreshes the original TTL. It
is collected after critical action readback and may reflect intervening changes
by another actor; collection is not atomic. A deadline during optional feedback
preserves completed delivery/proof and may return null feedback.

## Coordination and cleanup

`cua-client` is the reusable typed Rust boundary. `Client::spawn(Config)` installs
the authority and handshake; `call(body, budget, cancellation)` generates request
IDs and overwrites internal act grants. Public caller control messages are rejected.
The host uses `spawn_with_cancellation` so EOF or signals during the handshake
await native termination and reaping before host exit.
`shutdown()` closes stdin, allows 250 ms for clean EOF exit, then forces termination
if necessary and reaps the helper. A dead connection is not
silently restarted, and mutations are never automatically replayed.

The client serializes requests through a bounded queue. It validates replies and
monotonic progress prefixes against the pending operation, epoch and expectation.
A deadline includes queueing. Cancellation before handoff can establish no dispatch;
after handoff the client reconciles the original reply during a bounded grace period,
then terminates an unresponsive helper. Known receipts survive. Correlated
negative wait receipts also survive host-deadline
reconciliation. A native cancellation caused by the host's deadline is reported
as deadline expiry while retaining its delivery and proof; explicit user
cancellation keeps its own cause. Late satisfied reads cannot extend that
deadline. A protocol violation
reports the known prefix and all unacknowledged action IDs as uncertainty rather
than claiming an untrusted helper left later steps unsent.
An incomplete stdout drain also leaves the entire unacknowledged suffix uncertain.
MCP cancellation can suppress the response in the SDK; native coordination and
cleanup still finish, with receipt metadata in bounded diagnostics. Cancellation
does not establish that no input was sent. A typed Rust caller can consume the
returned receipt directly.

Swift keeps admission/cancellation/deadline timers separate from its serial native
worker and AppKit main run loop. Native reads check one monotonic budget, and retained
AX objects receive a messaging timeout bounded by the remaining budget on each
actual object used; an application timeout is not assumed to cover its children.
An asynchronous timeout does not prove an in-flight OS call stopped. Physical work
continues to consume its queue slot until it actually finishes.
Swift admits at most 16 physical work items and 8 MiB of queued request bytes;
its 4096-ID session history closes with a resource-limit result when exhausted,
requiring a new connection rather than forgetting earlier IDs.

The native observation registry retains at most 32 entries for at most 60 seconds.
Expiry stays absolute during sequences: step, predicate, and mutation-handoff
checks do not restart it, and expired feedback marks the whole binding invalid.
Access does not refresh expiry. A fresh standalone wait observation does not extend
the old observation's refs. Entries and handles belong to one process epoch and
exact target. Cancelled or late observations do not publish handles. EOF, signals or
transport loss invalidate the registry, cancel queued work and close the process.
No AX notification observers or capture sessions are allocated.

Both pipes have bounded frame/output handling. The host observes EOF directly rather
than waiting for the MCP SDK's handler-drain interval. SIGINT/SIGTERM also trigger
native cleanup. Tokio runtime shutdown is bounded because macOS stdin can retain a
blocking read even after a service cancellation.

Diagnostics omit field values: the Rust client retains a 64-entry metadata trace
ring and counts drained stderr bytes; the MCP adapter emits at most 256 timing/route/
receipt records per connection. Raw child stderr is not forwarded. Swift emits
fixed diagnostic codes for invalid input and output failure.
The host admits at most 16 simultaneous tool calls without waiting for a slot;
excess calls receive a pre-dispatch resource-limit result. Validation consumes the
host budget before the remaining time is handed to the typed client.

## Verification and measurements

The [remediation record](evidence/per-7-per-8-remediation-2026-11-16.json) records
the corrected source at `9a539e4`: 266 automated tests passed with no skips,
36/36 native composition trials passed, and rebuilt scripted lanes passed 54/54
conformance trials (36 strict completions, 12 correct refusals, six honest
noncompletions). The legacy reference retained six wrong-target failures in 27
trials. The existing TextEdit composed reference passed 3/3 scripted tasks,
covering 18 persisted target documents and three protected references.

The continuous observer remained available through cleanup and saw no controlled
target activation in the accepted campaigns. Unrelated app switching was recorded
separately. A deliberate target-activation test stopped the next mutation; a
30-run timeout stress test retained the verified prefix and unsent suffix.
These are unpaid conformance checks, not autonomous reliability or speed evidence.

The [historical verification record](evidence/per-7-per-8-verification-2026-11-16.json)
and [paid comparison report](evaluation-results-2026-11-16.md) remain unchanged:
the earlier native campaign passed 30/36 and the matched Claude campaign passed
eight of 18, failed nine and left one unknown. Its failures are not replaced by
the new unpaid results. Post-fix model confirmation remains pending; the user has
put all paid runs on hold until scope and budget approval. No overall speed,
token or cost improvement is established. See the [PER-14 comparison and scope
recommendation](per-14-benchmark-comparison.md) before larger benchmark work.

```sh
npm run build:runtime
npm run test:runtime
python3 runtime/Tests/process-smoke.py
node test/runtime/measure.mjs
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
```

With Accessibility access already granted to the test host, build the disposable
fixture and run the installed semantic campaign:

```sh
sh test/fixtures/macos/build.sh
node test/runtime/semantic-live.mjs --repetitions 3
node test/runtime/composition-live.mjs --repetitions 3
```

This mutates only the fixture's own controls. Each trial uses a fresh fixture
process and separately gates CG registration and successful external AX inspection.
The fixture's `ready` event means native construction completed; it does not prove
that another process can already read its AX objects. Setup attempts, failures,
response bytes, and readiness latency are recorded separately from graded cases.
The runner writes `report.json` and `trace.jsonl` under `.artifacts/semantic-live`
by default; `--output PATH` selects a destination. The runner's `responseBytes`
counts encoded native structured content, excluding MCP wrapping and duplicate
text content; it is not a wire-byte or model-token measurement. See
[fixture.md](fixture.md) for the independent native oracle and coordinate conventions.

The separate 12-scenario composition campaign writes under
`.artifacts/composition-live` by default. It checks mixed/pure waits, immutable
prefixes, stop-on-failure and deadlines, presence/absence, hidden versus closed
windows, requested feedback, and causally gated helper death. `--output PATH`
selects its evidence directory. These deterministic fault checks are separate
from the matched scripted/model comparison in [evaluation.md](evaluation.md).

Subprocess fault tests cover framing, response correlation, deadlines, cancellation,
helper loss, progress receipts and cleanup. Installed-process MCP checks exercise the
copied pair outside the repository, both MCP lifecycles, repeated/concurrent requests,
configured authority, EOF and signals with stdin open. Injected native tests cover
association, retained identity, dispatch/readback, private values, and cooperative
locking. The live fixture campaign separately checks real native effects against
its model/control oracle. Fixture conformance does not establish arbitrary-app or
autonomous task success; model usage and cost belong to the separate evaluation.

`tool_finished.elapsedMs` measures the adapter boundary from argument validation
through typed-client completion. `nativeClientElapsedMs` includes the typed client's
serialization, queueing, private IPC and native work. Their difference estimates
adapter wrapping only; it excludes MCP parsing and response transport. A full MCP
round trip also includes those layers. These timings do not show improved task
completion or isolate Swift work from pipe overhead. These native intervals do not
measure model usage or monetary cost.

The earlier [PER-5/PER-6 verification record](evidence/per-5-per-6-verification-2026-11-14.json)
records 134 passing automated tests and 60/60 live fixture trials (20 scenarios,
three repetitions), with no final setup or cleanup failures. It preserves the two
earlier clean campaigns and their failure dispositions. The three deliberately
killed owners retain unknown delivery; that uncertainty is an expected result.
These are fixture-conformance results, not autonomous or arbitrary-app success.

The earlier [PER-3/PER-4 verification record](evidence/per-3-per-4-verification-2026-11-14.json)
records 91 passing automated tests and native process smoke checks for that earlier
milestone. Its fifty warm
capability queries used one helper and one epoch:

| Measured interval | Median | p95 |
| --- | --- | --- |
| Full MCP round trip | 16.28 ms | 16.76 ms |
| Typed client including native work | 16.06 ms | 16.55 ms |
| Adapter wrapping, excluding MCP transport | 0.0102 ms | 0.0183 ms |

The wrapping distribution comes from each request's nested intervals, not a
subtraction of aggregate percentiles. These results apply to preflight only.
