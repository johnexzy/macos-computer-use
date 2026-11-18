import assert from "node:assert/strict";
import test from "node:test";
import { gradeWorkflow, makeTask } from "./task.mjs";

function episode(task, variant = "clean") {
  const plan = makeTask(task, variant, "fixed seed");
  const before = {
    runNonce: "owned", values: { ...plan.protectedValues, ...Object.fromEntries(plan.fields.map(f => [f.id, f.initial])) },
  };
  const after = {
    runNonce: "owned", values: { ...plan.protectedValues, ...plan.expected }, pending: 0, activationCount: 0,
    events: plan.fields.filter(f => f.initial !== f.expected).map(f => ({ kind: "attempt", id: f.id })),
    submission: null, windows: [],
  };
  if (task === "invoice") {
    after.submission = { ...plan.expected };
    after.events.push({ kind: "submit_attempt" }, { kind: "submitted" });
    after.windows = [{ key: "work", visible: false }, { key: "confirmation", visible: true }];
  }
  return { plan, after, grade: (foreground = true) => gradeWorkflow(task, plan, before, after, foreground) };
}

test("correct form values do not excuse an incorrect or repeated submission", () => {
  const { after, grade } = episode("invoice");
  assert.equal(grade().outcome, "passed");
  after.submission["invoice.1.quantity"] = "91";
  assert.equal(grade().correctFields, 27);
  assert.equal(grade().outcome, "failed");
  after.submission["invoice.1.quantity"] = after.values["invoice.1.quantity"];
  after.events.push({ kind: "submit_attempt" });
  assert.equal(grade().outcome, "failed");
});

test("an unchanged final value cannot hide a redundant or wrong-target attempt", () => {
  const { plan, after, grade } = episode("settings");
  assert.equal(grade().outcome, "passed");
  assert.equal(grade(null).outcome, "unknown");
  after.events.push({ kind: "attempt", id: plan.fields.find(f => f.initial === f.expected).id });
  assert.equal(grade().unnecessaryWrites, 1);
  assert.equal(grade().outcome, "failed");
  after.events.pop();
  after.events.push({ kind: "attempt", id: "source.notes" });
  assert.equal(grade().wrongTargetAttempts, 1);
  assert.equal(grade().outcome, "failed");
  after.events.pop();
  after.events.push({ kind: "stale_attempt", id: plan.fields.find(f => f.initial !== f.expected).id });
  assert.equal(grade().wrongTargetAttempts, 1);
  assert.equal(grade().outcome, "failed");
});

test("friction needs exercised faults and no pending or focus effects", () => {
  const { plan, after, grade } = episode("settings", "friction");
  const fault = plan.config.friction;
  assert.equal(grade().faultsExercised, false);
  assert.equal(grade().outcome, "failed");
  after.events.push(...fault.recreate.map(id => ({ kind: "recreated", id })),
    { kind: "validation_cleared", id: fault.cleared }, { kind: "delayed", id: fault.delayed });
  assert.equal(grade().outcome, "passed");
  assert.equal(grade().normalizedInput, false);
  after.pending = 1;
  assert.equal(grade().outcome, "failed");
  after.pending = 0;
  after.activationCount = 1;
  assert.equal(grade().outcome, "failed");
});
