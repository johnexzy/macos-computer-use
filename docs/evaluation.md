# Matched fixture evaluation

The [16 November results](evaluation-results-2026-11-16.md) record the completed
repeated campaigns and matched Claude comparison, including failures, cost and
the remaining acceptance gaps.

`test/evaluation/run.mjs` compares the actual legacy MCP server, the rebuilt server
restricted to one action per request, and the rebuilt composed-action API. It uses
the same nine fixture cases, values, common instructions, permissions and controller
budgets across lanes. It rotates lane order by repetition and creates a fresh fixture
and MCP connection for every trial. Scripted runs default to three repetitions.
Model runs predeclare clean, ignored, and two-control cases with two repetitions:
18 assigned tasks across three lanes. `--cases` and `--repetitions` override this
before a campaign starts; budget exhaustion retains remaining assigned tasks.

The cases are clean replacement, duplicate-label selection of the second control,
in-place reorder, same-identifier recreation after observation, ambiguous windows,
ignored and delayed writes, a pre-existing exact value, and a two-control workload.
The two-control case compares controller decisions, CLI-reported turns and API calls with the number of underlying
action receipts. This is a small diagnostic suite; it does not establish general
desktop-agent success or a statistically significant improvement.

## Run

Build both implementations and the fixture before a serialized live run:

```sh
npm run build
npm run build:runtime
sh test/fixtures/macos/build.sh
node --test test/evaluation/*.test.mjs
node test/evaluation/run.mjs --mode scripted --repetitions 3
```

The following preflight makes no model request and launches no fixture. If
authentication is unavailable, every assigned lane/case/repetition remains in the
report as `setup_blocked`.

```sh
node test/evaluation/run.mjs --mode model --preflight
```

For an authorized model campaign, provide a private owner-only regular file
containing a bare API key or a dotenv `ANTHROPIC_API_KEY=...` entry (optional
`export`, single/double quotes and trailing comments). Only that entry is loaded.
Its value is passed in the Claude child's environment;
it is never an argument, report field, key hash, or committed configuration. The
runner accepts modes `0600` or stricter, refuses symlinks, and leaves the file intact.

```sh
node test/evaluation/run.mjs --mode model --model sonnet \
  --api-key-file /absolute/private/key-file --budget-usd 5
```

Claude Code 2.1.233 was inspected locally. Its help supports JSON/schema output,
tool disabling, strict MCP configuration, safe mode, nonpersistent sessions and
`--max-budget-usd`; its parser accepts `--max-turns`. No inference was used to
establish availability. The inspected shell had no configured Claude login or
provider credential environment variables. Availability is checked again per run.

One bounded inference probe resolves the requested alias through the result's
`modelUsage` key. Every subsequent call uses that specific model ID and rejects a
missing, changed or mixed resolved model. No fallback model is configured. The probe,
failed calls and all episode calls retain reported usage and count toward the common
USD budget. Default limits are USD5 total, USD0.10 reserved per CLI call, eight model
decisions per episode, 60 seconds per model call, and 120 seconds per episode.
For an explicit or resolved model ID, the child process pins the main model, all model
family aliases, the current/deprecated background selectors and subagent default to
that same ID. The exact role overrides are retained with each invocation. An initial
alias probe has no exact ID yet and is still rejected if multiple models appear.
Every model call also sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` in its child environment
to skip the background session-title request. These are documented controls recognized
by the installed CLI; observed per-model usage remains the enforcement check.
The child sets `MAX_STRUCTURED_OUTPUT_RETRIES=1`: this CLI setting counts total
structured-output attempts, including the initial attempt. Zero can reject a
decision before generation; one permits the initial attempt without a repair retry.
The attempt bound is recorded per invocation and is identical across all lanes.
The controller reserves 13 seconds for the bounded eight-second MCP call plus
five-second oracle read, clips model time to the remaining budget less that reserve,
and checks admission again before dispatching a tool.
The runner stops further model calls if reported cost is missing or exhausted.
Claude's own USD guard may only stop after a provider request; a reported overshoot
is retained and stops the rest of the campaign. Do not infer a hard provider billing
cap or exact billed cost from these client-side checks.

## Model and API boundary

Claude returns one structured JSON proposal at a time. Builtin tools, skills,
browser integration, hooks/customizations and connected MCP servers are disabled.
The controller, not Claude Code, invokes the selected lane's MCP tools. Each call
passes its actual public schema/result to the model. Common task instructions are
identical; API schemas, observations and their token overhead intentionally differ.
Each turn starts a fresh nonpersistent CLI process with the explicit history so
session memory, compaction and hidden tool execution do not differ across lanes.

The fixture allowlist requires exact IDs from the disposable fixture; it rejects
other windows, app-name routing, screenshots, keys, global input and unrelated
tools. The same controller policy permits one mutation attempt per requested
control and stops automatic replay proposals. This is a harness constraint,
not evidence that the legacy runtime itself enforces retained identity or replay
safety. The legacy lane uses its actual selectors and native inspection/set tools.
Rebuilt mutations must use the first successful case observation ID and references;
new observations/waits may reconcile state but cannot authorize a replacement target.
This explicit controller policy is not a new native identity guarantee. Legacy
selectors retain their actual re-resolution semantics.
Its `wait_for_accessibility` waits for appearance; it is never re-labelled as an
exact-value wait. Legacy has no native whole-request deadline: a transport timeout
does not prove its OS work stopped. The rebuilt single lane advertises and enforces
a cloned one-step act schema; the original native schema is retained for provenance.
The composed lane passes the actual sequence to the rebuilt server, including
read-only exact-value wait steps. Wait steps do not count as mutation attempts.
Other runtime predicates remain outside this model text workload.

## Independent grading and retained evidence

`report.json` and `trace.jsonl` are written under `.artifacts/evaluation/<timestamp>`
unless `--output` supplies a destination. Reports retain source and binary hashes,
common/lane prompt hashes, model/session IDs, actual MCP request/response IDs,
native observation/epoch/action receipts, per-step delivery/verification/routes,
latencies, bytes, independent fixture generations/values/write attempts, and
foreground endpoints/activation counts. Setup and measured case activity are
separate in the trace. Fixture oracle state is never supplied to the model.

The fixture's model and native control values establish completion independently
of AX readback. Every non-goal control and sibling-window press counter is checked.
Writing to a replacement generation is wrong-target dispatch even if its identifier
matches. Infrastructure/API errors are not correct stale/ambiguous refusals.
Expected refusal conformance is separate from strict mutation completion; already
correct values do not prove new delivery. False native confirmation checks or
wrong-target dispatch block the candidate safety gate. Model completion claims are
scored separately, including false and unjudgeable claims. All legacy failures are
reported honestly but do not block the rebuilt candidate's gate. Unknown outcomes,
unjudgeable confirmations, missing repetitions and blocked lanes stay visible.
Earlier composed witnesses that a later dispatched/unknown mutation may change
cannot be graded from the final endpoint. They remain explicitly unjudgeable,
instead of being relabelled false; stable/final-goal witnesses retain exact grading.
Satisfied standalone waits are also checked against the independent oracle.
Native state-confirmation truth uses each read reference's observed generation;
task completion/wrong-target grading separately uses the original selected generation.

Usage sums input/output tokens and cache-read/cache-creation counters from every
`modelUsage` entry, including auxiliary models and failed/rejected calls. Top-level
main-conversation usage is retained separately and never added to those totals.
CLI invocations/controller decisions are distinct from the sum of CLI-reported
`num_turns`; missing CLI turn counts remain null, including paired turn deltas.
Reasoning tokens and independently billed cost remain null. USD figures are explicitly
labelled CLI-reported estimates, including failed calls and the model-resolution probe. No model
campaign has zero token/cost claims merely because it did not run. Per-lane model
cost excludes the separately retained common pin probe; the campaign total includes
it. Foreground endpoint sampling cannot exclude transient or external disruption.

Competing-client, helper-death and predicate/window-transition fault checks belong to
the separate deterministic composition campaign. `--fault-report PATH` records its
artifact path and hash without claiming those faults were model-driven. No precise
kill timing is inferred from a sleep in this model runner.

The Claude controls follow the [official CLI reference](https://code.claude.com/docs/en/cli-reference)
and [programmatic-run documentation](https://code.claude.com/docs/en/headless).
Background/subagent role pinning follows the [model configuration documentation](https://code.claude.com/docs/en/model-config#environment-variables).
Title-request disabling follows the [environment variable reference](https://code.claude.com/docs/en/env-vars).
The [cost documentation](https://code.claude.com/docs/en/costs#using-the-usage-command)
describes dollar totals as locally computed estimates, not authoritative billing.
