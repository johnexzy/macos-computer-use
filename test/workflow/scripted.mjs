import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Fixture } from "../fixtures/macos/client.mjs";
import { root, data, payload } from "../evaluation/adapters.mjs";
import { foregroundProof, mergeForegroundWatches } from "../evaluation/metrics.mjs";
import { buildForegroundMonitor, ForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { gradeWorkflow, makeTask, workflowVariants } from "./task.mjs";
import { buildUserActiveActors, userActiveSource, UserActiveActivity } from "./support/user-active.mjs";

const host = path.join(root, ".artifacts/runtime-install/cua-host");
const fixturePath = "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture";
const budgetMs = 3000;
const absent = { kind: "windowAbsent", params: {} };
const exists = (identifier, role) => ({ kind: "elementExists", params: { selector: { identifier, role } } });
const valueEquals = (elementRef, value) => ({ kind: "valueEquals", params: { elementRef, value } });
const hash = (value) => createHash("sha256").update(value).digest("hex");

async function ready(read) {
  const deadline = performance.now() + 6000;
  let last;
  while (performance.now() < deadline) {
    try { return await read(); } catch (err) { last = err; }
    await sleep(80);
  }
  throw last;
}

const stopped = (exit, label) => Promise.race([exit, sleep(2000, undefined, { ref: false }).then(() => {
  throw new Error(`${label} stop was not observed`);
})]);

async function trial(assignment, monitorBinary, actorBinaries) {
  const { task, variant, lane, seed } = assignment;
  const plan = makeTask(task, variant, seed);
  const legacy = lane === "legacy";
  const maxBatch = lane === "composed" ? 12 : 1;
  const calls = [];
  let fixture, client, hostClosed, monitor, activity, before, after, observation, setupMs, taskMs, error, cleanupError, staleProof;
  const watches = [];
  const setupStarted = performance.now();
  const lookup = (state, key) => ({ pid: state.pid, windowId: state.windows.find(w => w.key === key && w.visible)?.windowId });
  const call = async (name, args) => {
    const t = performance.now();
    const entry = { name, args };
    calls.push(entry);
    try {
      entry.result = await client.callTool({ name, arguments: args }, undefined, { timeout: 8000 });
      return entry.result;
    } catch (err) {
      entry.error = err.message;
      throw err;
    } finally {
      entry.elapsedMs = performance.now() - t;
    }
  };
  const observe = async (target) => {
    assert.ok(target.windowId, "Fixture window is not present");
    const result = legacy ? await call("inspect_accessibility", { windowId: target.windowId, includeValues: true })
      : await call("observe", { target, budgetMs, includeValues: true });
    assert.ok(!result.isError, JSON.stringify(payload(result)));
    const observed = legacy ? payload(result) : data(result);
    assert.ok(observed?.elements?.length && !observed.truncated, "Expected a nonempty, untruncated AX observation");
    return observed;
  };
  const element = (observed, id) => {
    const matches = observed.elements.filter(e => e.identifier === id);
    assert.equal(matches.length, 1, `Expected one ${id}`);
    return matches[0];
  };
  const readValue = (observed, id) => String(element(observed, id).value);
  const act = async (target, observed, steps) => {
    assert.ok(steps.length > 0 && steps.length <= maxBatch);
    const result = await call("act", { target, budgetMs, observationId: observed.observationId, steps });
    return data(result);
  };
  const setStep = (observed, spec, value = spec.expected) => ({ actionId: spec.id, operation: {
    kind: "setValue", params: { elementRef: element(observed, spec.id).reference, value } } });
  const press = async (target, observed, id, condition) => {
    const selected = element(observed, id);
    assert.ok(selected.actions.includes(legacy ? "AXPress" : "press"), `AXPress unavailable for ${id}`);
    if (legacy) {
      const result = await call("perform_accessibility_action", { windowId: target.windowId, selector: { identifier: id }, action: "press" });
      assert.ok(!result.isError, JSON.stringify(payload(result)));
    } else {
      const result = await act(target, observed, [{ actionId: id, operation: { kind: "press", params: { elementRef: selected.reference } }, expect: condition }]);
      assert.equal(result?.stopReason, "completed", JSON.stringify(result ?? calls.at(-1)?.result));
      assert.equal(result.steps[0].delivery, "dispatched");
      if (condition) assert.equal(result.steps[0].verification, "confirmed");
    }
    await activity?.afterMutation([id]);
  };
  const write = async (target, observed, specs, special) => {
    if (legacy) {
      assert.equal(specs.length, 1);
      const spec = specs[0], value = special === "normalize" ? "12.5" : spec.expected;
      const result = await call("set_accessibility_value", { windowId: target.windowId, selector: { identifier: spec.id }, value });
      if (spec.id === plan.config.friction?.delayed) {
        await ready(async () => assert.equal(readValue(await observe(target), spec.id), spec.expected));
      } else if (!special) assert.ok(!result.isError, JSON.stringify(payload(result)));
    } else {
      const result = await act(target, observed, specs.map(spec => setStep(observed, spec, special === "normalize" ? "12.5" : spec.expected)));
      if (special) {
        assert.ok(["verificationFailed", "deadlineExceeded"].includes(result?.stopReason), JSON.stringify(result ?? calls.at(-1)?.result));
        assert.equal(result.steps[0].delivery, "dispatched");
        assert.equal(result.steps[0].verification, "mismatch");
      } else {
        assert.equal(result?.stopReason, "completed", JSON.stringify(result ?? calls.at(-1)?.result));
        assert.equal(result.steps.length, specs.length);
        assert.ok(result.steps.every(s => s.delivery === "dispatched" && s.verification === "confirmed"));
      }
    }
    await activity?.afterMutation(specs.map(spec => spec.id));
  };
  const populate = async (target, scope) => {
    const fault = plan.config.friction;
    const remaining = scope.filter(f => f.initial !== f.expected);
    while (remaining.length) {
      const spec = remaining.shift();
      observation = await observe(target);
      if (spec.kind === "checkbox") {
        assert.equal(readValue(observation, spec.id), spec.initial);
        await press(target, observation, spec.id, valueEquals(element(observation, spec.id).reference, spec.expected));
      } else if (fault && spec.id === fault.trigger) {
        await write(target, observation, [spec]);
        // Exercise a stale ref once. The replaced field has never received input.
        if (!legacy) {
          const replaced = plan.fields.find(f => f.id === fault.recreate[0]);
          const result = await act(target, observation, [setStep(observation, replaced)]);
          assert.equal(result?.steps[0]?.delivery, "not_dispatched", JSON.stringify(result ?? calls.at(-1)?.result));
          assert.equal(result.stopReason, "targetStale");
          staleProof = result;
        }
      } else if (fault && spec.id === fault.cleared) {
        await write(target, observation, [spec], "clear");
        observation = await observe(target);
        assert.equal(readValue(observation, spec.id), "");
        assert.ok(observation.elements.some(e => String(e.value).includes(`Validation cleared ${spec.label}`)), "Public validation error is missing");
        await write(target, observation, [spec]);
      } else if (fault && spec.id === fault.decimal) {
        await write(target, observation, [spec], "normalize");
        assert.equal(readValue(await observe(target), spec.id), spec.expected);
      } else {
        const batch = [spec];
        while (batch.length < maxBatch && remaining.length && remaining[0].kind !== "checkbox" &&
            !activity?.isMilestone(batch.at(-1).id) &&
            ![fault?.trigger, fault?.cleared, fault?.decimal].includes(remaining[0].id)) batch.push(remaining.shift());
        await write(target, observation, batch);
      }
    }
  };

  try {
    fixture = new Fixture(undefined, ["--workflow", JSON.stringify(plan.config)]);
    before = await fixture.ready;
    monitor = new ForegroundMonitor(monitorBinary);
    watches.push(await monitor.begin(before.pid));
    assert.ok(foregroundProof(watches[0], before.pid) && watches[0].startedForegroundPID !== before.pid, "Fixture must begin in the background");
    const transport = new StdioClientTransport({ command: legacy ? process.execPath : host,
      args: legacy ? [path.join(root, "server.mjs")] : [], cwd: root, stderr: "pipe", env: { MACOS_COMPUTER_USE_UNSAFE: "0" } });
    hostClosed = new Promise(resolve => { transport.onclose = resolve; });
    transport.stderr?.resume();
    client = new Client({ name: "workflow-scripted", version: "1" });
    await client.connect(transport);
    const source = lookup(before, "source"), work = lookup(before, "work");
    await ready(async () => assert.equal(readValue(await observe(source), "source.instructions"), plan.config.source));
    observation = await ready(async () => {
      const observed = await observe(work);
      for (const spec of plan.fields.slice(0, task === "invoice" ? 27 : 5)) element(observed, spec.id);
      return observed;
    });
    if (plan.userActiveMilestones) {
      activity = new UserActiveActivity({ binaries: actorBinaries, targetPID: before.pid, milestones: plan.userActiveMilestones,
        snapshot: async () => { const sample = await monitor.snapshot(); watches.push(sample); return sample; } });
      await activity.start();
    }
    setupMs = performance.now() - setupStarted;
    const start = performance.now();
    if (task === "invoice") {
      assert.equal(before.submitEnabled, false);
      if (!legacy) assert.equal(element(observation, "invoice.submit").enabled, false);
      await populate(work, plan.fields);
      observation = await observe(work);
      assert.equal((await fixture.call("state")).submitEnabled, true);
      if (!legacy) assert.equal(element(observation, "invoice.submit").enabled, true);
      await press(work, observation, "invoice.submit", absent);
      const submitted = await fixture.call("state");
      const confirmation = lookup(submitted, "confirmation");
      const shown = await ready(async () => {
        const observed = await observe(confirmation);
        assert.equal(readValue(observed, "invoice.confirmed"), `Submitted PO ${plan.expected["invoice.po"]}`);
        return observed;
      });
      if (!legacy) {
        const result = await call("waitFor", { target: confirmation, observationId: shown.observationId, budgetMs, condition: exists("invoice.confirmed", "AXStaticText") });
        assert.equal(data(result)?.outcome, "satisfied");
      }
    } else {
      for (let page = 0; page < 3; page++) {
        if (page) {
          observation = await observe(work);
          await press(work, observation, `settings.tab.${page}`, exists(`settings.${page * 5}`, "AXTextField"));
        }
        observation = await observe(work);
        const visible = plan.fields.filter(spec => observation.elements.some(e => e.identifier === spec.id)).map(f => f.id);
        const group = plan.fields.slice(page * 5, page * 5 + 5);
        assert.deepEqual(visible, group.map(f => f.id), "Inactive settings controls must stay out of the AX tree");
        for (const spec of group) assert.equal(readValue(observation, spec.id), spec.initial);
        await populate(work, group);
      }
    }
    taskMs = performance.now() - start;
  } catch (err) { error = err.message; }
  finally {
    try { if (before) after = await fixture.call("state"); } catch (err) { cleanupError ??= err.message; }
    try { if (monitor) watches.push(await monitor.snapshot()); } catch (err) { cleanupError ??= err.message; }
    try { await client?.close(); } catch (err) { cleanupError ??= err.message; }
    try { await fixture?.close(); } catch (err) { cleanupError ??= err.message; }
    if (activity) {
      try {
        await stopped(hostClosed, "MCP host");
        await stopped(fixture.exited, "Workflow fixture");
        activity.evidence.controlledProcessesStopped = true;
      } catch (err) { cleanupError ??= err.message; }
    }
    // Actors remain alive until native work and all controlled fixture windows have stopped.
    try { await activity?.close(); } catch (err) { cleanupError ??= err.message; }
    try { if (monitor) watches.push(await monitor.close()); } catch (err) { cleanupError ??= err.message; }
  }
  const foreground = before ? mergeForegroundWatches(watches, before.pid) : null;
  const grade = gradeWorkflow(task, plan, before, after, foregroundProof(foreground, before?.pid), activity?.evidence);
  if (!error && variant === "friction" && !grade.normalizedInput) error = "Scripted normalization probe did not exercise the formatter";
  const outcome = error && setupMs == null ? "setup_blocked" : error ? "failed" : cleanupError ? "unknown" : grade.outcome;
  return { ...assignment, outcome, setupMs, taskMs, error, cleanupError, grade, before, after, foreground, activity: activity?.evidence, staleProof, calls };
}

const { values } = parseArgs({ options: { output: { type: "string" }, task: { type: "string" }, variant: { type: "string" }, lane: { type: "string" } } });
const options = { task: ["invoice", "settings"], variant: workflowVariants(values.variant), lane: ["legacy", "single", "composed"] };
for (const [name, allowed] of Object.entries(options)) {
  if (values[name] != null) {
    assert.ok(allowed.includes(values[name]), `Unsupported ${name}`);
    options[name] = [values[name]];
  }
}
assert.ok(values.output, "Specify a new --output directory");
const output = path.resolve(values.output);
await mkdir(output, { mode: 0o700 });
const plan = options.task.flatMap((task, i) => options.variant.flatMap((variant, j) => options.lane.map((_, k) =>
  ({ task, variant, lane: options.lane[(i + j + k) % options.lane.length], seed: `workflow-${task}-1` }))));
const actorBinaries = options.variant.includes("user-active") ? await buildUserActiveActors() : null;
const evidenceFiles = [fixturePath, ...(options.lane.includes("legacy") ? ["native_helper"] : []),
  ...(options.lane.some(lane => lane !== "legacy") ? [".artifacts/runtime-install/cua-host", ".artifacts/runtime-install/cua-runtime"] : []),
  "test/fixtures/macos/WorkflowFixture.swift", "test/workflow/scripted.mjs", "test/workflow/task.mjs",
  ...(actorBinaries ? [userActiveSource, "test/workflow/support/user-active.mjs", ...actorBinaries.flatMap(binary =>
    [path.relative(root, binary), path.relative(root, path.join(path.dirname(binary), "../Info.plist"))])] : [])];
const binariesAndSources = Object.fromEntries(await Promise.all(evidenceFiles.map(async p => [p, hash(await readFile(path.join(root, p)))])));
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const report = { mode: "oracle_informed_scripted_readiness", modelCalls: 0, source: { revision: git("rev-parse", "HEAD"),
  dirty: Boolean(git("status", "--porcelain")), sha256: binariesAndSources }, trials: plan.map(a => ({ ...a, outcome: "not_started" })) };
const save = () => writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
await save();
const monitorBinary = await buildForegroundMonitor();
for (let i = 0; i < plan.length; i++) {
  const episode = await trial(plan[i], monitorBinary, actorBinaries);
  report.trials[i] = episode;
  await save();
  const { task, variant, lane, outcome, grade, error, cleanupError } = episode;
  console.log(JSON.stringify({ task, variant, lane, outcome, grade, error, cleanupError }));
}
if (report.trials.some(e => e.outcome !== "passed")) process.exitCode = 1;
