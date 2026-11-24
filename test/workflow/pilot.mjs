import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { root, data, payload } from "../evaluation/adapters.mjs";
import { apiKeyEnvironment, ModelBudget } from "../evaluation/model.mjs";
import { foregroundProof, mergeForegroundWatches } from "../evaluation/metrics.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { buildForegroundMonitor, ForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { makeTask, gradeWorkflow } from "./task.mjs";
import { connectLane, WorkflowLane } from "./session-lane.mjs";
import { openGateway } from "./session-gateway.mjs";
import { runSession, workflowPrompt, workflowSystemPrompt } from "./session-model.mjs";
import { compareCampaign, pilotSummary } from "./session-metrics.mjs";
import { campaignAssignments, lanes, validateReviewedPilot } from "./campaign-plan.mjs";
import { UserActiveActivity, agentActivityOffsetsMs, buildUserActiveActors, exerciseDuringAgent, userActiveSource } from "./support/user-active.mjs";

export { pilotSummary } from "./session-metrics.mjs";

const hash = (value) => createHash("sha256").update(value).digest("hex");
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const fixtureBinary = "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture";
export function pilotAssignments() {
  return campaignAssignments("pilot");
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
  if (plan.userActiveMilestones) plan.userActiveMilestones = agentActivityOffsetsMs.map(ms => `session-${ms}ms`);
  const setupStart = performance.now();
  const watches = [], cleanupErrors = [];
  let fixture, monitor, before, after, client, lane, gateway, activity, activityWork, readyMs, taskStarted, session, error;
  const { abortSignal } = configuration;
  const activityStop = new AbortController();
  const prompt = workflowPrompt(assignment.task);
  const cleanup = async (step) => {
    try { await step(); return true; } catch (failure) { cleanupErrors.push(failure.message); return false; }
  };
  try {
    abortSignal?.throwIfAborted();
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
    if (plan.userActiveMilestones) {
      activity = new UserActiveActivity({ binaries: configuration.actorBinaries, targetPID: before.pid, milestones: plan.userActiveMilestones,
        snapshot: async () => { const snapshot = await monitor.snapshot(); watches.push(snapshot); return snapshot; } });
      activity.evidence.scheduledOffsetsMs = agentActivityOffsetsMs;
      await activity.start();
    }
    readyMs = performance.now() - setupStart;
    abortSignal?.throwIfAborted();
    await configuration.beforeSession?.();
    abortSignal?.throwIfAborted();
    taskStarted = performance.now();
    session = await runSession({ ...configuration, tools: lane.tools, config: gateway.config, prompt,
      onReady: () => {
        lane.stopped = false;
        if (activity) activityWork = exerciseDuringAgent(activity, activityStop.signal).catch(failure => {
          if (!activityStop.signal.aborted) activity.evidence.error = failure.message;
        });
      }, onStop: () => { lane.stopped = true; activityStop.abort(); } });
  } catch (failure) { error = failure instanceof Error ? failure.message : String(failure); }
  finally {
    activityStop.abort();
    await activityWork;
    if (gateway) await cleanup(() => gateway.close());
    const hostStopped = await cleanup(() => lane ? lane.stop() : client?.close());
    // The agent can no longer send tools when the independent final state is taken.
    if (before) await cleanup(async () => { after = await fixture.call("state"); });
    if (monitor) await cleanup(async () => { watches.push(await monitor.snapshot()); });
    const fixtureStopped = await cleanup(() => fixture?.close());
    if (activity) {
      activity.evidence.controlledProcessesStopped = hostStopped && fixtureStopped;
      await cleanup(() => activity.close());
    }
    if (monitor) await cleanup(async () => { watches.push(await monitor.close()); });
  }
  const foreground = before ? mergeForegroundWatches(watches, before.pid) : null;
  const grade = gradeWorkflow(assignment.task, plan, before, after, foregroundProof(foreground, before?.pid), activity?.evidence);
  const connection = gateway?.connectionState();
  const budgetStop = session?.limit || (session?.costUsd ?? 0) > configuration.budgetUsd;
  const partialUsage = session && (session.costUsd === null || Object.values(session.usage).some(value => value === null));
  const transportLoss = lane?.calls.some(call => call.infrastructureError);
  const outcome = abortSignal?.aborted ? "interrupted" : taskStarted == null ? "setup_blocked" : budgetStop ? "budget_stopped" : grade.outcome === "failed" ? "failed" :
    grade.outcome === "unknown" || cleanupErrors.length || partialUsage || transportLoss || !connection?.accepted || connection.refusedConnections ? "unknown" :
      session?.ok ? "passed" : "failed";
  return { ...assignment, outcome, modelStarted: taskStarted != null, readyMs, taskMs: taskStarted == null ? null : performance.now() - taskStarted,
    error, cleanupErrors, grade, before, after, foreground, connection, activity: activity?.evidence, calls: lane?.calls ?? [], session,
    promptSha256: hash(prompt), tools: lane?.tools, toolsSha256: lane ? hash(JSON.stringify(lane.tools)) : null,
    backgroundToolNames: lane?.backgroundToolNames,
    falseCompletionClaim: session?.claim === "complete" && grade.outcome === "failed",
    unknownCompletionClaim: session?.claim === "complete" && grade.outcome === "unknown" };
}

export async function withCampaignSignals(run) {
  const controller = new AbortController();
  const interrupt = () => controller.abort("SIGINT");
  const terminate = () => controller.abort("SIGTERM");
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", terminate);
  try { return await run(controller.signal); }
  finally {
    process.off("SIGINT", interrupt);
    process.off("SIGTERM", terminate);
  }
}

async function main(argv) {
  const { values } = parseArgs({ args: argv, options: {
    execute: { type: "boolean" }, output: { type: "string" }, "api-key-file": { type: "string" }, claude: { type: "string", default: "claude" },
    auth: { type: "string", default: "api-key" },
    model: { type: "string", default: "claude-sonnet-5" }, "budget-usd": { type: "string" }, "per-trial-usd": { type: "string" },
    stage: { type: "string", default: "pilot" }, "reviewed-pilot": { type: "string" },
    "max-turns": { type: "string", default: "46" }, "trial-seconds": { type: "string", default: "240" },
  } });
  const binary = values.claude, model = values.model;
  const stage = values.stage, authMode = values.auth;
  const assignments = campaignAssignments(stage);
  const budgetUsd = Number(values["budget-usd"]), perTrialUsd = Number(values["per-trial-usd"]);
  const turns = Number(values["max-turns"]), timeoutMs = Number(values["trial-seconds"]) * 1000;
  if (!Number.isInteger(turns) || turns <= 0 || !Number.isFinite(timeoutMs) || timeoutMs <= 0 || !model.startsWith("claude-")) {
    throw new Error("Provide a full Claude model ID and positive trial time and turn limits");
  }
  if (!["api-key", "terminal"].includes(authMode) || (authMode === "terminal" && values["api-key-file"])) {
    throw new Error("Select --auth api-key or --auth terminal. Only api-key accepts --api-key-file.");
  }
  if (values.execute && !(values.output && (authMode === "terminal" || values["api-key-file"]) && Number.isFinite(budgetUsd) &&
    Number.isFinite(perTrialUsd) && perTrialUsd > 0 && perTrialUsd <= budgetUsd)) {
    throw new Error("Execution requires --output, --budget-usd, --per-trial-usd and an API key file or terminal login");
  }
  const cliVersion = execFileSync(binary, ["--version"], { encoding: "utf8", timeout: 5000 }).trim();
  if (!values.execute) {
    console.log(JSON.stringify({ mode: "plan", stage, modelCalls: 0, cliVersion, model, authMode, turns, timeoutMs, assignments }, null, 2));
    return;
  }
  let reviewedPilotSha256;
  if (stage === "main") {
    if (!values["reviewed-pilot"]) throw new Error("Main execution requires --reviewed-pilot from the separately approved pilot");
    const reviewedPilot = await readFile(values["reviewed-pilot"]);
    validateReviewedPilot(JSON.parse(reviewedPilot), model);
    reviewedPilotSha256 = hash(reviewedPilot);
  }
  const consoleState = execFileSync("/usr/sbin/ioreg", ["-n", "Root", "-d1"], { encoding: "utf8", timeout: 5000 });
  if (/"CGSSessionScreenIsLocked"\s*=\s*Yes/.test(consoleState)) throw new Error("Unlock the Mac before launching a benchmark campaign");
  const output = path.resolve(values.output);
  await mkdir(output, { mode: 0o700 });
  const cwd = path.join(output, "agent-cwd");
  await mkdir(cwd, { mode: 0o700 });
  const env = Object.fromEntries(["PATH", "HOME", "LOGNAME", "USER", "LANG", "TMPDIR"].filter(key => process.env[key])
    .map(key => [key, process.env[key]]));
  let subscriptionType;
  if (authMode === "terminal") {
    const status = JSON.parse(execFileSync(binary, ["auth", "status", "--json"], { cwd, env, encoding: "utf8", timeout: 10000, stdio: ["ignore", "pipe", "ignore"] }));
    if (!status.loggedIn || status.authMethod !== "claude.ai" || status.apiProvider !== "firstParty" || !status.subscriptionType) {
      throw new Error("Terminal mode requires a first-party Claude subscription login");
    }
    subscriptionType = status.subscriptionType;
  } else {
    Object.assign(env, await apiKeyEnvironment(values["api-key-file"]));
  }
  const budget = new ModelBudget(budgetUsd, perTrialUsd);
  const files = [fixtureBinary, "native_helper", ".artifacts/runtime-install/useui", ".artifacts/runtime-install/useui-runtime",
    "test/fixtures/macos/WorkflowFixture.swift", "test/workflow/task.mjs", "test/workflow/session-lane.mjs", "test/workflow/session-gateway.mjs",
    "test/workflow/session-relay.mjs", "test/workflow/session-model.mjs", "test/workflow/session-metrics.mjs", "test/workflow/campaign-plan.mjs",
    "test/workflow/pilot.mjs", ...(stage === "main" ? [userActiveSource, "test/workflow/support/user-active.mjs"] : [])];
  const source = { revision: git("rev-parse", "HEAD"), dirty: Boolean(git("status", "--porcelain")),
    sha256: Object.fromEntries(await Promise.all(files.map(async (file) => [file, hash(await readFile(path.join(root, file)))]))) };
  const trials = assignments.map(assignment => ({ ...assignment, outcome: "not_started" }));
  const report = { schemaVersion: 2, mode: `actual_claude_session_${stage}`, stage, reviewedPilotSha256, cliVersion, model, authMode, subscriptionType, turns, timeoutMs, source,
    systemPromptSha256: hash(workflowSystemPrompt), trials, startedAt: new Date().toISOString() };
  const save = async () => {
    report.budget = budget.summary();
    report.summary = pilotSummary(trials);
    report.byLane = Object.fromEntries(lanes.map(lane => [lane, pilotSummary(trials.filter(trial => trial.lane === lane))]));
    report.comparison = compareCampaign(trials);
    const next = path.join(output, "report.tmp");
    await writeFile(next, JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    await rename(next, path.join(output, "report.json"));
  };
  await withCampaignSignals(async (abortSignal) => {
    await save();
    const monitorBinary = abortSignal.aborted ? null : await buildForegroundMonitor();
    const actorBinaries = !abortSignal.aborted && stage === "main" ? await buildUserActiveActors() : null;
    if (actorBinaries) {
      source.sha256.actorBinaries = await Promise.all(actorBinaries.map(async file => hash(await readFile(file))));
      report.userActivityOffsetsMs = agentActivityOffsetsMs;
    }
    let stopReason;
    for (const [index, assignment] of assignments.entries()) {
      if (abortSignal.aborted) {
        trials[index] = { ...assignment, outcome: "interrupted", modelStarted: false, error: "Campaign stopped before admission" };
        continue;
      }
      const allowance = budget.allowance();
      if (stopReason || allowance === null) {
        trials[index] = { ...assignment, outcome: "budget_stopped", error: stopReason ?? "Remaining budget cannot reserve another trial" };
        continue;
      }
      const trial = await pilotTrial(assignment, { binary, cwd, env, model, turns, timeoutMs, budgetUsd: allowance, authMode, abortSignal, actorBinaries,
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
      } else if (trial.modelStarted) {
        budget.record({ costUsd: null });
        stopReason = "A started model session has no attributable cost";
      }
      trials[index] = trial;
      await save();
      console.log(JSON.stringify({ ...assignment, outcome: trial.outcome, estimatedCostUsd: trial.session?.costUsd ?? null }));
    }
    report.finishedAt = new Date().toISOString();
    report.interruption = abortSignal.reason ?? null;
    await save();
    if (abortSignal.aborted) process.exitCode = abortSignal.reason === "SIGINT" ? 130 : 143;
    else if (trials.some(trial => trial.outcome !== "passed")) process.exitCode = 1;
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) await main(process.argv.slice(2));
