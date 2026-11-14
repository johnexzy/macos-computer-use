# Rust host and persistent Swift runtime

The rebuild has a standalone Rust MCP executable and one persistent Swift child
per connection. PER-3/PER-4 provide coordination and lifecycle; PER-5/PER-6 add
retained semantic observations and a narrow background action path. These
executables use protocol v1 from [protocol.md](protocol.md).

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
| `observe` | Associate the exact CG target with one AX window; return at most 256 controls with retained opaque references, bounds, actions, labels, and optional identifiers. Values require `includeValues: true`; images are unsupported. |
| `act` | Execute one retained-control `setValue`, `typeText`, or `press` step. Revalidate identity, enabled state, and the actual native affordance before dispatch. |
| `waitFor` | Poll an exact `valueEquals` condition on a retained reference within the original budget; a satisfied result includes a fresh observation with values excluded. |

Screenshots, OCR, keys, scrolling, coordinate input, existence/absence waits, and
multi-step execution remain unsupported in the new runtime. The wire format can
represent more operations than this implementation executes. It does not route
around missing capabilities through legacy selectors, activation, or global input.

## Observation and reference validity

The public AX API does not expose an OS-attested mapping from `CGWindowID` to an
AX window. Association therefore requires the same PID, exact logical bounds, and
compatible titles when available. Both AX candidate ties and equivalent CG
siblings are rejected. A missing AX title cannot distinguish equal-bounds CG
siblings with different titles. There is no nearest-window scoring or private API.

Each catalog read takes one visible CG-window list, then resolves its distinct
owner PIDs once on the AppKit main queue using `NSRunningApplication(pid:)`. All
rows share that immutable PID-to-bundle map. The main queue performs no explicit
AX calls or input for this metadata read, and the separate logical deadline stays
active while the worker waits. No process metadata is cached or retried across
calls. Process association rejects incomplete owned layer-zero rows instead of
silently dropping a sibling. An absent exact CG pair is `targetNotFound`; an
existing pair with unavailable process metadata is a native metadata failure.
These coherent per-call inputs still do not form an atomic cross-API snapshot.

Each issued reference retains the actual AX control, its observed role, and its raw
AX identifier. Before a read or action, the runtime rechecks the exact CG target
and metadata, the retained window's `CFEqual` membership in current AX windows,
the control's PID and owning-window link or parent chain, bounded live-tree
membership, and its role/identifier. Recreated objects, changed identifiers/roles,
wrong-window refs, and stale session refs are refused. A genuine in-place reorder
may move a control without invalidating it; mutable labels, values, and control
bounds are not treated as identity. Same-role reuse with no changed identifier is
not an observable native generation guarantee.

Collection is bounded to 1,024 tree nodes and depth 32, with at most 256 returned
elements. Unreadable nodes, omitted unknown enabled states, traversal limits, and
export limits produce partial coverage. Exported labels and identifiers are capped
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
budget. Unknown or disabled enabled states are refused.

Action guards and explicit expectations currently support `valueEquals` and
`enabled`. Every `setValue` also requires an intrinsic exact readback of its
requested value; a caller's explicit expectation is an additional check, including
when it concerns another control. If all required checks are already satisfied,
the receipt can be confirmed with `not_dispatched` and `alreadySatisfied`.

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
user's cache directory. Ownership spans revalidation, native dispatch, and critical
readback, and lasts until physical work returns even if a logical timeout or
cancellation has already sealed its receipt. Closing/crashing the owner releases
the lock; the lockfile is not unlinked. This does not exclude the human user,
legacy helpers, or unrelated automation. No lock spans a model call.

The runtime samples foreground PID before, around, and after background work and
fails on observed change. These samples do not prove the absence of transient or
external foreground changes. An absent foreground baseline is refused.

## Coordination and cleanup

`cua-client` is the reusable typed Rust boundary. `Client::spawn(Config)` installs
the authority and handshake; `call(body, budget, cancellation)` generates request
IDs and overwrites internal act grants. Public caller control messages are rejected.
`shutdown()` closes stdin, allows 250 ms for clean EOF exit, then forces termination
if necessary and reaps the helper. A dead connection is not
silently restarted, and mutations are never automatically replayed.

The client serializes requests through a bounded queue. It validates replies and
monotonic progress prefixes against the pending operation, epoch and expectation.
A deadline includes queueing. Cancellation before handoff can establish no dispatch;
after handoff the client reconciles the original reply during a bounded grace period,
then terminates an unresponsive helper. Known receipts survive. A protocol violation
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
Access does not refresh expiry. Entries and handles belong to one process epoch and
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

Subprocess fault tests cover framing, response correlation, deadlines, cancellation,
helper loss, progress receipts and cleanup. Installed-process MCP checks exercise the
copied pair outside the repository, both MCP lifecycles, repeated/concurrent requests,
configured authority, EOF and signals with stdin open. Injected native tests cover
association, retained identity, dispatch/readback, private values, and cooperative
locking. The live fixture campaign separately checks real native effects against
its model/control oracle. Fixture conformance does not establish arbitrary-app or
autonomous task success, and model tokens/cost remain unmeasured.

`tool_finished.elapsedMs` measures the adapter boundary from argument validation
through typed-client completion. `nativeClientElapsedMs` includes the typed client's
serialization, queueing, private IPC and native work. Their difference estimates
adapter wrapping only; it excludes MCP parsing and response transport. A full MCP
round trip also includes those layers. These timings do not show improved task
completion or isolate Swift work from pipe overhead. Model usage and monetary cost
remain unmeasured.

The [PER-5/PER-6 verification record](evidence/per-5-per-6-verification-2026-11-14.json)
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
