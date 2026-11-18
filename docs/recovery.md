# Bounded recovery evaluation

[PER-13](https://linear.app/komonapp/issue/PER-13/evaluate-bounded-recovery-and-execution-route-evidence)
is implemented as an opt-in harness policy. The runtime's dispatch, permissions,
retained references and execution routes are unchanged. This evaluates one
semantic `setValue` repair on the disposable fixture, not a general recovery agent
or learned router.

## Policy and evidence

`test/recovery/recovery.mjs` reconciles an actual typed request with its native
receipt, preserving the completed prefix and separating known-unsent work from
uncertain input. A host uncertainty envelope preserves its validated settled
prefix while leaving the whole unacknowledged suffix uncertain. Missing or
uncorrelated responses do not prove input was unsent.

The default policy is `none`. Both enabled baselines re-observe public state.
They never replay unknown or sent-unverified input; readback does not erase that
history. `simple` selects a uniquely identified known-unsent control from the new
observation. `guarded` also requires matching route evidence, a successful
read-only validation of its original retained control, and a fresh-value
precondition on the corrective action. A current value that already meets the
goal produces no input.

Route facts record app bundle and binary fingerprint, runtime binary fingerprint,
OS version, process/trial/window scope, control identifier/role/subrole, original
observation/reference, action, actual route and confirmed readback. A fact has a
local freshness horizon of at most 60 seconds. Native reference TTL and identity
validation remain authoritative; the cache does not extend them. A stale retained
identity invalidates the fact and retains its history. App/runtime/version or
control metadata mismatch cannot select a different route. Public AX object
identity has the same reuse limitations documented in `protocol.md`.

Explicit stale or disagreeing visual evidence triggers at most one fresh visual
observation. Its target, channel interval and frame/AX geometry must agree, and
an exact OCR match must map inside the relevant control's AX bounds. Missing or
contradictory evidence stays uncertain. This read-only reconciliation cannot
authorize a new input route; the original known-unsent and retained-route checks
still apply before `axSetValue`.

Every enabled arm gets the same extra budget: **four attempted repair steps,
one mutation and 1,500 ms**. Re-observation, visual reconciliation and retained
reference checks consume that budget. Reports distinguish attempted steps from
actual handed-off calls. A deadline before handoff preserves known-unsent status;
a lost response after handoff stays uncertain. Original receipts remain in
`initial`; `final` is a goal-state projection, with repair request/response IDs
retained separately. It is not a rewritten native receipt.

## Run without model inference

Pure checks and the deterministic logical-clock comparison require only Node:

```sh
node --test test/recovery/recovery.test.mjs
node test/recovery/run.mjs --mode offline --repetitions 3 \
  --output .artifacts/per13-offline
```

The offline matrix has eight cases, three policies and three repetitions: 72
assigned episodes. It includes known-unsent work, an already-correct goal,
uncertain delivery, replaced controls, version mismatch, stale visual evidence,
persistent visual disagreement and budget exhaustion. Its time is a deterministic
policy clock. It proves policy boundaries, not native or model performance.

Native plans launch no fixture unless `--execute` is present:

```sh
node test/recovery/run.mjs --mode native --repetitions 3
```

After coordinating an unlocked, serialized desktop slot, build the installed
pair and fixture and run the unpaid native comparison:

```sh
npm run build:runtime
sh test/fixtures/macos/build.sh
node test/recovery/run.mjs --mode native --execute --repetitions 3 \
  --output .artifacts/per13-native
```

The native matrix has six cases and 54 assignments. It uses the same fixture
state and seed for every policy, rotates policy order, and hashes controlled
state without process/window IDs. It establishes a real semantic route during
declared setup, then executes a two-field sequence whose second precondition
fails. Cases add response omission, true control recreation, actual window
ambiguity and an actual captured visual observation made stale by a window move.
Response omission is a harness fault; it is not claimed as a helper-death test.
Version mismatch and persistent OCR contradiction are offline tests, not claimed
as native app-upgrade or visual-recognition coverage.

Setup publication gates and route warmup are separately tagged. Only public
observations and typed receipts reach the recovery policy. The fixture's private
control/model values, generations, pending writes and attempt counters feed a
separate oracle, with a 500 ms read budget. A continuous independent foreground
observer is required through cleanup; known positive fixture activation also
vetoes success. The policy uses semantic input on the disposable fixture and relies on existing permissions.

## Interpret the result

Keep every assigned episode, including setup blocks, budget stops and unknowns.
Reports retain source/binary hashes, route facts, initial and repair receipts,
completed/unmet/uncertain state, native call traces and independent outcomes.
They compare unassisted and eventual strict completion, repair time/call count,
duplicates, additional damage and repeated-run consistency. Raw oracle state is
retained separately; completion outside the repair budget or with failed cleanup
does not count as bounded recovery success. Pair fingerprints must agree before
making a paired comparison; unmatched states remain reported.

The strict oracle requires both actual values and model values, original control
identity, protected state, no pending writes, no additional damage or duplicate
actions, and known foreground preservation. Duplicates include an extra attempt
on an already-correct control or one already attempted during initial execution.
Writing a replacement object is additional damage even if its final text matches.
That is this fixture task's original-object requirement. A different workflow may
explicitly authorize a replacement; this policy does not establish that intent.

Model tokens and dollars are **unmeasured (`null`)**. These are unpaid scripted
checks. A stricter policy can reduce damage while completing fewer tasks; report
that tradeoff instead of claiming recovery universally improves success. Evidence
for this one route and fixture does not establish routing across arbitrary apps,
visual accuracy, autonomous recovery, or a model-training benefit.

## Verified fixture results

The native campaign assessed all 54 assignments with 18 matched state triplets.
The deterministic offline campaign assessed all 72 assignments with 24 matched
state triplets. Both campaigns recorded zero duplicate actions.

| Policy | Native strict completion | Native trials with additional damage | Offline strict completion |
| --- | ---: | ---: | ---: |
| None | 3/18 | 0 | 3/24 |
| Simple | 9/18 | 3 | 15/24 |
| Guarded | 6/18 | 0 | 9/24 |

The simple arm's three native damage cases wrote the recreated control. The
guarded arm rejected that route because the original retained reference was
invalid. Median native policy time was 29.8 ms for simple and 30.4 ms for
guarded. Those measurements include the extra checks on this fixture. The
[verification record](evidence/per-13-recovery-2026-11-18.json) retains the
source revisions, binary hashes, repair calls and latency distributions.
