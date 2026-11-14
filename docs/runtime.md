# Rust host and persistent Swift runtime

The rebuild now has a standalone Rust MCP executable and one persistent Swift child
per connection. PER-3 owns coordination and PER-4 owns the native process lifecycle.
These executables use protocol v1 from [protocol.md](protocol.md).

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
The existing entry point remains available for the PER-1 comparison while semantic
operations are completed.

The official [rmcp 3.10.0 SDK](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.10.0)
is pinned. It supports MCP revision 2026-07-28 with per-request metadata/discovery
and older initialization sessions including 2025-11-25. The SDK handles negotiation;
the private Rust–Swift protocol has its own version and epoch.

## Implemented operations

| MCP tool | Current native behavior |
| --- | --- |
| `capabilities` | Read permission booleans and installed mode without permission prompts; supported action list is empty. |
| `targets` | Return at most 256 visible, layer-zero windows with bundle IDs and exact process/window keys. |
| `observe` | Revalidate the CG process/window pair, retain an application AX handle when permitted, and return lifecycle metadata with AX coverage unavailable and no elements. Images are unsupported. |
| `act` | Return an unsupported, not-dispatched receipt prefix. No native input is sent. |
| `waitFor` | Return an unsupported error; predicate evaluation follows semantic observations. |

Exact CG-to-AX window binding, live control references and semantic dispatch remain
PER-5/PER-6. The lifecycle observation is not an AX tree and cannot establish that
a control exists or that an action is possible. The runtime does not route around
missing capabilities through the legacy selector or global-input paths.

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
AX application objects receive a messaging timeout bounded by the remaining budget.
An asynchronous timeout does not prove an in-flight OS call stopped. Physical work
continues to consume its queue slot until it actually finishes.
Swift admits at most 16 physical work items and 8 MiB of queued request bytes;
its 4096-ID session history closes with a resource-limit result when exhausted,
requiring a new connection rather than forgetting earlier IDs.

The native observation registry retains at most 32 entries for at most 60 seconds.
Access does not refresh expiry. Entries and handles belong to one process epoch and
exact target. Cancelled or late observations do not publish handles. EOF, signals or
transport loss invalidate the registry, cancel queued work and close the process.
No AX observers or capture sessions are allocated in this milestone.

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

Subprocess fault tests cover framing, response correlation, deadlines, cancellation,
helper loss, progress receipts and cleanup. Installed-process MCP checks exercise the
copied pair outside the repository, both MCP lifecycles, repeated/concurrent requests,
configured authority, EOF and signals with stdin open. Native tests use read-only
queries or injected providers; they do not establish semantic action outcomes.

`tool_finished.elapsedMs` measures the adapter boundary from argument validation
through typed-client completion. `nativeClientElapsedMs` includes the typed client's
serialization, queueing, private IPC and native work. Their difference estimates
adapter wrapping only; it excludes MCP parsing and response transport. A full MCP
round trip also includes those layers. These timings do not show improved task
completion or isolate Swift work from pipe overhead. Model usage and monetary cost
remain unmeasured.

The [2026-11-14 verification record](evidence/per-3-per-4-verification-2026-11-14.json)
records 91 passing automated tests plus native process smoke checks. Fifty warm
capability queries used one helper and one epoch:

| Measured interval | Median | p95 |
| --- | --- | --- |
| Full MCP round trip | 16.28 ms | 16.76 ms |
| Typed client including native work | 16.06 ms | 16.55 ms |
| Adapter wrapping, excluding MCP transport | 0.0102 ms | 0.0183 ms |

The wrapping distribution comes from each request's nested intervals, not a
subtraction of aggregate percentiles. These results apply to preflight only.
