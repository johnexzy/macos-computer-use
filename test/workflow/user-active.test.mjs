import assert from "node:assert/strict";
import test from "node:test";
import { gradeUserActive, gradeWorkflow, makeTask, workflowVariants } from "./task.mjs";
import { UserActiveActivity } from "./support/user-active.mjs";

function fakeActivity(options = {}) {
  const state = { current: 99, events: [], calls: [], closed: [], ticks: 0 };
  const activity = new UserActiveActivity({ binaries: ["fakeA", "fakeB"], targetPID: 42,
    milestones: ["first", "second"], snapshot: async () => ({ available: !options.unavailable,
      targetPID: 42, targetActivations: 0, finishedForegroundPID: state.current, truncated: false, events: state.events }),
    makeActor: (_binary, label, nonce) => {
      const pid = label === "A" ? 101 : 102;
      let activations = 0;
      return { child: { pid }, ready: Promise.resolve({ pid, nonce, label, previousForegroundPID: 99,
        previousIdentityKnown: !options.unknownPrior, foregroundPID: 99 }),
        call: async (command, args) => {
          state.calls.push({ pid, command, args });
          if (command === "restore") {
            const restored = pid === state.current;
            if (restored) state.current = 99;
            return { restored, reason: restored ? "prior_focus_restored" : "unowned_foreground_preserved" };
          }
          if (command === "yield") {
            assert.equal(state.current, pid, "foreground_changed_before_actor_yield");
            assert.ok(args.ownedPIDs.includes(args.nextActorPID));
            return { state: { pid, foregroundPID: pid } };
          }
          assert.equal(state.current, args.expectedForegroundPID, "foreground_changed_before_actor_activation");
          state.current = pid; activations += 1;
          state.events.push({ pid, observedUptimeNs: ++state.ticks });
          return { state: { pid, foregroundPID: pid, activationCount: activations } };
        },
        close: async () => { state.closed.push(pid); if (options.failClose && pid === 102) throw new Error("close failed"); },
      };
    } });
  return { activity, state };
}

test("user-active is explicit opt-in and does not widen the default twelve assignments", () => {
  assert.deepEqual(workflowVariants(), ["clean", "friction"]);
  assert.equal(2 * workflowVariants().length * 3, 12);
  assert.deepEqual(workflowVariants("user-active"), ["user-active"]);
  assert.throws(() => workflowVariants("all"));
  for (const task of ["invoice", "settings"]) {
    const active = makeTask(task, "user-active", "paired"), clean = makeTask(task, "clean", "paired");
    assert.deepEqual(active.config, clean.config);
    assert.deepEqual(active.expected, clean.expected);
    assert.equal(active.userActiveMilestones.length, 2);
    assert.ok(active.userActiveMilestones.every(id => active.fields.some(f => f.id === id && f.initial !== f.expected)));
  }
});

test("independent actor events follow shared logical milestones and survive cleanup grading", async () => {
  const { activity, state } = fakeActivity();
  await activity.start();
  await activity.afterMutation(["other"]);
  assert.equal(activity.evidence.transitions.length, 1);
  await activity.afterMutation(["first"]);
  await activity.afterMutation(["middle", "second"]);
  assert.equal(gradeUserActive(activity.evidence, 42, ["first", "second"]), false, "Cleanup is part of coverage");
  await activity.close();
  activity.evidence.controlledProcessesStopped = true;
  assert.deepEqual(activity.evidence.transitions.map(s => [s.checkpoint, s.actorPID]), [["task_start", 101], ["after:first", 102], ["after:second", 101]]);
  assert.deepEqual(state.calls.filter(call => call.command === "yield").map(call => [call.pid, call.args.nextActorPID]), [[101, 102], [102, 101]]);
  assert.equal(gradeUserActive(activity.evidence, 42, ["first", "second"]), true);
  assert.equal(activity.evidence.restore.restored, true);
  assert.deepEqual(state.closed.sort(), [101, 102]);
});

test("a composed batch cannot silently move a causal milestone past other writes", async () => {
  const { activity } = fakeActivity(); await activity.start();
  await assert.rejects(activity.afterMutation(["first", "later"]), /must end/);
  assert.equal(activity.evidence.transitions.length, 1);
  await activity.close();
});

test("unknown prior identity or unavailable monitor cannot establish user-active coverage", async () => {
  for (const options of [{ unknownPrior: true }, { unavailable: true }]) {
    const { activity } = fakeActivity(options);
    await assert.rejects(activity.start());
    await activity.close();
    assert.notEqual(gradeUserActive(activity.evidence, 42, ["first", "second"]), true);
  }
});

test("an unrelated user switch stops further actor activation and skips restoration", async () => {
  const { activity, state } = fakeActivity(); await activity.start();
  state.current = 777;
  await assert.rejects(activity.afterMutation(["first"]), /foreground_changed/);
  await activity.close();
  assert.equal(state.current, 777);
  assert.equal(activity.evidence.restore.restored, false);
  assert.equal(activity.evidence.transitions.length, 1);
});

test("actor cleanup failure cannot disappear behind completed task activity", async () => {
  const { activity } = fakeActivity({ failClose: true });
  await activity.start(); await activity.afterMutation(["first"]); await activity.afterMutation(["second"]);
  await assert.rejects(activity.close(), /close failed/);
  assert.equal(gradeUserActive(activity.evidence, 42, ["first", "second"]), false);
});

test("goal truth needs complete user-active coverage and independent final foreground proof", () => {
  const plan = makeTask("settings", "user-active", "paired");
  const before = { pid: 42, runNonce: "owned", values: Object.fromEntries(plan.fields.map(f => [f.id, f.initial])) };
  const after = { runNonce: "owned", values: { ...plan.expected, ...plan.protectedValues }, activationCount: 0, pending: 0,
    events: plan.fields.filter(f => f.initial !== f.expected).map(f => ({ kind: "attempt", id: f.id })), windows: [] };
  const evidence = { targetPID: 42, actorPIDs: [101, 102], previousForegroundPID: 99, cleanupComplete: true, controlledProcessesStopped: true,
    transitions: ["task_start", ...plan.userActiveMilestones.map(id => `after:${id}`)].map((checkpoint, i) => ({ checkpoint,
      beforePID: i ? [101, 102][(i - 1) % 2] : 99, actorPID: [101, 102][i % 2], activationCount: 1, monitorKnown: true, observedUptimeNs: i + 1 })) };
  assert.equal(gradeWorkflow("settings", plan, before, after, true).outcome, "unknown");
  assert.equal(gradeWorkflow("settings", plan, before, after, true, evidence).outcome, "passed");
  assert.equal(gradeWorkflow("settings", plan, before, after, null, evidence).outcome, "unknown");
  assert.equal(gradeWorkflow("settings", plan, before, after, false, evidence).outcome, "failed");
  delete evidence.cleanupComplete;
  assert.notEqual(gradeWorkflow("settings", plan, before, after, true, evidence).outcome, "passed");
});
