import assert from "node:assert/strict";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { runSession, summarizeSession } from "./session-model.mjs";
import { pilotAssignments, pilotSummary } from "./pilot.mjs";
import { WorkflowLane } from "./session-lane.mjs";
import { makeTask } from "./task.mjs";
import { compareCampaign } from "./session-metrics.mjs";
import { campaignAssignments, validateReviewedPilot } from "./campaign-plan.mjs";
import { renderCampaign } from "./report.mjs";

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
  assert.equal(parsed(init, auxiliary).limit, "turns");
  assert.equal(parsed(init, { ...final, subtype: "error_max_budget_usd" }).limit, "cost");
  assert.equal(parsed(init, final).limit, null);
  assert.equal(parsed(init, auxiliary).costUsd, 0.4);
  assert.equal(parsed(init, auxiliary).usage.cacheReadInputTokens, 400);
  const wrongAssistantModel = parsed(init, { type: "assistant", message: { model: "claude-other" } }, final);
  assert.equal(wrongAssistantModel.ok, false);
  assert.equal(wrongAssistantModel.costUsd, 0.4);
  const unrecognizedClaim = parsed(init, { ...final, result: "The workflow is finished." });
  assert.equal(unrecognizedClaim.ok, true);
  assert.equal(unrecognizedClaim.claim, null);
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
  assert.equal(result.limit, "time");
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

test("SIGTERM on the campaign stops an active session and preserves unknown cost", async () => {
  const agentScript = `console.log(JSON.stringify({ ...${JSON.stringify(init)}, workerPid: process.pid })); setInterval(() => {}, 1000);`;
  const script = `
import { withCampaignSignals } from ${JSON.stringify(new URL("./pilot.mjs", import.meta.url).href)};
import { runSession } from ${JSON.stringify(new URL("./session-model.mjs", import.meta.url).href)};
const summary = await withCampaignSignals(async abortSignal => {
  const result = await runSession({
    binary: process.execPath, prefix: ["-e", ${JSON.stringify(agentScript)}, "--"],
    env: {}, model: "claude-test", tools: [{ name: "targets" }], cwd: process.cwd(), config: {}, prompt: "offline", budgetUsd: 1,
    turns: 1, timeoutMs: 3000, abortSignal, onReady: () => process.kill(process.pid, "SIGTERM"),
  });
  return { stopped: abortSignal.reason, failure: result.failure, cost: result.costUsd, pid: result.records[0].workerPid };
});
console.log(JSON.stringify(summary));`;
  const { stdout } = await promisify(execFile)(process.execPath, ["--input-type=module", "-e", script], { timeout: 6000 });
  const { pid, ...result } = JSON.parse(stdout);
  assert.deepEqual(result, { stopped: "SIGTERM", failure: "Campaign interrupted", cost: null });
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
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
  assert.equal(pilotSummary([completed, { outcome: "admitted" }]).dollarsPerSuccessfulTask, null);
  assert.equal(pilotSummary([completed, { outcome: "interrupted", modelStarted: true }]).dollarsPerSuccessfulTask, null);
  assert.equal(pilotSummary([failed]).dollarsPerSuccessfulTask, null);
});

test("report keeps separate matched cohorts, missing field evidence and complete denominators", () => {
  const trials = pilotAssignments().map(assignment => ({ ...assignment, outcome: "budget_stopped" }));
  trials[0] = { ...trials[0], outcome: "passed", taskMs: 30, grade: { correctFields: 27, requiredFields: 27,
    wrongTargetAttempts: 0, unnecessaryWrites: 0, targetActivationPreserved: true }, session: { costUsd: 1, numTurns: 5, usage: final.modelUsage[model] },
    calls: [{ result: { isError: true } }, { handedOff: true, result: { isError: true } }] };
  const summary = pilotSummary(trials);
  assert.deepEqual(summary.fields, { assigned: 252, assessed: 27, correct: 27, unassessed: 225 });
  assert.equal(summary.strictSuccessRate, 1 / 12);
  assert.equal(summary.safety.preHandoffRefusals, 1);
  assert.ok(summary.strictSuccessWilson95.lower < 1 / 12 && summary.strictSuccessWilson95.upper > 1 / 12);
  const { byCohort, pairs } = compareCampaign(trials);
  assert.equal(Object.keys(byCohort).length, 12);
  assert.equal(Object.keys(pairs).length, 4);
  assert.equal(pairs["invoice/clean/workflow-invoice-1"].legacy.costUsd, 1);
  assert.equal(pairs["invoice/clean/workflow-invoice-1"].single.outcome, "budget_stopped");
  const markdown = renderCampaign({ stage: "pilot", mode: "actual_claude_session_pilot", finishedAt: "2026-11-18",
    model, source: { revision: "offline-test" }, trials });
  assert.match(markdown, /\| legacy \| \$1\.0000 \| \$1\.0000 \| 1\/4/);
  assert.match(markdown, /\| 0\/0 \(1\/1\) \| 1 \|/);
  assert.match(markdown, /\| — \(0\/1\) \| 0 \|/);
});

test("main pairs all 180 assignments and requires a finalized priced pilot", () => {
  const main = campaignAssignments("main");
  assert.equal(main.length, 180);
  assert.equal(main.filter(trial => trial.variant === "user-active").length, 60);
  const { byCohort, pairs } = compareCampaign(main.map(assignment => ({ ...assignment, outcome: "budget_stopped" })));
  assert.equal(Object.keys(byCohort).length, 18);
  assert.ok(Object.values(byCohort).every(cohort => cohort.assigned === 10));
  assert.equal(Object.keys(pairs).length, 60);
  assert.ok(Object.values(pairs).every(pair => Object.keys(pair).length === 3));
  const markdown = renderCampaign({ stage: "main", mode: "actual_claude_session_main", finishedAt: "2026-11-18",
    model, source: { revision: "offline-test" }, trials: main.map(assignment => ({ ...assignment, outcome: "budget_stopped" })) });
  assert.match(markdown, /180 assigned trials \(180 budget_stopped\)/);
  assert.match(markdown, /\| Lane \| USD \/ success \| Total USD \|/);
  assert.match(markdown, /\| legacy \| — \| — \| 0\/60 \(0\.0%\)/);
  assert.match(markdown, /\| invoice \| user-active \| composed \| 0\/10/);
  assert.match(markdown, /Wilson 95%/);
  const pilot = { mode: "actual_claude_session_pilot", model, finishedAt: "2026-11-18", trials: campaignAssignments("pilot").map((assignment, index) => ({
    ...assignment, outcome: "failed", modelStarted: true,
    session: { sessionId: `session-${index}`, sameSession: true, inventoryOk: true, modelOk: true, costUsd: 1 },
  })), summary: { model: { reportedCostUsd: 12 } } };
  assert.doesNotThrow(() => validateReviewedPilot(pilot, model));
  assert.throws(() => validateReviewedPilot({ ...pilot, mode: "offline_fake_cli" }, model), /reviewed pilot report/);
  assert.throws(() => validateReviewedPilot(pilot, "claude-other"), /requested model/);
  assert.throws(() => validateReviewedPilot({ ...pilot, model: null }, model), /requested model/);
  const incomplete = structuredClone(pilot);
  Object.assign(incomplete.trials[0], { outcome: "setup_blocked", modelStarted: false, session: null });
  assert.throws(() => validateReviewedPilot(incomplete, model), /every assignment/);
  const reused = structuredClone(pilot);
  reused.trials[0].session.sessionId = reused.trials[1].session.sessionId;
  assert.throws(() => validateReviewedPilot(reused, model), /distinct verified session/);
  const mismatched = structuredClone(pilot);
  mismatched.trials[0].session.modelOk = false;
  assert.throws(() => validateReviewedPilot(mismatched, model), /requested model/);
  pilot.trials[0].session.costUsd = null;
  assert.throws(() => validateReviewedPilot(pilot, model), /known model cost/);
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
