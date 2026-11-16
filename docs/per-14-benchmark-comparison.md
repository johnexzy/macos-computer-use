# PER-14 scope recommendation

Reviewed 16 November 2026 against [PER-14](https://linear.app/komonapp/issue/PER-14/measure-success-rate-speed-and-token-cost-on-a-realistic-30-50-action) and the preserved TextEdit implementation. This is a proposal for approval, not an approved implementation or spending plan. All further paid model runs, including post-fix PER-7/PER-8 confirmation, remain on hold.

Use the extended fixture for the main agent benchmark. Keep TextEdit as a separate real-application compatibility regression. These answer different questions: the fixture measures a controlled workflow with observable faults; TextEdit checks actual document editing, persistence and closing.

## What is already verified

At clean source `9a539e4`, unpaid native composition passed 36/36 trials and rebuilt scripted lanes passed 54/54 conformance trials. The latter comprise 36 strict completions, 12 correct refusals and six honest noncompletions. They are not a 100% autonomous task-success result. The legacy reference passed 21/27; its six wrong-target failures remain recorded.

The existing TextEdit composed reference passed 3/3 scripted tasks: 18 target documents had exact persisted bytes and confirmed closes, and three protected references were preserved through grading and cleanup. Each task has six value replacements and six close presses: **12 input operations**, not 30–50. Median measured task time was 3.244 seconds; there was no model inference. The reference uses private expected answers and therefore establishes actuator conformance, not autonomous reasoning or model cost.

See the [remediation evidence](evidence/per-7-per-8-remediation-2026-11-16.json) and [TextEdit specification](realworld-benchmark.md). The historical paid comparison remains unchanged; post-fix model performance has not been measured.

## Keep, merge, change

| Decision | Recommendation |
| --- | --- |
| Keep | T1 invoice entry as the main workflow; T2 settings as a separate precision task. Keep clean, friction and user-active variants, strict independent grading and dollars per successful task. |
| Keep | One actual Claude Code agent session per trial, with only that lane's MCP server. Keep the current per-decision harness for receipt and replay regressions. |
| Keep | TextEdit as a real-app regression. Do not enlarge it by repeating documents solely to reach an action count. |
| Merge | Fresh seeded workspaces, private expected results, protected decoys, full assigned denominators, original target identities, receipt accounting, retained failures/files, and source/binary/prompt/tool-schema hashes from the existing work. |
| Merge | The independent continuous foreground observer through cleanup. Count activation of the controlled app separately from switches among unrelated apps. Missing monitoring cannot establish background success. |
| Change | Explicitly specify correction, recreated-row and formatting behavior before building friction. They currently conflict with assumptions in the small safety harness. |
| Defer | Return/Tab/Escape and other new actuators. The existing four operations already support the verified TextEdit path. Probe checkbox/tab capabilities before promising T2 support. |
| Drop | The causal claim that fresh CLI processes explain zero cache reads, the implication that ten repetitions ensure separation, and the linear extrapolation from two writes as an approved budget. |

The full legacy tool surface should be disclosed. Comparing it with the smaller rebuilt surface measures the current products, not the isolated effect of Rust or composition. Single versus composed is the cleaner composition comparison. Do not add extra benchmark arms to the pilot.

Declare the action denominator explicitly: T1's proposed 27 writes, one press and two waits are about 30 typed steps, of which 28 send input. T2 is a precision task with fewer necessary mutations. Report waits, observations and mutations separately; do not pad either task to manufacture a 30–50 input count.

## Resolve these contracts first

**Recovery.** A validation error that visibly clears a field can justify a new corrective action after fresh observation. A recreated row requires a new reference and verified identity. Unknown delivery still forbids a blind retry. The small harness's rule against reusing a sent control cannot become a permanent ban on legitimate correction, nor can a fresh reference erase an uncertain prior action.

Predeclare the friction triggers for each paired seed and record when they fire. Prefer causal triggers over arbitrary wall-clock timing so different lane speeds do not silently receive different faults.

**Reference lifetime.** The runtime retains references for an absolute 60 seconds, permits at most 16 steps per request and binds each request to one window. A long trial must observe again when necessary. Composition batches only eligible same-window work; source, form and confirmation windows require separate target bindings. Do not inflate TTL or call a multi-window task one transaction.

**Formatting.** Native `setValue` requires exact intrinsic readback. Sending `12.5` to a control that returns `12.50` is a mismatch under that contract. Declare accepted canonical input and any subsequent read-only reconciliation in advance. A semantically correct fixture field does not retroactively turn the original exact receipt into a confirmed write.

**Precision.** T2 must record attempts as well as final values. Already-correct controls must stay untouched; a redundant setter is a precision failure even if final state is correct. Independently prove the actual AX actions/value types for tabs and checkboxes before choosing their fixture implementation.

**Authority and privacy.** Permit only the lane's actual MCP tools against the owned fixture. The source invoice is readable to the agent; expected submissions and private oracle counters are not. Use the same owned-resource boundary across lanes and record the exact available tools. A completion claim is graded separately from the oracle result.

## Staged run recommendation

1. After scope approval, implement the fixture and actual-session harness with one implementation owner and independent read-only review. Complete unpaid capability, oracle, unknown-delivery and user-active readiness checks.
2. After explicit budget approval, run the **12-trial pilot**: two tasks × clean/friction × three lanes × one repetition. Pair seeds and rotate lane order. This is a feasibility and cost pilot, not a reliability estimate. Retain every assigned outcome; do not replace failures with favorable retries.
3. Review actual usage, failures, reference refreshes, cache hits and budget stops. Resolve pilot defects in a separately identified revision before proposing the main run.
4. Seek separate approval for the proposed **180-trial main run**: two tasks × three variants × three lanes × ten repetitions. Report T1 and T2 separately. A later TextEdit agent evaluation would be its own approved campaign, not pooled with fixture success.

No pilot or main-run budget is approved here. Historical cumulative CLI-estimated spend is **$2.35910325** against the earlier $5 cap; the arithmetic remainder is $2.64089675. The user's newer hold prevents spending that remainder automatically. The two-write results cannot reliably price a 27-write adaptive session. The pilot must replace that extrapolation with observed costs before main-run approval.

## Measurement corrections

The headline metric per task/variant/lane is:

`(all assigned trial costs + disclosed allocated campaign overhead) / strict successful tasks`

Include failed calls, unknowns, controller rejections and budget-stopped trials. Report shared probe/setup inference separately and disclose its allocation. With zero successes the ratio has no finite value; do not report $0. CLI-reported dollars are estimates unless independently reconciled with provider billing. Model-call admission limits are not provider-side hard billing guarantees.

Record success with a Wilson 95% interval; field accuracy is diagnostic and does not create additional independent trials. For illustration, 8/10 yields about 49.0–94.3% and 5/10 yields 23.7–76.3%. Ten repetitions remain exploratory; a claimed effect needs an appropriate comparison and sample-size decision. These intervals were calculated using the [NIST Wilson formula](https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm).

Report wall time including model/tool/final grading, with unmeasured setup separate; median and p90, turns, MCP calls, mutations, waits, refusals and unnecessary writes. Keep budget stops visible in latency reporting. Action count and fewer round trips alone do not establish lower token cost.

One growing agent session per trial is the right workload model. [Claude Code supports session execution, tool restrictions and turn/budget controls](https://code.claude.com/docs/en/cli-reference); verify the installed version's flags without inference before admission. Preserve all-model token and cost accounting and avoid double-counting cumulative stream summaries.

The prior campaign observed 492,063 cache-creation tokens and zero cache-read tokens. That observation does not identify the cause. [Anthropic caching depends on matching eligible prompt prefixes and cache lifetime/configuration](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), rather than a local process identity. A new process can hit a cache; a persistent session can miss. Record actual read/write counters, stable prompt/tool ordering, cache configuration, timing and lane order. Do not label a trial cold or warm solely from its CLI PID.
