// Opt-in live AppKit comparison. No models, screenshots, existing apps, or global input.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { parseArgs } from "node:util";
import { Session, root } from "../runtime/mcp-session.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { ForegroundMonitor, buildForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { cpuMilliseconds, foregroundProof, toastClaims, summarize, laneOrder } from "./metrics.mjs";
import { selectedArgs, widerReadReason } from "./policy.mjs";

const { values } = parseArgs({ options: { repetitions: { type: "string", default: "3" }, output: { type: "string" } } });
const repetitions = Number(values.repetitions);
assert.ok(Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 5);
const output = path.resolve(values.output || path.join(root, ".artifacts/selective-observation", new Date().toISOString().replaceAll(":", "-")));
await fs.mkdir(output, { recursive: true });
const fixtureBinary = path.join(root, "test/fixtures/selective/.build/CUASelectiveFixture.app/Contents/MacOS/CUASelectiveFixture");
const monitorBinary = await buildForegroundMonitor(); // Compilation is outside setup and graded timing.
const hash = async (file) => createHash("sha256").update(await fs.readFile(file)).digest("hex");
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const report = { schemaVersion: 1, startedAt: new Date().toISOString(), repetitions, lanes: ["full", "selected", "retained"],
  source: { revision: git("rev-parse", "HEAD"), dirty: Boolean(git("status", "--porcelain")),
    hostSha256: await hash(path.join(root, ".artifacts/runtime-install/cua-host")),
    helperSha256: await hash(path.join(root, ".artifacts/runtime-install/cua-runtime")), fixtureSha256: await hash(fixtureBinary),
    monitorSha256: await hash(monitorBinary) },
  budgets: { requestMs: 3000, setupMs: 5000, turnAfterScenarioMs: 700 },
  model: { providerCalls: 0, actualTokens: null, actualCostUsd: null },
  episodes: Array.from({ length: repetitions }, (_, repeat) => laneOrder(repeat).map((lane) => ({
    lane, repeat, outcome: "not_started", strictCompletion: null, workflowCompletion: null,
    responseBytes: 0, requestBytes: 0, setupResponseBytes: 0, historySamples: 0, escalations: [], calls: [] }))).flat(),
  notes: ["Matched scripted evidence comparison, not autonomous model effectiveness or a provider token/cost comparison.",
    "Fresh fixture/helper per trial; paired timing schedule per repetition. All assigned trials remain in the denominator.",
    "Delayed dialog is an in-window native AppKit confirmation group, not an OS sheet or new modal window.",
    "Toast timing oracle is native model journal, not AX readback. Reads wholly inside visibility are true, disjoint reads false, boundary-overlapping reads unknown.",
    "Tool wire bytes include MCP response duplication, setup and requery calls. Fixed MCP initialization/notifications are excluded; no bytes/4 token estimate is reported.",
    "ps CPU counters have centisecond resolution; RSS has KiB units. Two endpoint samples are not peak RSS. Fixture/monitor/helper/host CPU are separate.",
    "Retention rereads share the serial action worker: long operations can delay and miss short transients. Notifications are wakeups, never event-state proof.",
    "History sample counts are returned counters through the last history read; later samples before cleanup are not included in that count."] };
const trace = [];
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
const data = (response) => response.result?.structuredContent?.body?.data;
const kind = (response) => response.result?.structuredContent?.body?.result;
function processes(pids) {
  try {
    const text = execFileSync("ps", ["-p", pids.filter(Boolean).join(","), "-o", "pid=,time=,rss="], { encoding: "utf8", timeout: 2000 });
    return Object.fromEntries(text.trim().split("\n").filter(Boolean).map((line) => {
      const [pid, cpu, rss] = line.trim().split(/\s+/);
      return [pid, { cpuMs: cpuMilliseconds(cpu), rssKiB: Number(rss) }];
    }));
  } catch { return null; }
}
function processDelta(before, after, pid) {
  const a = before?.[pid], b = after?.[pid];
  return !a || !b || a.cpuMs == null || b.cpuMs == null ? null :
    { cpuMs: b.cpuMs - a.cpuMs, maxObservedRssKiB: Math.max(a.rssKiB, b.rssKiB), samples: 2 };
}
const selectors = [
  { role: "AXTextField", label: null, identifier: "field" },
  { role: "AXStaticText", label: null, identifier: "toast" },
  { role: "AXGroup", label: null, identifier: "dialog" },
  { role: "AXButton", label: null, identifier: "dialog.ack" },
];
report.summary = summarize(report.episodes); await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
for (const episode of report.episodes) {
  const { lane, repeat } = episode;
  episode.outcome = "unknown";
  let session, fixture, monitor, state, target, measuring = false, scenarioStarted, measuredStarted, startedCpu, startedProcesses;
  const observations = [], watches = [], responseBytes = new Map(), historyCounts = new Map(); let cursor;
  const call = async (name, args = {}) => {
    const id = session.next + 1;
    const requestBytes = Buffer.byteLength(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } })) + 1;
    const started = performance.now(), response = await session.tool(name, args), elapsedMs = performance.now() - started;
    const bytes = responseBytes.get(id);
    assert.ok(Number.isInteger(bytes), "Actual response wire byte count missing");
    episode.requestBytes += requestBytes; episode.responseBytes += bytes;
    if (!measuring) episode.setupResponseBytes += bytes;
    episode.calls.push({ phase: measuring ? "case" : "setup", name, elapsedMs, requestBytes, responseBytes: bytes });
    trace.push({ event: "tool_call", lane, repeat, phase: measuring ? "case" : "setup", name, args, response, elapsedMs, requestBytes, responseBytes: bytes });
    return response;
  };
  const read = async () => {
    const args = lane === "full" ? { target, includeValues: true } : selectedArgs(target, selectors, { includeValues: true, retain: lane === "retained", cursor });
    const response = await call("observe", { ...args, budgetMs: 3000 });
    assert.equal(kind(response), "observe", JSON.stringify(response));
    const observation = data(response); observations.push(observation);
    if (observation.events) {
      cursor = observation.events.cursor;
      historyCounts.set(cursor.generation, Math.max(historyCounts.get(cursor.generation) || 0, observation.events.sampleCount));
      episode.historySamples = [...historyCounts.values()].reduce((sum, count) => sum + count, 0);
    }
    const reason = widerReadReason(observation);
    if (reason) {
      episode.escalations.push(reason);
      const wider = await call("observe", { target, includeValues: true, budgetMs: 3000 });
      assert.equal(kind(wider), "observe", JSON.stringify(wider)); observations.push(data(wider)); return data(wider);
    }
    return observation;
  };
  const act = async (observation, operation, expect) => {
    const response = await call("act", { observationId: observation.observationId, target,
      steps: [{ actionId: `action-${episode.calls.length}`, operation, precondition: null, expect: expect ?? null }], budgetMs: 3000 });
    assert.equal(kind(response), "act", JSON.stringify(response));
    const result = data(response), step = result.steps[0];
    // Never replay a failed/unknown input or continue this scripted mutation sequence after it.
    assert.equal(result.stopReason, "completed", JSON.stringify(result));
    assert.equal(step.delivery, "dispatched"); assert.equal(step.verification, "confirmed");
    assert.equal(step.route, operation.kind === "setValue" ? "axSetValue" : "axPress");
  };
  try {
    session = new Session(); session.output.on("line", (line) => { responseBytes.set(JSON.parse(line).id, Buffer.byteLength(line) + 1); });
    await session.initialize(); const capabilities = await call("capabilities");
    assert.equal(data(capabilities)?.permissions?.accessibility, true, "Accessibility preflight unavailable; no permission request is made");
    fixture = new Fixture((entry) => trace.push({ lane, repeat, ...entry }), [], fixtureBinary); state = await fixture.ready;
    target = { pid: state.pid, windowId: state.windowId };
    assert.notEqual(state.foregroundPID, state.pid); assert.equal(state.activationCount, 0);
    monitor = new ForegroundMonitor(monitorBinary); watches.push(await monitor.begin(state.pid));
    assert.equal(watches[0]?.available, true, "Independent foreground monitoring unavailable");
    assert.equal(watches[0]?.targetPID, state.pid); assert.equal(watches[0]?.truncated, false);
    assert.notEqual(watches[0]?.startedForegroundPID, state.pid, "Fixture became foreground before monitoring began");
    const setupStarted = performance.now(); let initial;
    while (performance.now() - setupStarted < 5000) {
      const response = await call("observe", { target, budgetMs: 1000 });
      if (kind(response) === "observe" && data(response).elements.some((control) => control.identifier === "field")) { initial = data(response); break; }
      await pause(20);
    }
    assert.ok(initial, "Read-only semantic readiness exceeded setup budget");
    episode.setupMs = performance.now() - setupStarted;
    measuring = true; startedCpu = process.cpuUsage(); measuredStarted = performance.now();
    startedProcesses = processes([session.helperPid, session.child.pid, fixture.child.pid, monitor.child.pid]);
    const before = await read();
    const field = before.elements.find((element) => element.identifier === "field"); assert.ok(field);
    scenarioStarted = performance.now();
    state = await fixture.call("scenario", { toastDelayMs: 120 + repeat * 10, toastDurationMs: 180, dialogDelayMs: 450 + repeat * 10 });
    episode.scenarioGeneration = state.generation;
    const value = `done-${state.runNonce}-${repeat}`; episode.expectedValue = value;
    await act(before, { kind: "setValue", params: { elementRef: field.reference, value } });
    await pause(700 - (performance.now() - scenarioStarted));
    const next = await read();
    const ack = next.elements.find((element) => element.identifier === "dialog.ack"); assert.ok(ack, "Delayed dialog not found on second turn");
    await act(next, { kind: "press", params: { elementRef: ack.reference } },
      { kind: "elementAbsent", params: { selector: { role: "AXButton", label: null, identifier: "dialog.ack" } } });
    await read(); state = await fixture.call("state");
    episode.workflowCompletion = state.modelValue === value && state.controlValue === value && state.writes === 1 && state.acknowledged === 1 && !state.dialogPresent;
    episode.oracle = state; episode.toastClaims = toastClaims(observations, state.journal);
    episode.missedToast = episode.toastClaims.some((claim) => claim.truth === true) ? false :
      episode.toastClaims.some((claim) => claim.truth == null) ? null : true;
    episode.elapsedMs = performance.now() - scenarioStarted;
    const after = processes([session.helperPid, session.child.pid, fixture.child.pid, monitor.child.pid]);
    episode.resources = { helper: processDelta(startedProcesses, after, session.helperPid), host: processDelta(startedProcesses, after, session.child.pid),
      fixture: processDelta(startedProcesses, after, fixture.child.pid), monitor: processDelta(startedProcesses, after, monitor.child.pid), runnerCpu: process.cpuUsage(startedCpu) };
    episode.measuredMs = performance.now() - measuredStarted;
    watches.push(await monitor.snapshot());
  } catch (error) { episode.error = error.stack; episode.outcome = measuring ? "failed" : "setup_blocked"; }
  finally {
    try { if (fixture) { state = await fixture.call("state"); episode.finalOracle = state; } } catch (error) { episode.cleanupError = error.message; }
    try { await session?.close(); } catch (error) { episode.cleanupError ||= error.message; }
    try { await fixture?.close(); } catch (error) { episode.cleanupError ||= error.message; }
    try { if (monitor) watches.push(await monitor.close()); } catch (error) { watches.push(null); episode.monitorError = error.message; }
    episode.foregroundWatches = watches; episode.foregroundPreserved = target ? foregroundProof(watches, state, target.pid) : null;
    const falseClaim = episode.toastClaims?.some((claim) => claim.truth === false);
    if (episode.error || episode.cleanupError || episode.workflowCompletion === false || episode.missedToast === true || falseClaim || episode.foregroundPreserved === false) {
      episode.strictCompletion = episode.outcome === "setup_blocked" ? null : false;
      if (episode.outcome === "unknown") episode.outcome = "failed";
    } else if (episode.workflowCompletion === true && episode.missedToast === false && episode.foregroundPreserved === true) {
      episode.strictCompletion = true; episode.outcome = "passed";
    }
  }
  await fs.writeFile(path.join(output, "trace.jsonl"), trace.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  report.summary = summarize(report.episodes); await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
}
report.finishedAt = new Date().toISOString(); report.summary = summarize(report.episodes);
await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
console.log(JSON.stringify({ output, summary: report.summary }));
if (report.episodes.some((episode) => episode.outcome === "setup_blocked" || episode.cleanupError || episode.strictCompletion == null ||
  episode.workflowCompletion !== true || episode.foregroundPreserved === false || episode.toastClaims?.some((claim) => claim.truth === false) ||
  (episode.lane === "retained" && episode.strictCompletion !== true))) process.exitCode = 1;
