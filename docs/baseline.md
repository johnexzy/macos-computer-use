# Legacy baseline (PER-1)

This development harness measures the existing TypeScript/Swift implementation before the Rust host replaces it. It runs scripted driver scenarios against a disposable AppKit fixture. It does not run a model, measure autonomous task planning, or spend model API credit. Node is a development dependency for this legacy comparison, not a requirement chosen for the new native distribution.

## Run

From the repository root on an unlocked macOS desktop:

```sh
npm ci --ignore-scripts
npm run baseline:build
npm run baseline:preflight
npm run baseline -- --repetitions 3
```

The preflight only reads metadata and capabilities; it neither launches the fixture nor requests privacy permissions. A live campaign requires existing Accessibility permission. Screen Recording is optional: missing access skips capture/OCR probes explicitly. Only the fixture's own controls are mutated. The harness does not activate apps or use global input or AppleScript. Each trial launches and closes its own fixture process; startup foreground interference blocks that trial.

Use `--output <directory>` to choose the evidence location. The default is an ignored `.artifacts/baseline/<timestamp>` directory. A campaign writes `report.json`, `trace.jsonl`, and fixture-only screenshots when capture is available. These can contain local process/window IDs, device details and disposable field values; inspect them before sharing.

```sh
npm run baseline -- --repetitions 3 --output .artifacts/legacy
node test/baseline/run.mjs --repetitions 3 --output .artifacts/candidate --compare .artifacts/legacy/report.json
```

The second command currently runs the same legacy adapter; it checks repeatability and the pairing machinery. A later runtime adapter must use the same case IDs, fixture seed, repetition count, permissions and budgets before comparing implementations. The comparison reports unmatched rows rather than discarding them.

## Scenarios and oracle

The fixture owns two windows with duplicate field labels. Its JSONL control channel reads actual native model and control values independently of the AX path under test. Each trial starts a fresh process, resets both windows and records the run nonce and reset generation. See [fixture.md](fixture.md) for its protocol.

| Case | Requirement being measured |
| --- | --- |
| Clean set | Update `primary.first`, preserving all sibling fields and foreground state |
| Ignored write | Attempt the same edit while the fixture ignores AX writes; the oracle must detect the missing effect |
| Delayed write | Attempt the edit with a delayed effect; separately record driver response and eventual oracle convergence |
| Reordered fields | Observe, reorder rows, then address the same field identity |
| Already satisfied | The requested value already exists and AX writes are ignored; do not count this as a newly applied edit |
| Recreated control | Replace the observed control with a new generation; test refusal rather than silent retargeting |
| Reopened window | Replace the observed window; require refusal without writing into its replacement |
| Duplicate label | Use a selector that matches both fields; require ambiguity refusal without mutation |
| Ambiguous windows | Give both windows the same title and frame; require refusal without mutation |

Refusal correctness requires the intended stale/ambiguous error code and unchanged independent values. An unrelated infrastructure error cannot pass. Refusal correctness and mutation completion are separate result categories. The legacy API has selectors rather than retained observation-bound references: recreated-control/window cases deliberately expose its lack of identity continuity. This is a requirement for the rebuild, not a claim that legacy selectors promise retained identity. An error-free AX result is not the oracle. Known legacy failures are baseline data, not a reason to alter the shipping code in this issue.

## Measurement boundary

- Calls go through the existing in-process tool registry, including its services and Swift helper. MCP transport overhead is excluded and identified in each report.
- A temporary wrapper records `NativeBridge.call` round trips without modifying production code. These samples include process startup, native work, JSON and IPC. They are not isolated AX execution times.
- `match_text` is a lightweight helper-startup proxy. Standalone `screencapture` measures CLI capture wall time. Standalone `ocr` uses that saved fixture image, so its round trip excludes capture but still includes helper startup. Samples overlap conceptually; do not subtract their medians to claim a precise decomposition.
- Scenario latency covers observation, attempted action, independent readback convergence and endpoint foreground reads. Separate helper-startup and visual probes are excluded. Cold Vision initialization can differ substantially from later calls.
- The legacy helper lacks an internal request deadline; the report records that as an unbounded native-call limit. Oracle convergence and fixture-control requests have explicit budgets. A driver hang is not evidence that no action happened.
- Equal frontmost PIDs before/after cannot rule out transient focus theft. The fixture additionally records its own activation count. Neither signal proves arbitrary background cooperation across macOS apps.

Reports record repository and legacy-source revisions, dirty state, binary hashes, hardware/OS/display metadata, permissions, instructions, budgets, response bytes and request-attributable traces. Model token categories, monetary cost and human-rescue minutes remain `null` when unmeasured. Bytes are not substituted for tokens. Tool invocations, native action requests, fixture write attempts and applied writes are counted separately; none counts low-level OS events.

## Outcomes

Each assigned scenario is `passed`, `failed`, `unknown`, or `setup_blocked`. Missing oracle evidence is unknown, never verified success. A missing required permission records blocked cases and exits with code 2. Recorded driver failures do not abort the campaign; an unexpected fixture/setup failure must be investigated before interpreting the report.

`scenarioSuccessRate` includes unknown evaluated outcomes in its denominator. `repeatedRunSuccess` is the fraction of cases that pass every independent reset trial; it is not the aggregate success rate raised to a power. Missing repetitions make that result undefined. `byKind` separates successful mutations, already-satisfied conditions and correct refusals.

`conditionComparison` pairs clean edits with ignored, delayed and reordered edits by fixture seed and repetition. It exposes missing pairs. This comparison measures a fixed script under controlled changes; it does not establish autonomous agent reliability.

A verified-effect claim contradicted by the fixture is distinct from an accepted or unverified delivery result. Scripted runs have no agent task-completion claim, so completion-claim rates remain unmeasured. The metrics module can account for explicitly supplied model usage, rescue flags and completion claims in later recorded campaigns. Total measured cost includes failed attempts; cost per verified scenario is undefined when no scenario passes or costs are unmeasured. Provider reasoning/visual tokens can overlap reported output/input categories and are not blindly summed.

Run `node --test test/baseline/*.test.mjs` for metric checks without a desktop or permissions. Live fixture campaigns are separate from ordinary CI checks.

## Recorded baseline

The [2026-11-14 evidence summary](evidence/per-1-baseline-2026-11-14.json) records 27 trials across nine cases: 9/12 mutations, 3/3 already-satisfied conditions and 0/12 required refusals passed. Ignored writes account for the three mutation failures; they correctly returned unconfirmed results. Reopened windows received writes addressed to an old window ID. Recreated controls and ambiguous labels/windows expose identity and refusal requirements for the rebuild. This mixed scenario result is not an autonomous task-success score.

No fixture activations or endpoint foreground changes occurred in this recorded campaign. A prior diagnostic campaign recorded one Chrome-to-ChatGPT endpoint switch with zero fixture activations; its cause was not established. Full local traces include fixture commands and pre-action state, while the committed summary retains hashes and omits process IDs and screenshots. There were no model calls, so token/cost and completion-claim metrics remain unmeasured.
