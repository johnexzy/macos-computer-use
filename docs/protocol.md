# Rust–Swift protocol v1

This is the internal contract for the rebuild, implemented in `crates/cua-protocol`
and the Foundation-only `protocol/swift` package. The standalone Rust host and
persistent Swift runtime use it for semantic observation and a narrow background
action path; see [runtime.md](runtime.md) for build/run commands and implemented
scope. The contract can represent operations that the current runtime rejects as
unsupported. The existing Node/Swift npm entry point remains separate.

## Boundary and transport

The Rust host owns MCP, public argument validation, host authorization,
end-to-end deadlines, and response correlation. Swift owns macOS objects, exact
window resolution, AX references, capture geometry, and dispatch. No FFI or daemon
is required by this contract. The transport is a private child-process pipe.

Each stdout line is exactly one UTF-8 JSON object followed by LF. Stderr is for
diagnostics. Pretty-printed multiline JSON, CRLF, non-JSON stdout, unknown fields,
and unknown enum variants are rejected. Text newlines are JSON-escaped. Field order
and insignificant number formatting are not canonical. Optional fields may be
omitted or null; both encoders emit null for absent record properties.

Producers emit unique object keys and decimal integer tokens for integer fields.
The shared corpus establishes the listed conformance cases, not identical behavior
for every malformed JSON encoding: Foundation accepts duplicate keys (keeping the
first) and integral spellings such as `1.0`/`1e0`; serde rejects those forms. This
private pipe accepts trusted typed encoders, not raw model JSON. Do not expose the
Swift decoder directly as an untrusted public JSON endpoint. A second handwritten
JSON parser is deliberately outside this foundation.

The codecs enforce an **8 MiB frame limit including LF**, before JSON decoding.
The pipe reader must enforce that same limit while accumulating bytes, rather than
waiting indefinitely for LF. It must distinguish a truncated final frame from a
complete response. Requests and responses have this shape:

```json
{"kind":"request","message":{"version":1,"id":"request-1","epoch":"helper-epoch-1","budgetMs":5000,"body":{"method":"capabilities","params":{}}}}
```

Use `decode_line` / `Frame.decodeLine` and `encode_line` / `Frame.encodeLine` at the
boundary; direct serde/Codable construction alone does not check semantic bounds.
Then use `Response.validate_for` / `validateFor` before consuming a reply. These
check request ID, helper epoch, method, target, and action-prefix accounting.

## Session, authority, and lifecycle

The first request is `hello`, with no epoch, a client name, supported versions, and
an authority grant installed by the trusted Rust host. The helper returns its new
epoch and selected version. V1 requires envelope version 1. Incompatible versions
are rejected before execution; there is no automatic downgrade.

The grant contains an opaque `grantId` and an immutable execution mode. The default
host grant is `backgroundRequired`; `foregroundAllowed` is representable only for
an explicitly host-authorized session. **Public model arguments must never supply
the handshake, grant, or a policy upgrade.** These are internal control messages.
`SessionContext.authorize` rejects another grant, an old epoch, and a second hello.
The host/runtime must call it; the contract alone cannot authenticate a
process that can write to the private pipe.

All later requests carry the helper epoch. References and observations belong to
that epoch and exact `(pid, windowId)`. A helper restart invalidates them. Runtime
limits are **32 retained observations**, **60 seconds maximum retention**, **256
elements per observation**, and **256 returned targets**, with explicit truncation
or partial coverage. The constants are shared and the persistent runtime enforces
retention. Semantic element references are opaque retained AX objects with observed
role/identifier identity, not indices or selectors for a model to reconstruct.
The original 60-second expiry continues during a sequence. Each step/predicate and
mutation handoff checks it; progress, waits, and feedback do not refresh it.

Request IDs are unique within an epoch and are never reused there. Action IDs are
unique within their request. They correlate receipts; they do not make mutations
idempotent across crashes. The runtime rejects duplicate requests rather than
replaying them and closes when its bounded request history is exhausted. Neither
codec alone maintains a session history or durable journal.

`budgetMs` is the remaining deadline budget at IPC send, in `(0, 60000]`. The Rust
host owns the original monotonic deadline and subtracts elapsed time before sending.
Swift starts a monotonic timer at receipt; queueing, dispatch, waits, and verification
consume that same remaining budget. There are no per-step budget resets. Timestamps
on observations are evidence metadata, not execution clocks.

`cancel` targets an earlier request ID. Its reply acknowledges requested/not-found/
already-finished status, not rollback or a guarantee that input stopped. The original
request still has one final response. Stop unsent work; reconcile any dispatched
step. A deadline or helper death after dispatch may leave the result **unknown**.
Late, wrong-epoch, or uncorrelated responses must not attach to another request.

`progress` frames carry the settled, non-failing receipt prefix for an `act` request.
Before starting the next mutation, Swift writes and flushes that prefix. Rust
validates its request ID/epoch/action order and retains it; prefixes must grow by
one and never alter earlier receipts. On EOF the host first drains all complete
frames. It can then preserve the last settled prefix, mark the next unacknowledged
step unknown, and leave later steps unsent. An unknown or failed step is returned
in the final act result, not in progress.

The Rust client implements prefix accounting and rejects rewritten or regressing
progress. If EOF cannot be established within its bounded drain, it returns typed
uncertainty for the whole unacknowledged suffix instead of claiming later steps
were unsent. The current Swift executor accepts 1–16 steps. Prefix admission and
timer finals share control ordering; the native worker waits outside control for
the complete JSONL write before the next input. A timer during that barrier keeps
the settled prefix and leaves the next step not dispatched. A pure-wait sequence
sends no input; mixed sequences preserve the same boundary before later mutations.

## Operations

| Method | Contract |
| --- | --- |
| `capabilities` | Read-only permission booleans, installed mode, and actual supported action kinds. It does not request permission. |
| `targets` | Optionally filter by bundle ID; return exact window/process keys, titles, and logical bounds. `truncated` makes the bound visible. |
| `observe` | Exact target, explicit screenshot/value inclusion flags; return semantic targets and optional image evidence. |
| `act` | Installed grant, observation, exact target, and 1–16 ordered steps. No arbitrary scripts or execution-mode override. |
| `waitFor` | Evaluate a typed condition for the same exact target within the request deadline. It never mutates. |

The current runtime implements `observe` without images and bounded linear `act`
sequences combining `setValue`, `typeText`, `press`, and a read-only `waitFor`
operation. Every step shares the exact target, original observation/refs, and
whole-request budget. There are no branches, nested sequences, or target switches.
Presence checks do not create new action refs inside a sequence.

`WaitOperation` is `{condition: Condition}`. Its enclosing step's `precondition`
and `expect` must be omitted or null. Standalone waits, mutation guards, and
mutation expectations support `elementExists`, `elementAbsent`, `valueEquals`,
`enabled`, and `windowAbsent`.

The action enum also represents supported keys, semantic scroll, and coordinate
click. Coordinate click carries an explicit coordinate
space. It does not authorize global pointer input: background delivery still needs
an exact semantic target; unsupported targeting must fail without silent fallback.
Background keys are initially return/tab/escape/backspace/arrows. Scroll amounts
are signed nonzero units in `[-1000,1000]`; runtime determines support and delivery.
None of these three paths is currently implemented in the new runtime.
Overall `ActionKind` discovery is separate from each element's `ElementAction`
affordances. Coordinate click can be supported without claiming every element has
a semantic click action.

Existence selectors require a role and may constrain label
or identifier. They are conditions, not action locators. Actions use retained refs
or explicitly mapped points; an existence check does not resolve ambiguous labels.
There is no expression language, branching DSL, or rollback API.

`windowAbsent` uses `params: {}` and refers to the request's exact `(pid, windowId)`.
Only absence from a complete `.optionAll` CG-window list establishes it; a hidden,
offscreen, unreadable, or ambiguously associated window is not thereby closed.
It does not require the old AX window to remain readable. Other negative absence
checks require a complete scan; a zero-match partial scan is unavailable. A positive
match can establish presence or disprove absence despite another unreadable subtree.

`ambiguousTarget` is a distinct typed error and terminal receipt reason for unresolved
window/control ambiguity. It must not be collapsed into permission denial, native
failure, or a successful action. This lets verification score an intended refusal
without treating unrelated failures as a pass.

## Observations and geometry

An observation's `collected` interval covers the **whole collection operation**,
not a fictitious atomic snapshot. `accessibilityCollected` records the AX channel's
own interval and each screenshot has its own `collected` interval. These channel
intervals must fit inside the total interval; they can overlap or occur sequentially.
Available AX coverage requires its interval. Unavailable AX may have no interval
when uncollected, or an interval for an attempted collection. An absent screenshot
has no image interval. No channel silently inherits the total timestamp.
Accessibility coverage is complete/partial/unavailable. Partial
coverage must not be treated as proof that an omitted element is absent. Values
are excluded unless explicitly requested. The runtime must enforce that privacy
choice and revalidate target identity/state before input; this package models the
boundary and does not query a Mac.

The current runtime associates AX windows using unique PID, exact logical bounds,
and titles when available, rejecting ties in AX candidates and CG siblings. Public
AX provides no OS-attested `CGWindowID` association or atomic snapshot guarantee.
Catalog calls use one running-application bundle map for every CG row; missing
metadata cannot silently remove a process sibling during association. Exact CG
absence is distinguished from unavailable process metadata.
Each reference retains an actual object plus observed role and raw identifier;
live `CFEqual` tree/window membership, ownership, role, and identifier are checked
before use. Changed labels, values, or control positions do not remap the reference.
An unchanged role/identifier is not a native object-generation guarantee.

Observation traversal is bounded to 1,024 nodes/depth 32 and 256 returned elements.
Unreadability, unknown enabled states, traversal bounds, or omitted oversized
exports produce partial coverage. Labels/identifiers are capped at 1 KiB, values at
64 KiB, and encoded elements at 2 MiB. Omitted values are not empty strings. Values
excluded from observation are not requested through `AXValue`; internal action
proof can read values without adding them to returned observations or diagnostics.

Window and element rectangles use top-left-origin logical screen points and may
have negative origins. Returned screenshots have independent pixel dimensions.
`imageToScreen` maps `(x,y)` to:

```text
screenX = imageX * scaleX + offsetX
screenY = imageY * scaleY + offsetY
windowX = screenX - windowBounds.x
windowY = screenY - windowBounds.y
```

No global Retina constant or main-display origin is assumed. `validImageBounds`
is a half-open rectangle in returned image pixels. Complete mapping must cover
the whole image; partial mapping covers only the declared region. `to_screen` /
`toScreen` rejects points outside that region. A missing image or mapping cannot
be reconstructed by guessing. The runtime must reject image-coordinate clicks
without that observation's valid mapping and invalidate mappings after target
geometry changes. Positive axis scales describe the initial non-rotated window
capture contract; rotated/perspective transforms are not represented.

Inline screenshot payloads use standard padded base64 and are capped at **4 MiB
decoded bytes**. Codecs validate base64, dimensions, and transform domains; they
do not decode PNG/JPEG pixels or prove that image contents match the metadata.
The capture implementation must do that. Shared fixtures deliberately use a short
PNG signature as transport data, not a complete image file.

## Delivery, verification, and prefix receipts

Delivery and verification are independent:

| Delivery | Meaning |
| --- | --- |
| `not_dispatched` | No action was sent for that step. |
| `dispatched` | Input/API mutation was sent; this alone says nothing about its intended effect. |
| `unknown` | The host cannot establish whether input was sent/completed, for example after helper loss. |

Verification is confirmed/mismatch/unverified and points to explicit condition
evidence. Confirmed requires nonempty, consistently matching evidence; mismatch
requires failed evidence. A failed/rejected step is terminal and its reason matches
the sequence stop reason.
An already-satisfied condition may be confirmed with `not_dispatched` and the
`alreadySatisfied` reason. It must never be called newly delivered input. Dispatch
uncertainty stops the sequence even when expected-state evidence is confirmed.
Here **confirmed means the recorded condition was observed**, not causal proof
that the action produced it. Delivery `unknown` never becomes `dispatched` merely
because the desired state is present. Fresh wait/observe reconciliation can add
state evidence without rewriting the original delivery history.

A successful read-only wait step always has `not_dispatched`, `confirmed`, no
route, and timed evidence for its own condition. `alreadySatisfied` means the first
check matched; `conditionSatisfied` means a later check matched. Both are successful
non-failing receipts and can belong to a settled prefix. A wait can never claim
dispatched or unknown input. `CheckEvidence.collected` is optional for older/general
records but required for settled wait proof.

`WaitResult.evidence` optionally carries the typed condition witness. A satisfied
non-window wait still requires a fresh value-private observation. A satisfied
`windowAbsent` result instead requires a matching true witness with a valid
collection interval and `observation: null`; no observation or fresh control refs
are fabricated for the closed window. `alreadySatisfied` on standalone waits uses
the same first-check meaning.

`StepReceipt.route` is optional. The current executor records `axSetValue`,
`axSelectedText`, or `axPress` at the dispatch boundary; an absent route does not
invent a native method. `typeText` uses targeted `AXSelectedText` replacement of
the current UTF-16 selection, not a whole-value rewrite, keyboard fallback, or
selection-changing operation. It requires the advertised settable attribute.

Every `setValue` requires exact-value proof for its own requested value, in addition
to any caller-supplied `expect`. Correlation checks must account for both; a passing
unrelated expectation cannot confirm an ignored value write. For `typeText` with
private existing values, no derived full-value condition/evidence is exported.
An exact resulting value can be exposed as evidence only if values were included
in the originating observation or the caller supplied that exact expectation.
Otherwise delivery can succeed with unverified public evidence even when internal
readback matches. A press with no expectation likewise does not prove its effect.

`ActResult.steps` is the processed prefix, including a rejected final step when
applicable. `remainingSteps` counts steps never processed. Correlation checks require
prefix action IDs to match the original request and account for every requested
step. The root `ActResult.observationId` and `Progress.observationId` identify the
originating act observation and must match the request. Fresh verification
observations belong in each check's evidence ID. Completed prior mutations remain
in the receipts if a later step fails.
Required verification mismatch stops the sequence. A `completed` sequence means its
steps were processed, not that the user's whole task was independently completed.

The current Swift runtime serializes revalidate → dispatch → critical readback
across cooperating helpers for the same OS user with one stable advisory `flock`.
It holds the lock across all steps of a mixed sequence, including waits; a pure-wait
sequence needs no mutation lock.
It holds ownership until physical work returns, even when a logical timeout or
cancellation has already sealed a receipt. Owner close/crash releases the lock;
the inode is not unlinked. This excludes neither the user nor unrelated automation.
No lock spans a model call. The wire contract alone is not a locking implementation.

## Requested projection feedback

`ActRequest.feedback` is optional `FeedbackRequest {elementRefs, includeValues}`.
Refs must be unique and number at most 256. `ActResult.feedback` is optional
`ObservationFeedback {baseObservationId, collected, controls, invalidated, truncated}`.
When present, its base must match the original act observation, returned refs must
be requested refs, and values require explicit inclusion. Missing requested refs
require `truncated: true`.

Each `ControlFeedback` has `{elementRef, state, element}`. State is one of
`changed`, `unchanged`, `invalidated`, or `unavailable`. Only changed state carries
an `Element`, and that element must preserve the same base reference. Changed means
the requested bounded public projection differs from the base, not that this action
caused a UI change. Explicitly revealing a previously private value can change the
projection without any mutation; values excluded by the request are redacted from
both sides of the comparison.

Top-level `invalidated` means the whole base window/observation binding is invalid,
so it cannot carry live feedback. An individual removed/reused control can be
invalidated while unrelated refs remain live and the summary flag stays false.
Unknown reads produce unavailable status. The feedback payload is capped at 2 MiB;
label/identifier/value export limits still apply. Truncation and unavailable or
invalidated controls are not unchanged controls.

Feedback is best effort and separate from delivery/proof. `feedback: null` is valid
even for a completed request and means collection was unavailable or not returned;
it is not an all-unchanged result. Present feedback remains fully validated, and
unrequested feedback is rejected. It publishes no new observation, creates no refs,
does not refresh the base TTL, and cannot turn unknown delivery into confirmed
dispatch. Optional collection timing/failure must not erase settled receipts.

Response/progress correlation also binds verification to each requested `expect`:
confirmed/mismatch requires evidence for that exact condition, not a passing guard
or unrelated value. Settled progress, earlier processed steps, and completed results
cannot leave a required expectation unverified. A terminal timeout/cancellation/
helper-death receipt can preserve unverified effects. Independent negative evidence
can coexist with unknown delivery and the original timeout/helper-death reason;
it does not rewrite the delivery history or imply rollback.

Unknown dispatch, delivered-but-unverified effects, and partial mutation **must not
be automatically replayed**. Re-observe and reconcile first. Cancellation cannot
undo sent input. Generic error responses are for pre-dispatch request rejection or
read-only failure; once mutation might have happened, preserve an act receipt. If
the helper dies without one, the Rust host synthesizes the known prefix plus an
unknown final step rather than pretending the request was rejected.

## Conformance and checks

`protocol/fixtures/valid` and `invalid` are consumed by both implementations. They
cover handshake, every public operation, forged policy fields, invalid bounds,
partial collection/mappings, partial mutation, rejected input, timeout/helper death,
already-satisfied checks, and malformed receipt prefixes. Both suites decode and
round-trip valid frames and reject invalid frames. Additional tests exercise session
authority/epochs, response correlation, framing bounds, and coordinate conversion.

```sh
cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path protocol/swift --scratch-path /tmp/macos-cua-protocol-swift-build
```

These checks establish the contract and decoding behavior. Runtime/injected tests
and the isolated live fixture campaign separately check dispatch, retained identity,
exclusion, deadlines, and independent native outcomes; see [runtime.md](runtime.md).
Neither contract tests nor fixture conformance establishes arbitrary-application
task success or image fidelity.
