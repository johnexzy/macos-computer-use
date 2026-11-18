# Selective AX observations and bounded history

PER-12 adds opt-in selective semantic reads and target-window history to the
Rust host/persistent Swift runtime. Default observations keep their existing v1
wire shape. The new options require a matching host/helper pair. This changes
observation collection; it grants no additional input authority.

```json
{
  "target": { "pid": 42, "windowId": 7 },
  "includeValues": false,
  "axSelectors": [
    { "role": "AXStaticText", "identifier": "toast", "label": null }
  ],
  "eventHistory": { "cursor": null },
  "budgetMs": 3000
}
```

`axSelectors` accepts 1–16 unique exact selectors. Role is required; label and
identifier are optional exact constraints. Collection discovers current objects
through a bounded owning-window tree. It reads identity before control metadata
and requests AX values only for matching controls when `includeValues` is true.
This still traverses identities/children: it is not an app-maintained index or a
constant-time query. Selected controls receive new opaque retained references;
actions continue to use exact object, role, subrole and raw identifier checks.

A selected result always reports window `accessibility: partial`. Its separate
`axSelection` reports selectors, visited-node count, query `coverage`, and
`ambiguous`. Complete query coverage means all bounded matching candidates were
discovered and exported; it does not mean the whole window was returned or that
every attribute is available. Duplicate matches remain separate controls, and
ambiguous queries never silently choose an occurrence. An unreadable/unvisited
subtree prevents a complete negative query result.

The collector does not pick the next query or silently widen it. The example
caller policy in `test/selective/policy.mjs` requests a full observation after
query ambiguity, incomplete discovery, stale history, or history overrun. A full
read is itself bounded and may still be partial. Existing PER-9 `cropWindow`,
image limits, and image-to-window/screen transforms can be used with selection;
no screenshot stream, frame-change detector, or separate grounder is introduced.

## What history means

`eventHistory` requires selectors. Its first request starts a history generation;
subsequent requests pass the returned `{generation, sequence}` cursor. The history
contains **observed selected-state changes**, not a lossless UI event log.
Historical controls have role, subrole, identifier, label, nullable enabled,
optional value, and bounds. They have no action references or action affordances.
Use a current observation before acting on a newly discovered control.

Supported AX layout/value/title/move/resize/destroy notifications only wake a
reread. Each recorded change identifies whether notification or polling woke it,
with notification name when applicable, wake time, actual read interval, coverage,
and the resulting selected-control projection. An unavailable/partial read cannot
prove absence. Repeated unchanged reads are not stored; coalesced wakeups and a
sample counter make this work visible.

The tracker uses 500 ms safety polling when any selected/window notification
registration succeeds, or 50 ms fallback polling when none do. Each reread gets
at most 75 ms and still revalidates exact window association. Rereads share the
runtime's serial native worker with observations/actions, so AX object messaging
timeouts cannot race action guards or setters. Notification callbacks perform no
AX reads. Long actions, waits, OS scheduling, unsupported notifications and short
transients can cause misses; this is not continuous capture.

Retention limits are four active windows, 64 state changes and 64 KiB per window,
with at most 16 historical controls and 4096 UTF-8 bytes per value. Oversize
metadata/values are omitted with partial coverage, never truncated into an exact
value. Exported historical values require `includeValues: true`; changing that
privacy scope starts another generation. Encoded limits account for JSON escaping.
The selected query still has the existing 1024-node/256-returned-control bounds.

History has an absolute 60-second lifetime from initial tracking; rereads and
subsequent observations do not refresh it. Changed window association/geometry,
recreation, scope replacement, eviction and shutdown stop tracking. `stale`
marks invalidated bindings or a changed generation, while `overrun` marks a lost
cursor range, including byte/count eviction. Consumers must not infer no events
from a stale/overrun or unavailable history. Cursors are process-local and expire
on helper restart. A cancelled, unpublished replacement does not stop the last
published tracker, and unpublished handles release their own tracker.

## Matched unpaid comparison

The separate disposable AppKit fixture contains a writable result field, 48
unrelated labels, unrelated 25 ms text animation, a transient toast, and a delayed
in-window confirmation group with an AXPress button. It is not a system sheet or
separate modal window. The stdin/stdout oracle journals actual native model/view
transitions independently of Accessibility reads. No existing user app is edited,
no global input is posted, and no activation or permission request is made.

Compile and run pure checks without launching the fixture:

```sh
sh test/fixtures/selective/build.sh
node --test test/selective/selective.test.mjs
swift test
swift test --package-path protocol/swift
cargo test --workspace --all-features
```

On an unlocked desktop, run this explicit live command after building the pair:

```sh
npm run build:runtime
sh test/fixtures/selective/build.sh
node test/selective/run.mjs --repetitions 3 --output .artifacts/selective-observation-live
```

The runner assigns all three lanes per repetition: full, selected, and
selected+history. Lane order rotates; each repetition has the same predeclared
fixture schedule across lanes and fresh fixture/helper processes. Semantic AX
publication is a separate read-only setup gate, with failed setup reads retained.
Each lane writes one field once, waits until the same next observation time, and
acknowledges the delayed dialog once. Failed or unknown mutation receipts stop the
trial; there is no mutation replay.

Strict completion requires independent field/control agreement, one write, one
acknowledgment, a verified toast observation, and independent foreground proof
through helper/fixture cleanup. The report also separates ordinary workflow
completion, missed/false/unknown toast claims, and foreground failure. A toast
read wholly within the oracle visibility interval is true, one disjoint from it
is false, and a read straddling a boundary is unknown. Known fixture activation
or monitor activation vetoes success; missing monitor proof cannot pass.

The JSON report retains all assigned failures and unknowns, source/binary hashes,
per-call latency, actual MCP tool request/response bytes (including setup,
failures, duplicate MCP representation and wider requeries), returned history
sample counters, endpoint CPU/RSS observations for helper/host/fixture/monitor,
and runner CPU. Fixed MCP initialization/notifications are excluded from tool
byte totals. `ps` CPU has centisecond resolution; two RSS endpoints are not peak
memory. History sample counters stop at the last history read, while CPU can also
include samples occurring before cleanup. These are mechanism measurements, not
model token savings. Actual provider tokens, cache reads, cost and autonomous
success remain unmeasured; this runner never invokes a model.

Full and selected snapshots may intentionally miss the between-turn toast while
still completing the field/dialog workflow. The runner exits nonzero on blocked
setup, unknown evidence, false toast claims, unsafe foreground, workflow failure,
or retained-lane failure. No live result is implied by compilation/pure tests.
