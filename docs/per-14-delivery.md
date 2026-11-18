# PER-14 benchmark delivery

The benchmark compares macOS computer use on invoice entry and settings. The invoice form has 27 fields, one submission and two transition checks. The settings task has 15 controls across three pages and measures whether already-correct settings stay untouched. A disposable AppKit fixture evaluates outcomes from its controls, submission and event journal. The agent receives only the public task and MCP tool results.

The clean and friction trial matrix has 12 assignments: two tasks, two variants and three lanes. The lanes use legacy 3.0.2, the rebuilt host with at most one action per request, and the rebuilt host with up to 16 actions per request. Each seed is paired across lanes. The pilot places every lane at least once in each position. The user-active variant uses two separate disposable foreground actors and runs as an additional unpaid check.

## Build and verify

Use an unlocked Mac with Node 20 or newer, the repository's supported Rust and Swift toolchains, and existing Accessibility access for the CUA executables. Claude Code is required for the loopback and paid session commands.

```sh
npm ci
npm run build
npm run build:runtime
sh test/fixtures/macos/build.sh
mkdir -p .artifacts
node --test test/workflow/*.test.mjs test/evaluation/*.test.mjs
node test/workflow/scripted.mjs --output .artifacts/workflow-readiness
node test/workflow/scripted.mjs --variant user-active --output .artifacts/workflow-user-active
node test/workflow/session-live.mjs .artifacts/workflow-session-smoke
node test/workflow/session-live.mjs --user-active .artifacts/workflow-timed-session-smoke
node test/workflow/session-loopback.mjs .artifacts/workflow-cli-loopback
node test/workflow/pilot.mjs
node test/workflow/pilot.mjs --stage main
```

Run the live commands serially. The user-active check deliberately puts its two test apps in the foreground at defined workflow milestones. The initial handoff can activate only the
owned actor through Accessibility. Subsequent switches use cooperating test
apps. The check yields if the user changes apps and only attempts to restore the original application while a test actor remains in front. Confirmation comes from the independent foreground monitor. The check uses public AppKit calls, where the check and activation can race.

The session smoke drives the actual MCP lanes with a deterministic test process. The user-active session smoke also checks the timer-based actor switches used by the main campaign. The loopback smoke drives the installed Claude CLI with a dummy key and local Messages API. These checks exercise session handling with zero provider inference. Their results establish harness behavior and fixture conformance. Success rate, latency and token cost for an actual agent require the pilot.

## Run the pilot

`pilot.mjs` defaults to printing the trial plan. It requires an explicit execute switch, overall and per-trial dollar-estimate limits, and a new output directory. Use an owner-only API key file for a separately approved API run.

```sh
node test/workflow/pilot.mjs --execute \
  --budget-usd "$PER14_APPROVED_TOTAL_USD" --per-trial-usd "$PER14_APPROVED_TRIAL_USD" \
  --api-key-file "$PER14_PRIVATE_KEY_PATH" --output .artifacts/workflow-paid-pilot
```

Use `--auth terminal` in place of `--api-key-file` to use the installed Claude Code subscription login. Check `/usage` before an included-usage run to verify that the seat has available quota and usage credits are off. The CLI dollar figures estimate API-equivalent cost for comparing lanes. Seat usage is tracked by the subscription.

Each trial starts one Claude Code process with a fixed model, turn limit, wall-clock limit and one scoped MCP server. The campaign owns the live backend and ledger. A replacement stdio relay cannot initiate another connection for the same trial. A known validation clear can permit one correction after a fresh public observation and a settled prior dispatch. Missing delivery evidence stays uncertain across reference refreshes.

The legacy inventory retains the 17 default tool names. Exact owned-window reads and semantic edits are available. App launch, URLs, coordinate input, and separate typing and key routes are listed as restricted. This measures the current lanes under a common disposable background scope. An attempted edit to a disposable Notes control reaches the fixture and fails grading. Legacy continues to resolve selectors through its own implementation.

The report retains the full assigned denominator, independent oracle grade, model claim, tool manifest, session stream, timing, model usage and version hashes. It includes matched trial records and results by task, variant and lane. Dollars per successful task includes the reported cost of failures. If costs are missing or there are zero strict successes, that ratio is unavailable. Unknown spend or a reported cap overshoot stops further admission. SIGINT and SIGTERM stop active input and model work, then write an interrupted checkpoint. The CLI dollar limit is an estimate and can be exceeded by an in-flight request. [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)

## Run the main campaign after pilot review

The [19 November pilot report](per-14-pilot-2026-11-19.md) records the first 12 verified Claude sessions and the resulting controller fixes.

The main plan assigns 180 trials across both tasks, three variants, three lanes and ten seeds per task. Each of the six lane orders occurs ten times across the paired groups. This balances positions and immediate predecessors across the campaign. Execution requires separate main budget approval and a finalized, reviewed pilot. Each pilot assignment needs a distinct session with the pinned model, the expected tool inventory and a reported cost. Failed trials with verified session evidence remain eligible for review. The actor variant schedules two switches at fixed offsets of 750 ms and 2,000 ms after Claude initializes. The monitor must confirm the switches before the session ends. This gives every lane the same timed perturbation without changing which fields it may batch. The report retains actual switch evidence, including missed switches.

The reviewed terminal pilot took 16 minutes and 22 seconds for 12 trials and recorded an estimated API-equivalent cost of USD 3.89. Scaling that pace to 180 trials gives a planning baseline of 4.1 hours and USD 58 in equivalent usage. The 60 user-active assignments and additional seeds can change both estimates. Recheck the seat's available quota and usage credits in `/usage` immediately before an included-usage run.

```sh
caffeinate -di node test/workflow/pilot.mjs --stage main --execute --auth terminal \
  --reviewed-pilot .artifacts/per14-terminal-pilot-015e302/report.json \
  --budget-usd "$PER14_APPROVED_MAIN_USD" --per-trial-usd "$PER14_APPROVED_MAIN_TRIAL_USD" \
  --output .artifacts/per14-terminal-main
node test/workflow/report.mjs .artifacts/per14-terminal-main/report.json > docs/per-14-results.md
```

Publish measured results after reviewing the paired JSON and the rendered tables. The lane summary leads with cost per successful task. The cohort tables show Wilson 95% intervals, latency sample counts, safety assessment coverage, unrelated app switches and pre-handoff refusals. The tool inventory lists the tools advertised to the model and the subset eligible for background use in the fixture. Trials stopped by the turn, time or dollar limit remain in the denominator as budget stops. Deployable Rust/Swift binaries and client migration belong to PER-11. [PER-14 in Linear](https://linear.app/komonapp/issue/PER-14/measure-success-rate-speed-and-token-cost-on-a-realistic-30-50-action)
