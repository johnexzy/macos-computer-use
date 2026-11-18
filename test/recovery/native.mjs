import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { Session, root } from "../runtime/mcp-session.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { ForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { foregroundProof, mergeForegroundWatches } from "../evaluation/metrics.mjs";
import { RouteEvidence, recover, toolPayload } from "./recovery.mjs";
import { gradeState } from "./oracle.mjs";

export const nativeCases = ["already-complete", "known-unsent", "unknown-delivery", "recreated-control", "ambiguous", "stale-visual"];
const primary = state => state.windows.find(window => window.key === "primary");
const nativeData = (response, kind) => {
  const body = toolPayload(response)?.body;
  if (body?.result !== kind) throw new Error(body?.data?.code ?? "Native result unavailable");
  return body.data;
};
const hashFile = async file => createHash("sha256").update(await fs.readFile(path.join(root, file))).digest("hex");

export async function nativeProvenance() {
  const files = [".artifacts/runtime-install/cua-host", ".artifacts/runtime-install/cua-runtime",
    "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture"];
  return { revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
    dirty: Boolean(execFileSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" }).trim()),
    osVersion: execFileSync("/usr/bin/sw_vers", ["-productVersion"], { encoding: "utf8" }).trim(),
    sha256: Object.fromEntries(await Promise.all(files.map(async file => [file, await hashFile(file)]))) };
}

function oracleState(state) {
  return { controls: primary(state).controls.map(control => ({ identifier: control.identifier,
    generation: `${primary(state).generation}/${control.generation}`, value: control.modelValue, controlValue: control.controlValue,
    attempts: control.attempts, writes: control.appliedWrites })),
    protectedValue: JSON.stringify(state.windows.filter(window => window.key !== "primary").map(window => ({ key: window.key,
      generation: window.generation, visible: window.visible, pressCount: window.pressCount,
      controls: window.controls.map(control => ({ identifier: control.identifier, generation: control.generation,
        modelValue: control.modelValue, controlValue: control.controlValue, enabled: control.enabled, attached: control.attached,
        attempts: control.attempts, appliedWrites: control.appliedWrites, selection: control.selection })) }))),
    layout: state.windows.map(window => ({ key: window.key, generation: window.generation, title: window.title, frame: window.frame })),
    targetActivated: state.activationCount > 0, targetForeground: state.foregroundPID === state.pid,
    pending: state.windows.flatMap(window => window.controls).reduce((sum, control) => sum + control.pendingWrites.length, 0) };
}

export async function runNative(caseId, seed, policy, provenance, monitorBinary) {
  const episode = { caseId, seed, policy, mode: "native_scripted_conformance", outcome: "setup_blocked", trace: [], foregroundSamples: [] };
  let session, fixture, monitor, monitoredPID, setup, original, beforeRepair, final;
  let phase = "setup";
  const began = performance.now();
  const watch = async operation => {
    try { const sample = await operation(); episode.foregroundSamples.push(sample); return sample; }
    catch (error) {
      episode.foregroundSamples.push({ targetPID: monitoredPID, available: false, truncated: false, targetActivations: null });
      throw error;
    }
  };
  const oracle = async () => {
    let timer;
    try { return await Promise.race([fixture.call("state"), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Independent oracle exceeded 500ms")), 500); })]); }
    finally { clearTimeout(timer); }
  };
  try {
    session = new Session(); await session.initialize();
    const permissions = nativeData(await session.tool("capabilities"), "capabilities").permissions;
    episode.permissions = permissions;
    if (!permissions.accessibility) throw new Error("Accessibility permission unavailable");
    fixture = new Fixture(); let state = await fixture.ready;
    if (state.activationCount !== 0 || state.foregroundPID === state.pid) throw new Error("Fixture must start in the background");
    const target = { pid: state.pid, windowId: primary(state).windowId };
    monitoredPID = state.pid;
    monitor = new ForegroundMonitor(monitorBinary);
    const initialWatch = await watch(() => monitor.begin(state.pid));
    if (foregroundProof(initialWatch, state.pid) !== true || initialWatch.startedForegroundPID === state.pid) throw new Error("Independent foreground monitor unavailable or target foreground");
    const tool = async (name, args) => {
      const start = performance.now(), response = await session.tool(name, args);
      episode.trace.push({ phase, name, args, response: toolPayload(response), elapsedMs: performance.now() - start });
      return response;
    };
    const observe = async (budgetMs = 500, visual = false) => nativeData(await tool("observe", { target, includeValues: true, budgetMs,
      ...(visual ? { includeOcr: true, ocrQuery: "original", maxImageDimensionPx: 512 } : {}) }), "observe");
    // AX publication is an unmeasured setup gate, never a favorable retry of a graded mutation.
    let ready;
    const readyUntil = performance.now() + 5000;
    while (!ready && performance.now() < readyUntil) {
      try { const value = await observe(500); if (["primary.first", "primary.second"].every(id => value.elements.some(item => item.identifier === id))) ready = value; }
      catch { /* Setup only. */ }
      if (!ready) await pause(40);
    }
    if (!ready) throw new Error("Fixture AX readiness unavailable");
    const warmControl = ready.elements.find(item => item.identifier === "primary.second");
    const warmRequest = { target, observationId: ready.observationId, budgetMs: 500, steps: [{ actionId: "route-warmup",
      operation: { kind: "setValue", params: { elementRef: warmControl.reference, value: `${seed}-warmup` } } }] };
    const warm = nativeData(await tool("act", warmRequest), "act");
    const scope = { bundleId: "com.johnoba.cua.fixture", appVersion: provenance.sha256["test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture"],
      runtimeVersion: provenance.sha256[".artifacts/runtime-install/cua-runtime"], osVersion: provenance.osVersion,
      instanceId: state.runNonce, pid: state.pid, windowId: target.windowId };
    const routes = new RouteEvidence();
    if (!routes.record({ scope, control: warmControl, observationId: ready.observationId, receipt: warm.steps[0], now: performance.now() })) throw new Error("Actual semantic route warmup was not confirmed");
    state = await fixture.call("configure", { control: "second", value: caseId === "already-complete" ? `${seed}-goal-1` : "primary-second-original" });
    const origin = await observe(500);
    original = oracleState(await oracle());
    const goals = ["primary.first", "primary.second"].map((identifier, index) => ({ identifier, actionId: `set-${index}`, value: `${seed}-goal-${index}` }));
    const request = { target, observationId: origin.observationId, budgetMs: 500, steps: goals.map((goal, index) => {
      const control = origin.elements.find(item => item.identifier === goal.identifier);
      return { actionId: goal.actionId, operation: { kind: "setValue", params: { elementRef: control.reference, value: goal.value } },
        ...(index ? { precondition: { kind: "valueEquals", params: { elementRef: control.reference, value: "PER13-guard-not-ready" } } } : {}) };
    }) };
    phase = "initial";
    let response = await tool("act", request);
    const actual = nativeData(response, "act");
    if (actual.stopReason !== "preconditionFailed" || actual.steps[0]?.verification !== "confirmed" || actual.steps[1]?.delivery !== "not_dispatched") throw new Error("Controlled partial-state receipt was not established");
    phase = "fault_setup";
    if (caseId === "unknown-delivery") {
      // Explicit harness fault: hide the terminal suffix; do not claim an actual helper death.
      response = { structuredContent: { version: 1, route: "rust_host", error: { code: "controlled_response_loss" }, uncertainty: {
        observation_id: request.observationId, settled_steps: [actual.steps[0]], unacknowledged_action_ids: ["set-1"] } } };
    }
    if (caseId === "recreated-control") await fixture.call("recreate", { control: "second" });
    if (caseId === "ambiguous") {
      state = await fixture.call("state"); const frame = primary(state).frame;
      await fixture.call("configure", { window: "primary", title: "PER13 duplicate", frame });
      await fixture.call("configure", { window: "secondary", title: "PER13 duplicate", frame });
    }
    let artifact = null;
    if (caseId === "stale-visual") {
      artifact = await observe(1000, true);
      if (artifact.visual?.captureStatus !== "captured") throw new Error("Explicit visual evidence unavailable");
      state = await fixture.call("state"); const frame = primary(state).frame;
      await fixture.call("configure", { frame: { ...frame, x: frame.x + 40 } });
    }
    if (["stale-visual", "recreated-control"].includes(caseId)) {
      const readyUntil = performance.now() + 3000; let published = false;
      while (!published && performance.now() < readyUntil) {
        try {
          const value = await observe(500);
          published = value.elements.some(item => item.identifier === "primary.second") &&
            (caseId !== "stale-visual" || JSON.stringify(value.windowBounds) !== JSON.stringify(artifact.windowBounds));
        } catch { /* Controlled fault publication, outside the repair budget. */ }
        if (!published) await pause(40);
      }
      if (!published) throw new Error("Controlled fault did not reach the public AX surface");
    }
    beforeRepair = oracleState(await oracle());
    setup = { request, response, goals, scope, routes, artifact,
      port: { observe: remaining => observe(Math.min(500, remaining)),
        async observeVisual(identifier, previous, remaining) {
          const control = previous.elements.find(item => item.identifier === identifier);
          return nativeData(await tool("observe", { target, includeValues: true, includeOcr: true, ocrQuery: control.value,
            maxImageDimensionPx: 768, budgetMs: Math.min(1000, remaining) }), "observe");
        },
        async validate(record, value, remaining) {
          const reply = toolPayload(await tool("waitFor", { target, observationId: record.observationId, budgetMs: Math.min(500, remaining),
            condition: { kind: "valueEquals", params: { elementRef: record.control.reference, value } } }));
          return reply?.body?.result === "waitFor" ? reply.body.data : { outcome: "unavailable", errorCode: reply?.body?.data?.code };
        }, act: args => tool("act", args) } };
    episode.initialRequest = request; episode.initialResponse = toolPayload(response);
    episode.erroneousStateSha256 = createHash("sha256").update(JSON.stringify(beforeRepair)).digest("hex");
    phase = "repair";
    episode.recovery = await recover({ ...setup, policy, enabled: policy !== "none" });
    episode.routeRecords = routes.records;
    episode.invalidatedRouteRecords = routes.invalidated;
    final = oracleState(await oracle());
  } catch (error) { episode.error = error.message; }
  finally {
    const clean = async operation => { try { await operation(); } catch (error) { (episode.cleanupErrors ??= []).push(error.message); } };
    if (session) await clean(() => session.close());
    if (fixture && setup) await clean(async () => { final = oracleState(await oracle()); });
    if (monitor) await clean(() => watch(() => monitor.snapshot()));
    if (fixture) await clean(() => fixture.close());
    if (monitor) await clean(() => watch(() => monitor.close()));
  }
  episode.wallMs = performance.now() - began;
  if (setup && original && beforeRepair && final) {
    const foreground = final.targetActivated || final.targetForeground ? false
      : foregroundProof(mergeForegroundWatches(episode.foregroundSamples, setup.scope.pid), setup.scope.pid);
    episode.unassisted = gradeState({ original, beforeRepair: original, after: beforeRepair, goals: setup.goals, foreground });
    episode.final = gradeState({ original, beforeRepair, after: final, goals: setup.goals, foreground });
    episode.outcome = episode.error || episode.cleanupErrors?.length || foreground === null ? "unknown"
      : episode.recovery?.budgetStopped ? "budget_stopped" : episode.final.strictCompletion ? "passed" : "failed";
    episode.oracle = { original, beforeRepair, final };
  }
  episode.model = { runs: false, tokens: null, costUsd: null };
  return episode;
}
