import assert from "node:assert/strict";
import test from "node:test";
import { compareCampaigns, compareConditions, distribution, summarize, usageFields } from "./metrics.mjs";

const episode = (caseId, repeat, outcome, extra = {}) => ({
  caseId, fixtureSeed: "fixture-v1", repeat, outcome, kind: "mutation",
  elapsedMs: 100, responseBytes: 12, toolCalls: 1, nativeActionRequests: 1,
  phases: [], completionClaim: null, verificationClaim: false,
  usage: Object.fromEntries(usageFields.map((key) => [key, null])), ...extra,
});

test("repeat-run reliability uses complete independent case groups", () => {
  const rows = [episode("a", 0, "passed"), episode("a", 1, "passed"), episode("a", 2, "passed"),
    episode("b", 0, "passed"), episode("b", 1, "failed"), episode("b", 2, "unknown")];
  const result = summarize(rows);
  assert.equal(result.repeatedRunSuccess.value, 0.5);
  assert.equal(result.scenarioSuccessRate, 4 / 6);
  assert.equal(result.outcomes.unknown, 1);
  assert.equal(summarize(rows.slice(1)).repeatedRunSuccess.value, null);
  assert.equal(summarize([rows[0], rows[0], rows[0]]).repeatedRunSuccess.incompleteGroups, 1);
});

test("no model campaign cannot acquire zero-cost or zero-token claims", () => {
  const result = summarize([episode("a", 0, "passed")]);
  assert.equal(result.usage.inputTokens, null);
  assert.equal(result.costPerVerifiedScenario, null);
  assert.equal(result.costRatioReason, "unmeasured_cost");
  assert.equal(result.completionClaims.measured, false);
});

test("failed attempts and judges remain in measured cost; zero success is undefined", () => {
  const usage = Object.fromEntries(usageFields.map((key) => [key, 5]));
  const result = summarize([episode("a", 0, "passed", { usage }), episode("b", 0, "failed", { usage })]);
  assert.equal(result.costPerVerifiedScenario, 10);
  const none = summarize([episode("b", 0, "failed", { usage })]);
  assert.equal(none.costPerVerifiedScenario, null);
  assert.equal(none.costRatioReason, "no_verified_successes");
  assert.equal(summarize([episode("a", 0, "passed", { usage }), episode("b", 0, "failed")]).usage.costUsd, null);
});

test("delivery alone is not a false verification or a task-completion claim", () => {
  const result = summarize([
    episode("a", 0, "failed", { verificationClaim: true, effectObserved: false }),
    episode("b", 0, "failed", { verificationClaim: false, effectObserved: false }),
    episode("c", 0, "unknown", { completionClaim: true, verificationClaim: true, effectObserved: null }),
    episode("d", 0, "failed", { completionClaim: true }),
  ]);
  assert.deepEqual(result.effectClaims, { total: 2, contradicted: 1, unknown: 1 });
  assert.equal(result.completionClaims.false, 1);
  assert.equal(result.completionClaims.unknown, 1);
  assert.equal(result.completionClaims.falsePerAssigned, 0.25);
});

test("refusal correctness is reported separately from successful mutation", () => {
  const result = summarize([episode("write", 0, "failed"), episode("stale", 0, "passed", { kind: "refusal" })]);
  assert.equal(result.byKind.mutation.passed, 0);
  assert.equal(result.byKind.refusal.passed, 1);
});

test("paired comparison exposes missing cases instead of silently dropping them", () => {
  const left = { episodes: [episode("a", 0, "passed"), episode("b", 0, "failed")] };
  const right = { episodes: [episode("a", 0, "unknown"), episode("a", 1, "passed")] };
  const result = compareCampaigns(left, right);
  assert.equal(result.pairs.length, 1);
  assert.equal(result.pairs[0].right, "unknown");
  assert.equal(result.missingLeft.length, 1);
  assert.equal(result.missingRight.length, 1);
});

test("nearest-rank latency distribution has explicit empty and tail behavior", () => {
  assert.deepEqual(distribution([]), { samples: 0, p50: null, p95: null });
  assert.deepEqual(distribution([90, 10, 40]), { samples: 3, p50: 40, p95: 90 });
});

test("clean/adverse comparison pairs the same trial and exposes missing pairs", () => {
  const rows = [episode("clean", 0, "passed"), episode("clean", 1, "passed"),
    episode("delayed", 0, "passed", { elapsedMs: 250 }), episode("delayed", 2, "unknown")];
  const [result] = compareConditions(rows, "clean", ["delayed"]);
  assert.deepEqual(result.pairs, [{ fixtureSeed: "fixture-v1", repeat: 0,
    clean: "passed", adverse: "passed", elapsedDeltaMs: 150 }]);
  assert.equal(result.missingClean.length, 1);
  assert.equal(result.missingAdverse.length, 1);
});
