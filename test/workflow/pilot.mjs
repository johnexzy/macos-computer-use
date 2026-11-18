import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { root, data, payload } from "../evaluation/adapters.mjs";
import { apiKeyEnvironment, ModelBudget } from "../evaluation/model.mjs";
import { foregroundProof, mergeForegroundWatches, usageSummary } from "../evaluation/metrics.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { buildForegroundMonitor, ForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { makeTask, gradeWorkflow } from "./task.mjs";
import { connectLane, WorkflowLane } from "./session-lane.mjs";
import { openGateway } from "./session-gateway.mjs";
import { runSession, workflowPrompt, workflowSystemPrompt } from "./session-model.mjs";

const hash = (value) => createHash("sha256").update(value).digest("hex");
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const fixtureBinary = "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture";
const lanes = ["legacy", "single", "composed"];

export function pilotAssignments() {
  return ["invoice", "settings"].flatMap((task, i) => ["clean", "friction"].flatMap((variant, j) => lanes.map((_, k) =>
    ({ task, variant, lane: lanes[(i + j + k) % lanes.length], seed: `workflow-${task}-1` }))));
}

async function readiness(client, assignment, before, plan) {
  const legacy = assignment.lane === "legacy";
  const deadline = performance.now() + 6000;
  let lastError;
  while (performance.now() < deadline) {
    try {
      const [source, work] = ["source", "work"].map(key => before.windows.find(w => w.key === key));
      const inspect = async (windowId) => {
        const name = legacy ? "inspect_accessibility" : "observe";
        const args = legacy ? { windowId, includeValues: true } : { target: { pid: before.pid, windowId }, includeValues: true, budgetMs: 1500 };
        const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 2500 });
        if (result.isError) throw new Error("Fixture AX read unavailable");
        return (legacy ? payload(result) : data(result))?.elements ?? [];
      };
      const sourceElements = await inspect(source.windowId);
      const workElements = await inspect(work.windowId);
      if (sourceElements.find(e => e.identifier === "source.instructions")?.value !== plan.config.source ||
          !plan.fields.slice(0, assignment.task === "invoice" ? 27 : 5).every(field => workElements.some(e => e.identifier === field.id))) {
        throw new Error("The source and work controls are not fully observable");
      }
      return;
    } catch (error) { lastError = error; }
    await sleep(80);
  }
  throw lastError;
}

export async function pilotTrial(assignment, configuration, monitorBinary) {
  const plan = makeTask(assignment.task, assignment.variant, assignment.seed);
  const setupStart = performance.now();
  const watches = [], cleanupErrors = [];
  let fixture, monitor, before, after, client, lane, gateway, readyMs, taskStarted, session, error;
  const prompt = workflowPrompt(assignment.task);
  const cleanup = async (step) => { try { await step(); } catch (failure) { cleanupErrors.push(failure.message); } };
  try {
    fixture = new Fixture(undefined, ["--workflow", JSON.stringify(plan.config)]);
    before = await fixture.ready;
    monitor = new ForegroundMonitor(monitorBinary);
    const start = await monitor.begin(before.pid);
    watches.push(start);
    if (foregroundProof(start, before.pid) !== true || start.startedForegroundPID === before.pid) throw new Error("Fixture must start in the background");
    const connected = await connectLane(assignment.lane);
    client = connected.client;
    await readiness(client, assignment, before, plan);
    lane = new WorkflowLane({ lane: assignment.lane, ...connected, readFixture: () => fixture.call("state"), before, plan });
    lane.stopped = true;
    gateway = await openGateway(lane);
    readyMs = performance.now() - setupStart;
    await configuration.beforeSession?.();
    taskStarted = performance.now();
    session = await runSession({ ...configuration, tools: lane.tools, config: gateway.config, prompt,
      onReady: () => { lane.stopped = false; }, onStop: () => { lane.stopped = true; } });
  } catch (failure) { error = failure.message; }
  finally {
    if (gateway) await cleanup(() => gateway.close());
    if (lane) await cleanup(() => lane.stop());
    else if (client) await cleanup(() => client.close());
    // The agent can no longer send tools when the independent final state is taken.
    if (before) await cleanup(async () => { after = await fixture.call("state"); });
    if (monitor) await cleanup(async () => { watches.push(await monitor.snapshot()); });
    if (fixture) await cleanup(() => fixture.close());
    if (monitor) await cleanup(async () => { watches.push(await monitor.close()); });
  }
  const foreground = before ? mergeForegroundWatches(watches, before.pid) : null;
  const grade = gradeWorkflow(assignment.task, plan, before, after, foregroundProof(foreground, before?.pid));
  const connection = gateway?.connectionState();
  const budgetStop = session?.subtype === "error_max_budget_usd" || (session?.costUsd ?? 0) > configuration.budgetUsd;
  const partialUsage = session && (session.costUsd === null || Object.values(session.usage).some(value => value === null));
  const transportLoss = lane?.calls.some(call => call.infrastructureError);
  const outcome = taskStarted == null ? "setup_blocked" : budgetStop ? "budget_stopped" : grade.outcome === "failed" ? "failed" :
    grade.outcome === "unknown" || cleanupErrors.length || partialUsage || transportLoss || !connection?.accepted || connection.refusedConnections ? "unknown" :
      session?.ok && session.claim === "complete" ? "passed" : "failed";
  return { ...assignment, outcome, readyMs, taskMs: taskStarted == null ? null : performance.now() - taskStarted,
    error, cleanupErrors, grade, before, after, foreground, connection, calls: lane?.calls ?? [], session,
    promptSha256: hash(prompt), tools: lane?.tools, toolsSha256: lane ? hash(JSON.stringify(lane.tools)) : null,
    falseCompletionClaim: session?.claim === "complete" && grade.outcome === "failed",
    unknownCompletionClaim: session?.claim === "complete" && grade.outcome === "unknown" };
}

export function pilotSummary(trials) {
  const sessions = trials.flatMap(t => t.session ? [t.session] : []);
  const strictSuccesses = trials.filter(t => t.outcome === "passed").length;
  const model = usageSummary(sessions);
  const sorted = trials.flatMap(t => t.taskMs == null ? [] : [t.taskMs]).sort((a,b) => a - b);
  const quantile = (q) => sorted.length ? sorted[Math.ceil(q * sorted.length) - 1] : null;
  return { assigned: trials.length, strictSuccesses, strictSuccessRate: trials.length ? strictSuccesses / trials.length : null,
    outcomes: Object.fromEntries([...new Set(trials.map(t => t.outcome))].map(outcome => [outcome, trials.filter(t => t.outcome === outcome).length])),
    taskMs: { samples: sorted.length, p50: quantile(0.5), p90: quantile(0.9) },
    toolCalls: trials.reduce((sum, t) => sum + (t.calls?.length ?? 0), 0),
    fieldsCorrect: trials.reduce((sum, t) => sum + (t.grade?.correctFields ?? 0), 0),
    fieldMutationAttempts: trials.reduce((sum, t) => sum + (t.grade?.mutationAttempts ?? 0), 0),
    navigationPresses: trials.reduce((sum, t) => sum + (t.grade?.navigationPresses ?? 0), 0),
    submitAttempts: trials.reduce((sum, t) => sum + (t.after?.events.filter(e => e.kind === "submit_attempt").length ?? 0), 0),
    falseCompletionClaims: trials.filter(t => t.falseCompletionClaim).length,
    model, dollarsPerSuccessfulTask: strictSuccesses && model.reportedCostUsd !== null ? model.reportedCostUsd / strictSuccesses : null };
}

async function main(argv) {
  const { values } = parseArgs({ args: argv, options: {
    execute: { type: "boolean" }, output: { type: "string" }, "api-key-file": { type: "string" }, claude: { type: "string", default: "claude" },
    model: { type: "string", default: "claude-sonnet-5" }, "budget-usd": { type: "string" }, "per-trial-usd": { type: "string" },
    "max-turns": { type: "string", default: "46" }, "trial-seconds": { type: "string", default: "240" },
  } });
  const binary = values.claude, model = values.model;
  const assignments = pilotAssignments();
  const budgetUsd = Number(values["budget-usd"]), perTrialUsd = Number(values["per-trial-usd"]);
  const turns = Number(values["max-turns"]), timeoutMs = Number(values["trial-seconds"]) * 1000;
  if (!Number.isInteger(turns) || turns <= 0 || !Number.isFinite(timeoutMs) || timeoutMs <= 0 || !model.startsWith("claude-")) {
    throw new Error("Provide a full Claude model ID and positive trial time and turn limits");
  }
  if (values.execute && !(values.output && values["api-key-file"] && Number.isFinite(budgetUsd) &&
    Number.isFinite(perTrialUsd) && perTrialUsd > 0 && perTrialUsd <= budgetUsd)) {
    throw new Error("After budget approval, specify --execute, --output, --api-key-file, --budget-usd and --per-trial-usd");
  }
  const cliVersion = execFileSync(binary, ["--version"], { encoding: "utf8", timeout: 5000 }).trim();
  if (!values.execute) {
    console.log(JSON.stringify({ mode: "plan", modelCalls: 0, cliVersion, model, turns, timeoutMs, assignments }, null, 2));
    return;
  }
  const output = path.resolve(values.output);
  await mkdir(output, { mode: 0o700 });
  const cwd = path.join(output, "agent-cwd");
  await mkdir(cwd, { mode: 0o700 });
  const keyEnv = await apiKeyEnvironment(values["api-key-file"]);
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: process.env.LANG ?? "en_US.UTF-8", ANTHROPIC_API_KEY: keyEnv.ANTHROPIC_API_KEY };
  const budget = new ModelBudget(budgetUsd, perTrialUsd);
  const files = [fixtureBinary, "native_helper", ".artifacts/runtime-install/cua-host", ".artifacts/runtime-install/cua-runtime",
    "test/fixtures/macos/WorkflowFixture.swift", "test/workflow/task.mjs", "test/workflow/session-lane.mjs", "test/workflow/session-gateway.mjs",
    "test/workflow/session-relay.mjs", "test/workflow/session-model.mjs", "test/workflow/pilot.mjs"];
  const source = { revision: git("rev-parse", "HEAD"), dirty: Boolean(git("status", "--porcelain")),
    sha256: Object.fromEntries(await Promise.all(files.map(async (file) => [file, hash(await readFile(path.join(root, file)))]))) };
  const trials = assignments.map(assignment => ({ ...assignment, outcome: "not_started" }));
  const report = { schemaVersion: 1, mode: "actual_claude_session_pilot", cliVersion, model, turns, timeoutMs, source,
    systemPromptSha256: hash(workflowSystemPrompt), trials, startedAt: new Date().toISOString() };
  const save = async () => {
    report.budget = budget.summary();
    report.summary = pilotSummary(trials);
    report.byLane = Object.fromEntries(lanes.map(lane => [lane, pilotSummary(trials.filter(trial => trial.lane === lane))]));
    const next = path.join(output, "report.tmp");
    await writeFile(next, JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    await rename(next, path.join(output, "report.json"));
  };
  await save();
  const monitorBinary = await buildForegroundMonitor();
  let stopReason;
  for (const [index, assignment] of assignments.entries()) {
    const allowance = budget.allowance();
    if (stopReason || allowance === null) {
      trials[index] = { ...assignment, outcome: "budget_stopped", error: stopReason ?? "Remaining budget cannot reserve another trial" };
      continue;
    }
    const trial = await pilotTrial(assignment, { binary, cwd, env, model, turns, timeoutMs, budgetUsd: allowance,
      beforeSession: async () => {
        trials[index] = { ...assignment, outcome: "admitted", reservedUsd: allowance };
        await save();
      } }, monitorBinary);
    if (trial.session) {
      budget.record(trial.session);
      const { records, ...summary } = trial.session;
      const stream = `session-${index + 1}.jsonl`;
      await writeFile(path.join(output, stream), records.map(entry => JSON.stringify(entry)).join("\n") + "\n", { mode: 0o600 });
      trial.session = { ...summary, stream, retainedStreamSha256: hash(await readFile(path.join(output, stream))) };
      if (!summary.modelOk || !summary.inventoryOk || summary.costUsd === null || summary.costUsd > allowance) stopReason = "Model, inventory or cost admission check failed";
    } else if (trial.outcome !== "setup_blocked") {
      stopReason = "A started model session has no attributable cost";
    }
    trials[index] = trial;
    await save();
    console.log(JSON.stringify({ ...assignment, outcome: trial.outcome, estimatedCostUsd: trial.session?.costUsd ?? null }));
  }
  report.finishedAt = new Date().toISOString();
  await save();
  if (trials.some(trial => trial.outcome !== "passed")) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) await main(process.argv.slice(2));
