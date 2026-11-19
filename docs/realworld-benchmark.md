# TextEdit dispatch-note benchmark

This workload uses the installed macOS TextEdit application and ordinary text
files. It does not replace TextEdit with another custom control fixture. The
content is generated, disposable dispatch data; it is not production customer
information.

The benchmark is capability-gated. Bundle metadata can establish that TextEdit is
installed, but it cannot establish writable AX controls, reliable background
closing, or persistence. A serialized live probe must pass before a controller or
paid campaign is enabled. `test/realworld/run.mjs` supplies a scripted reference
controller and an explicitly budgeted model mode; neither runs during pure tests.

## Task and independent expected result

Each assigned task has six target `.txt` documents and one protected reference
document. Filenames contain a run-specific UUID. The reference filename closely
resembles the first target but is not a target. Input contents are deterministic
for a seed, with randomized order references, three line items per document,
prices, packed quantities, hold reasons, and protected archive tokens.

The model must replace only the text between `--- SUMMARY START ---` and
`--- SUMMARY END ---`. The marker lines and every byte outside that block remain
unchanged. It computes:

- Three line items, total ordered units, and total packed units.
- Subtotal from quantity multiplied by unit price, using integer cents and two
  decimal places without grouping separators.
- `ON HOLD` when a hold reason exists; otherwise `READY` when all units are packed;
  otherwise `PACKING`.

The model then closes each target through its observed close button. The reference
must remain open and unchanged until grading. There are twelve meaningful semantic
operations: six whole-document `setValue` actions and six close-button `press`
actions. An exact value requirement checks each replacement; a `windowAbsent`
expectation checks each close. These predicates are not counted as additional
input operations. Observations and model decisions are counted separately.

`dataset.mjs` generates both manifests. Only `publicManifest` is supplied to the
model. It contains exact filenames, the task, and summary rules. Original contents,
source-fact objects, expected output bodies and hashes remain in
`manifest.private.json`; the model reads source facts through the actual MCP
observation. The oracle never asks a model to judge the result.

## Capability gate

Root-owned setup may create these files and use public `open -g -n -a TextEdit`
to request a separate, background TextEdit instance. This is unmeasured setup,
not a model actuator. The controller must verify the actual PID and document
windows; `open` returning successfully does not establish app readiness or
isolation. It must not route mutations to a pre-existing personal document.

The live scratch-document plus reference probe must establish all of the
following before scaling to six targets:

1. The intended `AXTextArea` is observable with the current typed value/capability
   projection and supports `AXValue` setting. Missing optional enabled metadata
   must remain unknown rather than becoming an invented disabled state.
2. A unique observed `AXButton` with subrole `AXCloseButton` advertises `AXPress`.
   Selection uses role/subrole and an opaque retained reference, never coordinates,
   child order, or a guessed label.
3. Replacing text preserves the same live document/window identity. Title changes
   or normal document state must not silently rebind an old reference.
4. Pressing close on an existing owned UTF-8 `.txt` file persists the exact bytes
   and removes that exact window without activating TextEdit or requiring an
   unsupported save sheet. Both the target file and the reference are checked.
5. Background ownership, deadlines, cancellation and unknown-effect handling stay
   the same as the current Rust/Swift contract. No automatic mutating retry is
   introduced to make this workload pass.

The serialized scratch-document probe passed after nullable enabled state and
subrole projection were corrected: the actual TextEdit text area accepted value
replacement, its close button removed the exact window, persisted UTF-8 bytes
matched, and reference bytes stayed unchanged. The continuous monitor was
available and observed zero controlled-target activations. Local evidence is under
`.artifacts/textedit-probe-74a09f0e-21ae-432c-aed4-544615c500b0/` in
`write-close-report.json` and `trace-write-close.json`. That scratch probe alone
did not establish six-document or model-task success. The runner
rechecks all seven documents' read-only control capabilities before each trial.
If TextEdit requires an unsupported dialog or another action, report the assigned
trial as `setup_blocked` or failed as appropriate. Do not save with AppleScript or another
setup command and report that as end-to-end CUA completion. A future assisted-save
variant would need a different, explicitly disclosed task boundary.

The subsequent clean `9a539e4` composed scripted campaign passed 3/3 six-document
tasks: 18 exact persisted target files and three preserved reference files, with
confirmed closes, no cleanup errors and an available monitor through final stop.
Median measured task time was 3.244 seconds. This private-oracle-informed reference
made no model calls; it provides no autonomous success or model-cost result.
Raw local evidence is `.artifacts/per78-textedit-reference-final/{report.json,trace.jsonl}`;
sanitized hashes and counts are in the [remediation record](evidence/per-7-per-8-remediation-2026-11-16.json).

## Setup, reset and cleanup

The dataset/workspace/oracle support uses Node builtins. The runner reuses the
installed MCP SDK, JSON-schema validator and existing Claude integration; it adds
no provider integration or package dependency. Its foreground helper builds with
the existing Swift6 monitor script during setup.

```sh
node --test test/realworld/*.test.mjs
node test/realworld/workspace.mjs preflight
node test/realworld/workspace.mjs prepare --seed dispatch-1
```

`preflight` only reads TextEdit bundle metadata. `prepare` writes seven files and
private manifests under a new owner-only UUID directory beneath
`.artifacts/realworld`; it does not launch an app. After the live gate is accepted,
root may opt into setup launch with `prepare --seed dispatch-1 --open` or call
`openTextEditSetup(directory)` for an existing prepared workspace. The launch is
still setup activity and grants no model access to OS scripting.

The runner defaults to explicitly labelled, private-oracle-informed actuator
conformance. It is not an autonomous/model success result:

```sh
node test/realworld/run.mjs --mode scripted --lane composed --repetitions 3 \
  --output .artifacts/textedit-scripted-first
```

Use `--lane single`, `composed`, or `both`; the latter reverses lane order on the
second repetition and uses the same seed contents with fresh UUID workspaces.
Every assigned trial stays in the report, including setup blocks and unknown
outcomes. Existing campaign output directories are refused rather than overwritten.
The model mode requires a newly approved scope and explicit budget. All paid
runs are currently on hold; the following is usage documentation, not permission
to spend the prior budget remainder:

```sh
node test/realworld/run.mjs --mode model --lane both --repetitions 2 \
  --budget-usd 2.4 --api-key-file /absolute/private/key-file \
  --output .artifacts/textedit-model-first
```

Only model mode loads the private API file or invokes Claude. It reuses
`apiKeyEnvironment`, `invokeClaude` and `ModelBudget`; probe and failed-call usage
remain in the same estimate. The CLI has no builtin tools or connected MCP. The
model receives public task/rules, actual allowed schemas and owned-window results,
mutation history and bounded conversation history. It receives no private expected
bodies. The limits are 32 decisions, 180 seconds per trial, and 3000ms per native
call. A 20-second admission reserve covers final read-only tool/oracle work. Controller
rejections are returned as not-dispatched feedback, while correlated sent/unknown
or settled input cannot be replayed under a fresh reference alias. Action IDs and
wait/feedback/value bounds are validated before the ledger and MCP handoff.

The model actuator allowlist is the actual Rust/Swift MCP `targets`, `observe`,
`act`, and `waitFor` API, constrained to owned document identities. Each target is
observed immediately before editing so references do not outlive their absolute
TTL. The composed lane can put the replacement and close in one two-step request
for that document. The single lane uses one step per request. The current API
has one target per request, so it must not pretend to batch all six windows into
one transaction.

Only exact owned files can be reset or removed. Call `resetWorkspace(directory,
{documentsClosed:true})` or `cleanupWorkspace(directory,{documentsClosed:true})`
after independently closing all seven owned documents. These functions do not
interact with TextEdit, close windows, terminate apps, or follow file links.
Cleanup retains unrecognized files and its ownership metadata so it can resume
later. It never recursively deletes an unrecognized directory. An interrupted
setup can be cleaned from its ownership record even when a manifest is missing.
The runner's cleanup closes only originally owned windows whose close-control
ledger is provably unsent. It never retries a sent/unknown close or uses an OS-script
save fallback. If capability/ownership was not established or an uncertain close
leaves a window open, it records a cleanup error. All workspace files are retained
on every outcome, including success, for user inspection and reproducible evidence.
The runner never deletes files based on the visible-window catalog.
Cleanup of the protected reference occurs only after its final unchanged/open
state has been recorded. Disk bytes are checked again after typed cleanup, so a
persisted reference-buffer contradiction cannot remain a passing result. The manual
`cleanupWorkspace` API is for later operator cleanup only: `documentsClosed:true`
must follow independent verification that every original owned PID/window key is
absent from the complete CG window list, including hidden/minimized windows. A
visible `targets` result is insufficient proof for deletion. App closure during cleanup is separate setup/cleanup
activity, scoped to owned documents only.

## Oracle and strict task grading

`judgeFiles(directory)` reads disk bytes independently of AX values, model claims,
and action receipts. Every task retains a denominator of six targets and one
reference. Missing, unreadable, linked or mismatching files do not disappear from
that denominator. A changed protected body byte fails even when the arithmetic
summary is correct. The reference must match its original bytes. Unexpected files
in the owned documents directory also fail the file goal.

The result includes hashes and dispositions, not expected text. File bytes alone
are insufficient for strict task success. `gradeTrial` requires separate evidence
that all target windows closed, the reference window and live buffer were
preserved, a known continuous monitor observed no new controlled-target app
activation, the task stayed within budget, and the
controller completed without an unresolved error. Missing evidence stays unknown.
Any known failed requirement prevents strict completion.

All six closes require correlated, completed typed `windowAbsent` confirmation
receipts for their original window keys. Unknown close delivery never becomes a
successful close from an empty visible-window catalog. The monitor's final stop
state is retained and reconciled after cleanup; a late counter/availability
contradiction cannot leave a strict pass. Its phase remains unknown when the event
cannot be attributed to graded work versus cleanup.

Root must supply the app/window/foreground evidence separately. Read-only setup or
oracle automation, if used to inspect TextEdit's document state, must be disclosed
and kept outside the model actuator. The file oracle does not prove the number of
physical disk writes, nor can unchanged disk bytes alone rule out an unsaved edit
to the reference buffer. Native delivery receipts and the controller's no-replay
ledger retain those separate limits. An unrelated app switch is recorded as
interference; it must not be attributed to CUA without evidence. Foreground
endpoint samples cannot exclude every transient activation.

## Measurement and denominator

Run a free scripted capability/conformance trial before admitting paid work.
Predeclare seeds, lane order and the full assigned-task denominator. A small next
comparison can use two matched seeds in the single and composed lanes, with lane
order reversed on the second seed: four assigned tasks, each containing six
independent documents. A blocked setup, budget stop, controller rejection, or
unjudgeable outcome remains visible; it is not replaced by a favorable retry.

Report per task and per lane:

- Strict task success and the six-target/one-reference file outcomes; do not call
  a partial file update a successful task.
- Model decisions, CLI-reported turns, MCP calls and underlying typed action
  receipts, with mutation routes and uncertain delivery distinct from predicates.
- Setup time separately from task wall time, including model, tool and final
  oracle time. Record app/source/binary/dataset/prompt hashes and seed pairing.
- Every input/output/cache-read/cache-creation token counter and CLI-estimated
  cost, including probes, failed calls and rejected proposals. Missing cost stays
  unknown. Estimates do not establish a provider-side hard billing cap.

The arithmetic remainder from the prior USD5 cap is USD2.64089675. The user's
newer instruction requires scope and budget approval before any further paid
run; that remainder is not automatic spending authority. No paid call is
performed by these support modules or pure tests.

Keep this twelve-input real-app regression alongside the proposed PER-14 fixture
benchmark. The existing model mode uses the per-decision harness; a headline
PER-14 evaluation instead needs one actual agent session per trial. See the
[keep/merge/drop recommendation](per-14-benchmark-comparison.md) before extending
either workload. The proposed pilot and main run are not approved here.
