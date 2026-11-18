import assert from "node:assert/strict";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { runSession, summarizeSession } from "./session-model.mjs";
import { pilotAssignments, pilotSummary } from "./pilot.mjs";
import { WorkflowLane } from "./session-lane.mjs";
import { makeTask } from "./task.mjs";

const model = "claude-test";
const tools = [{ name: "targets" }];
const init = { type: "system", subtype: "init", session_id: "one", model, tools: ["mcp__workflow__targets"], mcp_servers: [{ name: "workflow", status: "connected" }] };
const final = { type: "result", subtype: "success", session_id: "one", result: "COMPLETE", total_cost_usd: 0.4,
  usage: { input_tokens: 9000 }, modelUsage: { [model]: { inputTokens: 18, outputTokens: 4, cacheReadInputTokens: 200, cacheCreationInputTokens: 12 } } };
const parsed = (...records) => summarizeSession(records, { model, tools, exitCode: 0 });

test("terminal usage is counted once and absent or duplicate results are unpriced", () => {
  assert.equal(parsed(init, { type: "assistant", usage: { input_tokens: 1000 } }, final).usage.inputTokens, 18);
  assert.equal(parsed(init, final).costUsd, 0.4);
  assert.equal(parsed(init).costUsd, null);
  assert.equal(parsed(init, final, final).costUsd, null);
  assert.equal(parsed(final, init).ok, false);
  const auxiliary = { ...final, subtype: "error_max_turns", modelUsage: { ...final.modelUsage, other: final.modelUsage[model] } };
  assert.equal(parsed(init, auxiliary).ok, false);
  assert.equal(parsed(init, auxiliary).costUsd, 0.4);
  assert.equal(parsed(init, auxiliary).usage.cacheReadInputTokens, 400);
});

const childSession = (script, options = {}) => runSession({ binary: process.execPath, prefix: ["-e", script, "--"], env: {},
  cwd: process.cwd(), model, tools, config: {}, prompt: "offline", budgetUsd: 1, turns: 3, timeoutMs: 4000, ...options });

test("an out-of-order init cannot open tool admission after terminal output", async () => {
  let opened = 0;
  const result = await childSession(`process.stdout.write(${JSON.stringify([final, init].map(entry => JSON.stringify(entry)).join("\n") + "\n")})`,
    { onReady: () => { opened++; } });
  assert.equal(result.ok, false);
  assert.equal(opened, 0);
  assert.match(result.failure, /preceded CLI initialization/);
});

test("timeout stops descendants even if the session leader exits first", async () => {
  const script = `const { spawn } = require('node:child_process');
const peer = spawn(process.execPath, ['-e', 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)'], { stdio: 'ignore' });
console.log(JSON.stringify({ type: 'test_peer', pid: peer.pid }));
process.on('SIGTERM', () => process.exit(0));
setInterval(() => {}, 1000);`;
  const result = await childSession(script, { timeoutMs: 650 });
  const pid = result.records.find(record => record.type === "test_peer")?.pid;
  assert.ok(pid);
  assert.match(result.failure, /wall-clock budget/);
  try {
    for (let i = 0; i < 20; i++) {
      try { process.kill(pid, 0); } catch (err) { if (err.code === "ESRCH") return; throw err; }
      await sleep(50);
    }
    assert.fail("Session process group survived teardown");
  } finally {
    try { process.kill(pid, "SIGKILL"); } catch (err) { if (err.code !== "ESRCH") throw err; }
  }
});

test("pilot includes all assignments and prices failures in dollars per success", () => {
  const grid = pilotAssignments();
  assert.equal(grid.length, 12);
  assert.equal(new Set(grid.map(row => `${row.task}/${row.variant}/${row.lane}`)).size, 12);
  const usage = final.modelUsage[model];
  const completed = { outcome: "passed", session: { costUsd: 0.5, usage } };
  const failed = { outcome: "failed", session: { costUsd: 0.25, usage } };
  assert.equal(pilotSummary([completed, failed, { outcome: "budget_stopped" }]).dollarsPerSuccessfulTask, 0.75);
  assert.equal(pilotSummary([completed, { ...failed, session: { ...failed.session, costUsd: null } }]).dollarsPerSuccessfulTask, null);
  assert.equal(pilotSummary([failed]).dollarsPerSuccessfulTask, null);
});

test("fresh references cannot replay an unknown mutation, while a settled visible validation clear can be corrected once", async () => {
  const plan = makeTask("invoice", "friction", "ledger");
  const id = plan.config.friction.cleared;
  const label = plan.fields.find(field => field.id === id).label;
  const state = { pid: 90, runNonce: "fixture", windows: [{ key: "work", windowId: 19, visible: true }], values: { [id]: "" },
    generations: { [id]: 1 }, events: [] };
  const target = { pid: 90, windowId: 19 };
  const schema = name => ({ name, inputSchema: { type: "object", properties: { steps: { type: "array" } } } });
  const reply = (result, data) => ({ structuredContent: { body: { result, data } }, content: [] });
  let acts = 0, observations = 0, mode = "lost";
  const client = { async callTool({ name, arguments: args }) {
    if (name === "observe") {
      observations++;
      return reply("observe", { observationId: `obs-${observations}`, elements: [{ identifier: id, reference: `ref-${observations}`, value: "" },
        ...(state.events.length ? [{ value: `Validation cleared ${label}. Enter the value again.` }] : [])] });
    }
    acts++;
    if (mode === "lost") throw new Error("Helper lost");
    if (mode === "host_refusal") return { isError: true, content: [], structuredContent: { version: 1, route: "rust_host",
      delivery: "not_dispatched", verification: "unverified", error: { code: "deadlineExceeded" } } };
    if (!state.events.length) state.events.push({ kind: "validation_cleared", id, generation: 1 });
    return reply("act", { observationId: args.observationId, remainingSteps: 0, stopReason: "deadlineExceeded",
      steps: [{ actionId: "write", delivery: "dispatched", verification: "mismatch", reason: "deadlineExceeded", evidence: [{ matched: false }] }] });
  } };
  const makeLane = () => new WorkflowLane({ lane: "composed", client, tools: [schema("observe"), schema("act")],
    readFixture: async () => structuredClone(state), before: state, plan });
  const attempt = async (lane) => {
    await lane.call("observe", { target, includeValues: true });
    return lane.call("act", { target, observationId: `obs-${observations}`, steps: [{ actionId: "write",
      operation: { kind: "setValue", params: { elementRef: `ref-${observations}`, value: "item" } } }] });
  };
  const uncertain = makeLane();
  assert.equal((await attempt(uncertain)).isError, true);
  assert.equal((await attempt(uncertain)).isError, true);
  assert.equal(acts, 1);
  mode = "host_refusal";
  const corrected = makeLane();
  assert.equal((await attempt(corrected)).isError, true);
  mode = "dispatched";
  assert.equal((await attempt(corrected)).structuredContent.body.result, "act");
  assert.equal((await attempt(corrected)).structuredContent.body.result, "act");
  assert.equal((await attempt(corrected)).isError, true);
  assert.equal(acts, 4);
});
