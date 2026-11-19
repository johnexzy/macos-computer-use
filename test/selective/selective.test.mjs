import assert from "node:assert/strict";
import test from "node:test";
import { widerReadReason, selectedArgs } from "./policy.mjs";
import { cpuMilliseconds, foregroundProof, toastClaims, summarize, laneOrder } from "./metrics.mjs";

test("paired trials rotate all lane positions without changing assignment", () => {
  assert.deepEqual([0, 1, 2].map(laneOrder), [["full", "selected", "retained"], ["selected", "retained", "full"], ["retained", "full", "selected"]]);
});

test("policy escalates uncertainty without collector-side selection or silent widening", () => {
  const base = { axSelection: { coverage: "complete", ambiguous: false } };
  assert.equal(widerReadReason(base), null);
  for (const [state, reason] of [[{ ...base, axSelection: { coverage: "complete", ambiguous: true } }, "ambiguous_query"],
    [{ ...base, axSelection: { coverage: "partial", ambiguous: false } }, "incomplete_query"],
    [{ ...base, events: { stale: true } }, "history_stale"], [{ ...base, events: { overrun: true } }, "history_overrun"]]) {
    assert.equal(widerReadReason(state), reason);
  }
  assert.deepEqual(selectedArgs({ pid: 42, windowId: 7 }, [{ role: "AXButton", identifier: "ack", label: null }]),
    { target: { pid: 42, windowId: 7 }, includeValues: false, axSelectors: [{ role: "AXButton", identifier: "ack", label: null }] });
});
test("event claims use independent timed visibility and retain unknown proof", () => {
  const journal = [{ kind: "toast_shown", unixMs: 100 }, { kind: "toast_removed", unixMs: 200 }];
  const observation = { elements: [], events: { events: [
    { sequence: 1, collected: { startedUnixMs: 120, finishedUnixMs: 130 }, controls: [{ identifier: "toast" }] },
    { sequence: 2, collected: { startedUnixMs: 220, finishedUnixMs: 230 }, controls: [{ identifier: "toast" }] },
    { sequence: 3, collected: { startedUnixMs: 90, finishedUnixMs: 110 }, controls: [{ identifier: "toast" }] }] } };
  assert.deepEqual(toastClaims([observation], journal).map((c) => c.truth), [true, false, null]);
  assert.equal(toastClaims([observation], []).every((c) => c.truth === null), true);
});
test("known late activation vetoes, missing watcher cannot pass, unrelated switches allowed", () => {
  const watch = { available: true, targetPID: 42, targetActivations: 0, truncated: false, startedForegroundPID: 1, finishedForegroundPID: 2 };
  assert.equal(foregroundProof([watch, watch], { activationCount: 0 }, 42), true);
  assert.equal(foregroundProof([watch, null], { activationCount: 0 }, 42), null);
  assert.equal(foregroundProof([watch, { ...watch, targetActivations: 1 }], { activationCount: 0 }, 42), false);
  assert.equal(foregroundProof([watch, watch], { activationCount: 1 }, 42), false);
  assert.equal(foregroundProof([{ ...watch, startedForegroundPID: 42 }, watch], { activationCount: 0 }, 42), false);
});
test("report keeps failed and unknown assigned trials and never fabricates token cost", () => {
  const report = summarize([{ lane: "full", strictCompletion: true }, { lane: "full", strictCompletion: false }, { lane: "full" }]);
  assert.equal(report.full.assigned, 3); assert.equal(report.full.strictPassed, 1); assert.equal(report.full.strictFailed, 1); assert.equal(report.full.unknown, 1);
  assert.equal(report.full.actualTokens, null); assert.equal(report.full.actualCostUsd, null);
  assert.equal(cpuMilliseconds("1:02.50"), 62500); assert.equal(cpuMilliseconds("1:02:03.40"), 3723400); assert.equal(cpuMilliseconds("unknown"), null);
});
