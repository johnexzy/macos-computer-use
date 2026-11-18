import assert from "node:assert/strict";
import test from "node:test";
import { recover, reconcile, RouteEvidence } from "./recovery.mjs";
import { offlineTrial, runOffline } from "./offline.mjs";
import { gradeState } from "./oracle.mjs";
import { recoverySummary, comparePolicies } from "./metrics.mjs";

test("typed stop preserves completed prefix and known unsent remainder", () => {
  const setup = offlineTrial("known-unsent", "partition");
  assert.deepEqual(reconcile(setup.request, setup.response).completed, ["set-0"]);
  assert.deepEqual(reconcile(setup.request, setup.response).unmet, ["set-1"]);
  const lost = offlineTrial("unknown-delivery", "partition");
  assert.deepEqual(reconcile(lost.request, lost.response).completed, ["set-0"]);
  assert.deepEqual(reconcile(lost.request, lost.response).uncertain, ["set-1"]);
  const bad = structuredClone(setup.response); bad.structuredContent.body.data.observationId = "another";
  assert.deepEqual(reconcile(setup.request, bad).uncertain, ["set-0", "set-1"]);
  bad.structuredContent = { version: 1, route: "rust_host", uncertainty: { observation_id: setup.request.observationId,
    settled_steps: [null, null, null], unacknowledged_action_ids: [] } };
  assert.deepEqual(reconcile(setup.request, bad).uncertain, ["set-0", "set-1"]);
});

test("recovery is opt-in and no policy replays unknown delivery", async () => {
  const setup = offlineTrial("known-unsent", "opt-in");
  const disabled = await recover({ ...setup, policy: "guarded" });
  assert.equal(disabled.calls.length, 0); assert.equal(disabled.mutations, 0);
  for (const policy of ["none", "simple", "guarded"]) {
    const result = await runOffline("unknown-delivery", "unknown", policy);
    assert.equal(result.recovery.calls.length, policy === "none" ? 0 : 1);
    assert.equal(result.final.extraAttempts, 0);
    assert.deepEqual(result.recovery.final.uncertain, ["set-1"]);
  }
});

test("only known unsent work is repaired and independent goals improve", async () => {
  const disabled = await runOffline("known-unsent", "paired", "none");
  const simple = await runOffline("known-unsent", "paired", "simple");
  const guarded = await runOffline("known-unsent", "paired", "guarded");
  assert.equal(disabled.final.strictCompletion, false);
  assert.equal(simple.final.strictCompletion, true);
  assert.equal(guarded.final.strictCompletion, true);
  assert.equal(guarded.recovery.routeUsed, "axSetValue");
  assert.equal(guarded.final.extraAttempts, 1);
  assert.equal(guarded.final.additionalDamage, 0);
  assert.equal(guarded.recovery.calls.length, 3);
  assert.equal(new Set([disabled, simple, guarded].map(result => result.erroneousStateSha256)).size, 1);
});

test("fresh references cannot legitimize an old control route after replacement", async () => {
  const simple = await runOffline("recreated-control", "replaced", "simple");
  const guarded = await runOffline("recreated-control", "replaced", "guarded");
  assert.equal(simple.final.goalSatisfied, true);
  assert.equal(simple.final.strictCompletion, false);
  assert.equal(simple.final.additionalDamage, 1);
  assert.equal(guarded.final.extraAttempts, 0);
  assert.equal(guarded.recovery.routeInvalidated, true);
  assert.equal(guarded.routeRecords.length, 0);
  assert.equal(guarded.final.additionalDamage, 0);
});

test("version or persistent visual disagreement blocks repair rather than choosing another route", async () => {
  for (const [caseId, reason] of [["route-version-mismatch", "route_scope_changed"], ["visual-conflict", "visual_text_unverified"]]) {
    const result = await runOffline(caseId, "refuse", "guarded");
    assert.equal(result.recovery.mutations, 0);
    assert.ok(result.recovery.reasons.includes(reason));
  }
  const stale = await runOffline("stale-visual", "refuse", "guarded");
  assert.equal(stale.recovery.visualReconciled, true);
  assert.equal(stale.recovery.calls.length, 4);
  assert.equal(stale.final.strictCompletion, true);
});

test("route evidence is specific to app, runtime, control and bounded lifetime", () => {
  const setup = offlineTrial("known-unsent", "route");
  const control = setup.routes.records[0].control;
  assert.ok(setup.routes.find(setup.scope, control, 101).record);
  for (const field of ["appVersion", "runtimeVersion", "instanceId", "pid", "windowId"]) {
    assert.equal(setup.routes.find({ ...setup.scope, [field]: "changed" }, control, 101).record, null);
  }
  assert.equal(setup.routes.find(setup.scope, { ...control, role: "AXButton" }, 101).record, null);
  assert.equal(setup.routes.find(setup.scope, control, 60100).reason, "route_expired");
  assert.throws(() => new RouteEvidence({ ttlMs: 60001 }));
  const bad = structuredClone(setup.routes.records[0]); bad.receipt.evidence[0].condition.params.elementRef = "another";
  assert.equal(setup.routes.record({ ...bad, now: 101 }), false);
});

test("budget refusal before handoff does not fabricate unknown input", async () => {
  const setup = offlineTrial("known-unsent", "cap");
  const result = await recover({ ...setup, policy: "guarded", enabled: true, limits: { maxCalls: 2, maxMutations: 1, timeoutMs: 1500 } });
  assert.equal(result.mutations, 0); assert.equal(result.budgetStopped, true);
  assert.deepEqual(result.final.unmet, ["set-1"]);
  assert.deepEqual(result.final.uncertain, []);
  const timeout = await runOffline("budget-exhausted", "cap", "guarded");
  assert.equal(timeout.recovery.budgetStopped, true); assert.equal(timeout.final.extraAttempts, 0);
});

test("a dropped repair result stays uncertain and cannot trigger a second input", async () => {
  const setup = offlineTrial("known-unsent", "lost-repair"); let inputs = 0;
  setup.port.act = async () => { inputs++; throw new Error("transport_lost"); };
  const result = await recover({ ...setup, policy: "guarded", enabled: true });
  assert.equal(inputs, 1); assert.equal(result.mutations, 1);
  assert.deepEqual(result.final.uncertain, ["set-1"]);
});

test("an independently already-correct value is not a delivery claim or redundant input", async () => {
  const setup = offlineTrial("known-unsent", "already"); setup.state.controls[1].value = setup.goals[1].value;
  const result = await recover({ ...setup, policy: "guarded", enabled: true });
  assert.equal(result.mutations, 0); assert.equal(result.final.uncertain.length, 0);
  assert.deepEqual(result.final.completed, ["set-0", "set-1"]);
  assert.equal(result.final.steps[1].delivery, "not_dispatched");
});

test("route evidence expiring during its read proof cannot authorize input", async () => {
  const setup = offlineTrial("known-unsent", "expires");
  setup.routes.records[0].expiresAt = 112; // observe finishes110; retained read finishes115.
  const result = await recover({ ...setup, policy: "guarded", enabled: true });
  assert.ok(result.reasons.includes("route_expired"));
  assert.equal(result.mutations, 0);
  assert.deepEqual(result.final.unmet, ["set-1"]);
});

test("duplicate public identifiers stay ambiguous rather than selecting an arbitrary repair target", async () => {
  const setup = offlineTrial("known-unsent", "ambiguous");
  const observe = setup.port.observe;
  setup.port.observe = async (...args) => { const value = await observe(...args); value.elements.push({ ...value.elements[1], reference: "other" }); return value; };
  const result = await recover({ ...setup, policy: "simple", enabled: true });
  assert.ok(result.reasons.includes("ambiguous_or_unreadable_control"));
  assert.equal(result.mutations, 0);
});

test("oracle counts redundant attempts from independent state even if native claims completion", () => {
  const setup = offlineTrial("already-complete", "duplicate");
  const after = structuredClone(setup.beforeRepair); after.controls[1].attempts++;
  const grade = gradeState({ ...setup, after });
  assert.equal(grade.goalSatisfied, true);
  assert.equal(grade.duplicateActions, 1);
  assert.equal(grade.strictCompletion, false);
});

test("summary keeps blocked assignments and exposes missing paired policy arms", async () => {
  const good = { ...await runOffline("known-unsent", "metrics", "guarded"), repeat: 0 };
  const summary = recoverySummary([good, { caseId: "known-unsent", repeat: 0, policy: "none", outcome: "setup_blocked" }], 1);
  assert.equal(summary.assigned, 2); assert.equal(summary.assessed, 1);
  assert.equal(summary.strictEventualPerAssigned, 0.5); assert.equal(summary.model.costUsd, null);
  const [pair] = comparePolicies([good]);
  assert.equal(pair.completePolicySet, false);
  const overrun = { ...good, recovery: { ...good.recovery, budgetStopped: true }, outcome: "budget_stopped" };
  assert.equal(recoverySummary([overrun], 1).strictEventual, 0);
});
