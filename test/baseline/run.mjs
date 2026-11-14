import { AsyncLocalStorage } from "node:async_hooks";
import { execFile, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";
import { compareCampaigns, compareConditions, summarize, usageFields } from "./metrics.mjs";
import { assessRefusal, controlValues, fixtureWrites } from "./oracle.mjs";

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const { values } = parseArgs({ options: {
  output: { type: "string" }, repetitions: { type: "string", default: "3" },
  preflight: { type: "boolean", default: false }, compare: { type: "string" },
} });
const repetitions = Number(values.repetitions);
if (!Number.isInteger(repetitions) || repetitions < 1 || repetitions > 20) {
  throw new Error("--repetitions must be an integer from 1 to 20");
}
const output = path.resolve(values.output || path.join(root, ".artifacts/baseline", new Date().toISOString().replaceAll(":", "-")));
await fs.mkdir(output, { recursive: true });
const trace = [];
const scope = new AsyncLocalStorage();
const helperPath = path.join(root, "native_helper");
const fixturePath = path.join(root, "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture");
const phaseFor = (command) => ({ ax_inspect: "ax_traversal_roundtrip", ax_set_value: "action_readback_roundtrip",
  match_text: "helper_startup_proxy", ocr: "ocr_roundtrip" }[command] || "helper_roundtrip");
const { NativeBridge } = await import("../../dist/core/native-bridge.js");
const originalCall = NativeBridge.call;
NativeBridge.call = async function (args) {
  const start = performance.now();
  let result, error;
  try { result = await originalCall.call(this, args); return result; }
  catch (caught) { error = caught; throw caught; }
  finally {
    const entry = { event: "native_call", command: args[0], phase: phaseFor(args[0]),
      elapsedMs: performance.now() - start,
      responseBytes: result ? Buffer.byteLength(JSON.stringify(result)) : null,
      error: error ? { code: error.code, message: error.message } : null };
    scope.getStore()?.phases.push(entry);
    trace.push({ ...entry, caseId: scope.getStore()?.caseId ?? null,
      repeat: scope.getStore()?.repeat ?? null, requestId: scope.getStore()?.requestId ?? null });
  }
};

class Fixture {
  constructor() {
    this.pending = new Map();
    this.child = spawn(fixturePath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.ready = new Promise((resolve, reject) => { this.resolveReady = resolve; this.rejectReady = reject; });
    this.startTimer = setTimeout(() => this.rejectReady(new Error("Fixture did not become ready")), 8000);
    this.reader = createInterface({ input: this.child.stdout });
    this.reader.on("line", (line) => {
      const message = JSON.parse(line);
      if (message.event === "ready") { clearTimeout(this.startTimer); this.resolveReady(message.state); }
      else {
        const pending = this.pending.get(message.id);
        if (pending) { clearTimeout(pending.timer); this.pending.delete(message.id); pending.resolve(message); }
      }
    });
    this.child.stderr.on("data", (data) => trace.push({ event: "fixture_diagnostic", text: data.toString() }));
    const fail = (error) => {
      clearTimeout(this.startTimer); this.rejectReady(error);
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
      this.pending.clear();
    };
    this.child.on("error", fail);
    this.child.on("exit", () => fail(new Error("Fixture exited")));
  }
  async call(command, args = {}) {
    const id = randomUUID();
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Fixture ${command} timed out`)); }, 5000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ id, command, ...args })}\n`);
    }).then((response) => {
      trace.push({ event: "fixture_call", caseId: scope.getStore()?.caseId ?? null,
        repeat: scope.getStore()?.repeat ?? null, request: { id, command, ...args }, response });
      if (response.status !== "ok") throw new Error(JSON.stringify(response));
      return response.state;
    });
  }
  async close() {
    try { if (this.child.exitCode === null) await this.call("quit"); }
    finally { this.reader.close(); if (this.child.exitCode === null) this.child.kill(); }
  }
}

const cases = [
  { id: "set-value/clean", kind: "mutation", condition: "clean", change: null },
  { id: "set-value/ignored", kind: "mutation", condition: "adverse", change: "ignored" },
  { id: "set-value/delayed", kind: "mutation", condition: "adverse", change: "delayed" },
  { id: "set-value/reordered", kind: "mutation", condition: "adverse", change: "reorder" },
  { id: "set-value/already-satisfied", kind: "already_satisfied", condition: "adverse", change: "already_satisfied" },
  { id: "target-safety/recreated", kind: "refusal", condition: "adverse", change: "recreate",
    refusalCodes: ["STALE_ELEMENT", "STALE_OBSERVATION", "TARGET_STALE", "ACCESSIBILITY_ELEMENT_NOT_FOUND", "staleElement", "staleObservation"] },
  { id: "target-safety/reopened", kind: "refusal", condition: "adverse", change: "close_reopen",
    refusalCodes: ["TARGET_NOT_FOUND", "TARGET_STALE", "targetNotFound", "staleElement"] },
  { id: "target-safety/duplicate-label", kind: "refusal", condition: "adverse", change: "duplicate",
    refusalCodes: ["AMBIGUOUS_TARGET", "ACCESSIBILITY_AMBIGUOUS", "AMBIGUOUS_MATCH", "ambiguousTarget"] },
  { id: "target-safety/ambiguous-windows", kind: "refusal", condition: "adverse", change: "ambiguous_windows",
    refusalCodes: ["AMBIGUOUS_TARGET", "AMBIGUOUS_WINDOW", "ambiguousTarget"] },
];
const windowOf = (state, key) => state.windows.find((window) => window.key === key);
const controlOf = (state, window = "primary", key = "first") => windowOf(state, window).controls.find((control) => control.key === key);
function payload(result) { return JSON.parse(result.content.find((part) => part.type === "text").text); }
function verifiedClaim(result) {
  const p = payload(result);
  return !result.isError && (p.status === "delivered_verified" || p.execution?.verification === "value_readback");
}
function traceResult(result) {
  return { ...result, content: result.content.map((part) => part.type === "image"
    ? { type: "image", mimeType: part.mimeType, bytes: Buffer.from(part.data, "base64").length,
      sha256: createHash("sha256").update(Buffer.from(part.data, "base64")).digest("hex") } : part) };
}

const hash = async (file) => createHash("sha256").update(await fs.readFile(file)).digest("hex");
const git = async (...args) => (await exec("git", args, { cwd: root })).stdout.trim();
const capabilities = await NativeBridge.getCapabilities();
const report = {
  schemaVersion: 1, campaignId: randomUUID(), startedAt: new Date().toISOString(),
  implementation: "legacy-typescript-swift", invocation: "in-process tool registry; MCP transport excluded",
  source: { revision: await git("rev-parse", "HEAD"), dirty: Boolean(await git("status", "--porcelain")),
    legacySourceRevision: await git("log", "-1", "--format=%H", "--", "src", "native"),
    helperSha256: await hash(helperPath) },
  environment: { platform: os.platform(), release: os.release(), architecture: os.arch(),
    cpu: os.cpus()[0]?.model, memoryBytes: os.totalmem(), node: process.version,
    macOS: (await exec("sw_vers", ["-productVersion"])).stdout.trim(), capabilities,
    display: await NativeBridge.call(["size"]) },
  model: { runs: false, id: null, reason: "Scripted driver scenarios; no model inference or paid campaign" },
  budgets: { repetitions, oracleTimeoutMs: 1000, fixtureRequestTimeoutMs: 5000,
    nativeCallTimeoutMs: null, nativeCallLimitReason: "Legacy NativeBridge has no native request deadline" },
  taskSet: cases.map((c) => ({ ...c, instruction: c.kind !== "refusal"
    ? "Set the observed primary.first control to the trial value; preserve every other control and foreground application."
    : "Refuse the stale or ambiguous observed target without mutating another control." })),
  measurementNotes: [
    "NativeBridge samples include helper startup, native work, JSON and IPC; component samples overlap and must not be subtracted.",
    "match_text is a helper-startup proxy, not isolated startup time. Capture is CLI wall time; OCR is capture-free helper roundtrip.",
    "Refusal correctness is separate from mutation completion. Unknown oracle results never establish success.",
    "Endpoint foreground sampling cannot exclude transient focus theft. Model usage/cost and human-rescue metrics are unmeasured.",
    "Scenario latency includes observation/action/oracle convergence and excludes separate helper-startup and capture/OCR probes.",
  ],
  episodes: [],
};

async function callTool(registry, episode, name, args) {
  const started = performance.now();
  const requestId = randomUUID();
  episode.toolCalls++;
  let result, error;
  try {
    result = await scope.run({ ...episode, requestId }, () => registry.invoke(name, args));
    episode.responseBytes += Buffer.byteLength(JSON.stringify(result));
    return result;
  } catch (caught) { error = caught; throw caught; }
  finally {
    trace.push({ event: "tool_call", caseId: episode.caseId, repeat: episode.repeat,
      request: { id: requestId, name, arguments: args }, elapsedMs: performance.now() - started,
      result: result ? traceResult(result) : null, error: error ? { message: error.message } : null });
  }
}

async function visualProbes(windowId, episode) {
  if (!capabilities.permissions.screenRecording) {
    trace.push({ event: "phase_blocked", phase: "capture_and_ocr", reason: "screen_recording_permission_required" });
    return;
  }
  const image = path.join(output, `fixture-${episode.repeat}.png`);
  const started = performance.now();
  await exec("/usr/sbin/screencapture", ["-x", "-o", "-l", String(windowId), image], { timeout: 5000 });
  episode.phases.push({ phase: "capture_cli", elapsedMs: performance.now() - started });
  const bounds = await NativeBridge.call(["get_window_bounds", String(windowId)]);
  const ocr = await NativeBridge.call(["ocr", image, "nil", String(bounds.bounds.width), "false"]);
  trace.push({ event: "ocr_probe", caseId: episode.caseId, result: ocr, image });
}

let fixture;
try {
  if (!values.preflight && capabilities.permissions.accessibility) {
    const { createToolRegistry } = await import("../../dist/server.js");
    const registry = createToolRegistry();
    report.source.fixtureSha256 = await hash(fixturePath);
    for (let repeat = 0; repeat < repetitions; repeat++) {
      for (const scenario of cases) {
        const episode = { caseId: scenario.id, kind: scenario.kind, condition: scenario.condition,
          fixtureSeed: "two-window-v1", repeat, outcome: "unknown", completionClaim: null,
          verificationClaim: false, effectObserved: null, phases: [], toolCalls: 0,
          nativeActionRequests: 0, responseBytes: 0, usage: Object.fromEntries(usageFields.map((key) => [key, null])) };
        episode.assisted = false;
        await scope.run(episode, async () => {
          fixture = new Fixture();
          const ready = await fixture.ready;
          episode.fixtureStartup = { startedForegroundPid: ready.startedForegroundPID,
            foregroundPid: ready.foregroundPID, activations: ready.activationCount };
          if (ready.activationCount > 0 || ready.foregroundPID === ready.pid || ready.foregroundPID !== ready.startedForegroundPID) {
            episode.outcome = "setup_blocked";
            episode.reason = "fixture_startup_foreground_interference";
            return;
          }
          let state = await fixture.call("reset");
          if (["ignored", "delayed", "already_satisfied"].includes(scenario.change)) {
            state = await fixture.call("configure", { window: "primary", control: "first",
              mode: scenario.change === "already_satisfied" ? "ignored" : scenario.change, delayMs: 150 });
          }
          if (scenario.change === "ambiguous_windows") {
            const frame = windowOf(state, "primary").frame;
            await fixture.call("configure", { window: "primary", title: "CUA Fixture — Duplicate", frame });
            state = await fixture.call("configure", { window: "secondary", title: "CUA Fixture — Duplicate", frame });
          }
          const before = state;
          const windowId = windowOf(before, "primary").windowId;
          const value = scenario.change === "already_satisfied" ? controlOf(before).controlValue : `trial-${repeat}-requested`;
          episode.alreadySatisfied = scenario.change === "already_satisfied";
          episode.fixtureRunNonce = state.runNonce;
          episode.resetGeneration = state.resetGeneration;
          await NativeBridge.call(["match_text", "startup probe", "probe", "word"]);
          const started = performance.now();
          const foregroundBefore = await NativeBridge.getFrontmostApplication();
          if (foregroundBefore.pid === before.pid) {
            episode.outcome = "setup_blocked";
            episode.reason = "fixture_already_foreground";
            return;
          }
          const observed = await callTool(registry, episode, "inspect_accessibility", { windowId,
            roles: ["AXTextField"], includeValues: true });
          if (observed.isError) throw new Error(`Fixture AX inspection failed: ${JSON.stringify(observed)}`);
          if (["reorder", "recreate", "close_reopen"].includes(scenario.change)) {
            state = await fixture.call(scenario.change, { window: "primary", control: "first" });
          }
          const actionStartState = state;
          trace.push({ event: "action_start_state", caseId: episode.caseId, repeat, state: actionStartState });
          const result = await callTool(registry, episode, "set_accessibility_value", { windowId,
            selector: scenario.change === "duplicate" ? { role: "AXTextField", title: "Value" }
              : { role: "AXTextField", identifier: "primary.first" }, value });
          episode.verificationClaim = verifiedClaim(result);
          let after = await fixture.call("state");
          const settleStarted = performance.now();
          while (scenario.kind === "mutation" && controlOf(after).controlValue !== value &&
            performance.now() - settleStarted < report.budgets.oracleTimeoutMs) {
            await new Promise((resolve) => setTimeout(resolve, 25));
            after = await fixture.call("state");
          }
          episode.phases.push({ phase: "oracle_convergence", elapsedMs: performance.now() - settleStarted });
          const sameIdentity = controlOf(after).generation === controlOf(before).generation &&
            windowOf(after, "primary").generation === windowOf(before, "primary").generation;
          const changed = controlValues(after).filter((row) => row[0] !== "primary" || row[1] !== "first");
          const preserved = controlValues(before).filter((row) => row[0] !== "primary" || row[1] !== "first");
          const beforeWrites = fixtureWrites(actionStartState), afterWrites = fixtureWrites(after);
          episode.fixtureWriteAttempts = afterWrites.attempts - beforeWrites.attempts;
          episode.fixtureAppliedWrites = afterWrites.applied - beforeWrites.applied;
          episode.effectObserved = scenario.kind === "mutation" ? sameIdentity &&
            controlOf(after).modelValue === value && controlOf(after).controlValue === value : null;
          const mutationSatisfied = sameIdentity && controlOf(after).modelValue === value && controlOf(after).controlValue === value;
          episode.outcome = scenario.kind !== "refusal"
            ? mutationSatisfied && JSON.stringify(changed) === JSON.stringify(preserved) ? "passed" : "failed"
            : (episode.refusal = assessRefusal(result, actionStartState, after, scenario.refusalCodes)).passed ? "passed" : "failed";
          const foregroundAfter = await NativeBridge.getFrontmostApplication();
          episode.foreground = { beforePid: foregroundBefore.pid, afterPid: foregroundAfter.pid,
            preserved: foregroundBefore.pid === foregroundAfter.pid,
            fixtureActivationDelta: after.activationCount - before.activationCount };
          if (!episode.foreground.preserved || episode.foreground.fixtureActivationDelta > 0) episode.outcome = "failed";
          episode.elapsedMs = performance.now() - started;
          episode.oracle = { before, after, sameIdentity };
          trace.push({ event: "oracle", caseId: episode.caseId, repeat, before, after, outcome: episode.outcome });
          if (scenario.id === "set-value/clean") {
            try { await visualProbes(windowId, episode); }
            catch (error) { trace.push({ event: "phase_error", phase: "capture_and_ocr", message: error.message }); }
          }
        }).catch((error) => { episode.error = error.message; episode.outcome = "unknown"; })
          .finally(async () => {
            episode.nativeActionRequests = episode.phases.filter((phase) => phase.command === "ax_set_value").length;
            if (fixture) {
              try { await fixture.close(); }
              catch (error) { episode.cleanupError = error.message; process.exitCode = 1; }
              fixture = null;
            }
          });
        report.episodes.push(episode);
      }
    }
  } else if (!values.preflight) {
    for (let repeat = 0; repeat < repetitions; repeat++) for (const scenario of cases) {
      report.episodes.push({ caseId: scenario.id, kind: scenario.kind, repeat, fixtureSeed: "two-window-v1",
        outcome: "setup_blocked", reason: "accessibility_permission_required", phases: [],
        toolCalls: 0, nativeActionRequests: 0, responseBytes: 0, completionClaim: null,
        usage: Object.fromEntries(usageFields.map((key) => [key, null])) });
    }
    process.exitCode = 2;
  }
} finally {
  if (fixture) {
    try { await fixture.close(); }
    catch (error) { report.cleanupError = error.message; process.exitCode = 1; }
  }
  NativeBridge.call = originalCall;
  report.finishedAt = new Date().toISOString();
  report.summary = summarize(report.episodes, { repetitions });
  report.conditionComparison = compareConditions(report.episodes, "set-value/clean",
    cases.filter((c) => c.kind === "mutation" && c.condition === "adverse").map((c) => c.id));
  if (values.compare) report.comparison = compareCampaigns(JSON.parse(await fs.readFile(values.compare, "utf8")), report);
  await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
  await fs.writeFile(path.join(output, "trace.jsonl"), trace.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  console.log(JSON.stringify({ report: path.join(output, "report.json"), summary: report.summary }, null, 2));
}
