# PER-7 / PER-8 evaluation — 16 November 2026

The requested repeated runs and matched Claude comparison are finished. Milestone
acceptance remains incomplete. The deterministic rebuilt lanes passed all 54
scripted trials, but the native fault campaign retained six failures and the model
controller retained three rejected proposals and one unknown episode. These
results support the native identity and receipt boundaries; they do not establish
reliable autonomous completion or an overall speed/token improvement.

The [verification record](evidence/per-7-per-8-verification-2026-11-16.json)
contains source/binary hashes, report/trace hashes, denominators, accounting and
failure dispositions. The [14 November record](evidence/per-7-per-8-verification-2026-11-14.json)
retains the earlier failed, blocked and development campaigns. Raw fixture and
model traces remain local under `.artifacts/`; no credential values are recorded.

## Repeated native and scripted runs

The native composition campaign assigned 12 scenarios three times: **30/36
passed**, six failed, with no setup or cleanup errors. Five failures were foreground
endpoint assertions. The sixth returned `nativeFailed` just before a 500 ms
deadline instead of the expected timeout; its foreground also changed. The error
source is unresolved. An early native error must not be relabelled as a timeout.

The independent fixture oracle found no unintended changes across either window.
All nine helper-death cases identified and killed the actual Swift child at their
causal gates. The verified prefix and uncertain active action were preserved;
remaining mutations stayed unsent. Foreground failures remain failures even where
these delivery checks passed. Fixture activation stayed zero, which does not
establish the cause of a foreground change.

The scripted campaign assigned nine cases, three lanes and three repetitions:

| Lane | Conformant trials | Strict goal completions | Correct refusals | Honest ignored-write outcomes | Wrong-target trials |
|---|---:|---:|---:|---:|---:|
| Legacy | 21/27 | 18 | 0 | 3 | 6 |
| Rebuilt single-step | 27/27 | 18 | 6 | 3 | 0 |
| Rebuilt composed | 27/27 | 18 | 6 | 3 | 0 |

The six legacy wrong-target trials were recreation and ambiguous-window cases,
three each. All 18 rebuilt lane/case groups passed every repetition. All 78
rebuilt confirmation claims matched the independent oracle. There were no
unknown confirmations, foreground changes, setup blocks or cleanup errors in
this scripted campaign. Correct refusal and honest noncompletion are conformance
outcomes, not completed mutations.

## Matched Claude comparison

The model workload was declared before execution: clean replacement, ignored
write and two controls, each repeated twice across all three lanes. All **18
assigned trials ran** with no setup blocks. Claude Code 2.1.233 used only
`claude-sonnet-5`. Its builtin tools and connected MCP servers were disabled;
the fixture controller invoked the actual lane APIs. Task instructions, controller
limits and the one-mutation-attempt policy were common. Rebuilt requests used a
three-second native budget; legacy appearance waits were capped at three seconds,
but legacy setters have no equivalent native deadline. An external transport
timeout does not establish that legacy input stopped. Public schemas and
observation sizes intentionally differed.

| Lane | Conformant trials | Failed | Unknown | Strict goals, of 4 eligible | Controller decisions | CLI turns | Task cost estimate |
|---|---:|---:|---:|---:|---:|---:|---:|
| Legacy | 3/6 | 3 | 0 | 2/4 | 22 | 44 | $0.448310 |
| Rebuilt single-step | 2/6 | 3 | 1 | 2/4 | 23 | 46 | $0.898349 |
| Rebuilt composed | 3/6 | 3 | 0 | 2/4 | 21 | 42 | $0.794564 |

The original strict result is **8 passed, 9 failed, 1 unknown**. The rebuilt
candidate gate remains `incomplete`. No native false confirmations, unknown
confirmations or wrong-target dispatches were observed in this model workload.
All 16 runtime confirmation claims matched the independent oracle: ten rebuilt
and six legacy.

Eight trials changed foreground endpoints; fixture activation remained zero in
all eight. Four model `complete` claims consequently failed the strict metric,
although all four had correct requested values and no unintended control changes.
Thus the recorded strict false-completion count is four; false goal-state claims
were zero among ten `complete` claims. This explanation does not remove the four
strict failures or attribute the foreground changes to a particular actor.

The controller rejected three proposals: one omitted the required native budget,
and two requested a repeated mutation. The budget omission reached no native
action. Neither replay proposal caused an extra write. One replay followed a
known ignored setter and left the episode `unknown` under the predeclared
controller-error policy. That is an unknown controller outcome, not an unknown
native delivery receipt. Another followed a confirmed first write and an unsent
second write after a native failure.

| Lane | Uncached input | Cache creation input | Cache read input | Output |
|---|---:|---:|---:|---:|
| Legacy | 44 | 99,114 | 0 | 5,100 |
| Rebuilt single-step | 46 | 207,555 | 0 | 7,992 |
| Rebuilt composed | 42 | 184,234 | 0 | 6,904 |

Task costs exclude the common pin probe. Including that probe, the corrected
campaign made 67 CLI invocations and reported 134 CLI turns, 134 uncached input
tokens, 492,063 cache-creation input tokens, zero cache-read input tokens and
20,155 output tokens. Reasoning-token counts and provider billing were not
independently established. Native lanes used more context than the legacy lane.
Schemas, observations and feedback differed; their individual contributions were
not isolated.

For **two-controls / repetition 1**, both rebuilt lanes strictly passed with two
applied writes:

| Measure | Single-step | Composed |
|---|---:|---:|
| Controller decisions | 4 | 3 |
| CLI-reported turns | 8 | 6 |
| Tool calls | 3 | 2 |
| End-to-end latency | 23.129 s | 15.714 s |
| CLI-estimated cost | $0.150917 | $0.107347 |

This is one successful matched pair, not an estimated production improvement.
Repetition 0 is not an equal-success performance comparison: the single lane
failed after a native error and blocked replay; composition reached both values
but failed foreground preservation. Aggregate lane costs and medians mix different
completion outcomes and must not be presented as causal efficiency gains.

## Accounting, correction and acceptance

An initial 16 November campaign stopped after two passing trials because the
harness set `MAX_STRUCTURED_OUTPUT_RETRIES=0`. Despite its name, the setting
counts total attempts, including the first. Commit `be3dca6` permits one initial
attempt, without a repair retry, and records that bound on every invocation.
All 16 evaluation tests passed after the correction. The interrupted campaign
is retained separately and is not pooled into the corrected trial results.

| Paid attempt | CLI-estimated USD |
|---|---:|
| Both retained 14 November attempts | $0.02976825 |
| Interrupted 16 November campaign | $0.18137175 |
| Corrected 18-trial campaign, including pin probe | $2.14796325 |
| **Cumulative estimate** | **$2.35910325** |

These are CLI-local estimates, not invoices or a hard provider-side billing cap.
All failed and pin-probe invocations are included. The authorized total was $5.

The 10 installed-process tests and read-only native process smoke also passed on
16 November; the smoke made zero mutations and requested no permissions. The
earlier full aggregate of 186 passing tests and one desktop-dependent skip is
historical, not a fresh full-suite run. Native/scripted campaigns used clean
`5f0a243`; the corrected model campaign used clean `be3dca6`. The native binaries
were identical across them. No native code was changed to erase safe failures.

PER-7 and PER-8 remain In Progress. The remaining acceptance work is controller
recovery from proven pre-dispatch validation failures while preserving mutation
replay protection, and a repeatable way to distinguish CUA foreground disruption
from unrelated desktop changes. The early native failure also needs a concrete
diagnosis before any owning correction. No additional paid rerun or repair was
performed after the declared comparison to select a more favourable result.

The implementation is local and opt-in. This branch has no remote CI or release
claim. Parent [PR #10](https://github.com/johnexzy/macos-computer-use/pull/10)
remains open with passing CI.
