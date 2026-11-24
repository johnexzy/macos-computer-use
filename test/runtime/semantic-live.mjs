// Live mutations are confined to the disposable fixture's fields and button.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { parseArgs } from "node:util";
import { Session, root } from "./mcp-session.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { distribution } from "../baseline/metrics.mjs";

const { values } = parseArgs({ options: { repetitions: { type: "string", default: "3" }, output: { type: "string" } } });
const repetitions = Number(values.repetitions);
assert.ok(Number.isInteger(repetitions) && repetitions > 0 && repetitions <= 5);
const output = path.resolve(values.output || path.join(root, ".artifacts/semantic-live", new Date().toISOString().replaceAll(":", "-")));
await fs.mkdir(output, { recursive: true });
const trace = [], episodes = [];
const windowOf = (s, key = "primary") => s.windows.find((w) => w.key === key);
const fieldOf = (s, key = "first", window = "primary") => windowOf(s, window).controls.find((c) => c.key === key);
const targetOf = (s, window = "primary") => ({ pid: s.pid, windowId: windowOf(s, window).windowId });
const native = (response) => response.result?.structuredContent;
const receipt = (response) => native(response)?.body?.data;
const resultKind = (response) => native(response)?.body?.result;
const stepOf = (response) => resultKind(response) === "act" ? receipt(response).steps[0] : null;
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate, ms = 3000) {
  const started = performance.now();
  while (performance.now() - started < ms) { const value = await predicate(); if (value) return value; await pause(10); }
  throw new Error("Independent setup/oracle wait exceeded budget");
}
function stableValues(before, after, except = []) {
  for (const win of before.windows) {
    const current = windowOf(after, win.key);
    assert.equal(current.pressCount, win.pressCount);
    for (const field of win.controls) if (!except.includes(field.identifier)) {
      const now = current.controls.find((c) => c.identifier === field.identifier);
      assert.equal(now.modelValue, field.modelValue, `${field.identifier} model changed`);
      assert.equal(now.controlValue, field.controlValue, `${field.identifier} control changed`);
      assert.equal(now.attempts, field.attempts, `${field.identifier} received unintended input`);
    }
  }
}
function expectRefusal(response, reasons = ["targetStale", "unsupported"]) {
  const step = stepOf(response);
  if (step) {
    assert.equal(step.delivery, "not_dispatched");
    assert.ok(reasons.includes(receipt(response).stopReason), JSON.stringify(native(response)));
  } else {
    assert.equal(resultKind(response), "error");
    assert.ok(["staleObservation", "staleElement", "targetNotFound", "ambiguousTarget"].includes(receipt(response).code));
  }
}

const cases = [
  "private-observation", "clean-set", "ignored-set", "delayed-set", "already-satisfied", "reorder", "recreated", "reopened",
  "wrong-window", "different-session", "disabled", "ambiguous-windows", "same-title-siblings", "wait-already-satisfied", "wait-delayed",
  "type-selection", "type-private", "press", "cross-helper-contention", "lock-owner-death",
];

const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const hash = async (file) => createHash("sha256").update(await fs.readFile(file)).digest("hex");
const report = { schemaVersion: 1, startedAt: new Date().toISOString(), repetitions,
  source: { revision: git("rev-parse", "HEAD"), dirty: Boolean(git("status", "--porcelain")),
    hostSha256: await hash(path.join(root, ".artifacts/runtime-install/useui")),
    helperSha256: await hash(path.join(root, ".artifacts/runtime-install/useui-runtime")),
    fixtureSha256: await hash(path.join(root, "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture")) },
  environment: { macOS: execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).trim(), cpu: os.cpus()[0].model, architecture: os.arch() },
  budgets: { nativeRequestMs: 3000, registrationMs: 3000, oracleMs: 3000 },
  model: { runs: false, tokens: null, costUsd: null }, cases, episodes,
  notes: ["Fixture-conformance checks, not autonomous task-success claims. Ignored writes are expected noncompletion with honest receipts.",
    "Fresh fixture process per trial; target registration is a separate setup gate, not a fixed sleep or part of measured case latency.",
    "CG/AX association uses unique public metadata, not OS-attested window-ID equivalence. AX state collection is not atomic.",
    "Foreground PIDs and fixture activation counters cannot rule out transient or external foreground changes.",
    "Cross-helper exclusion covers cooperating new runtimes; it does not lock out the user or other automation."],
};

const preflight = new Session();
try { await preflight.initialize(); report.permissions = receipt(await preflight.tool("capabilities")).permissions; }
catch (error) { report.preflightError = error.stack; }
finally {
  try { await preflight.close(); }
  catch (error) { report.preflightError ||= error.stack; }
}

try {
  for (let repeat = 0; repeat < repetitions; repeat++) for (const caseId of cases) {
    const episode = { caseId, repeat, outcome: "unknown", goalSatisfied: null, verifiedDispatchedSteps: 0, unknownDeliverySteps: 0 };
    if (report.preflightError || !report.permissions?.accessibility) { episode.outcome = "setup_blocked"; episode.error = report.preflightError || "Accessibility permission required"; episodes.push(episode); continue; }
    let fixture; const sessions = []; let measuring = false, caseStarted;
    const call = async (session, name, args = {}) => {
      const started = performance.now(); const response = await session.tool(name, args);
      const elapsedMs = performance.now() - started;
      if (measuring && resultKind(response) === "act") {
        for (const step of receipt(response).steps) {
          if (step.delivery === "dispatched" && step.verification === "confirmed") episode.verifiedDispatchedSteps++;
          if (step.delivery === "unknown") episode.unknownDeliverySteps++;
        }
      }
      trace.push({ event: "tool_call", caseId, repeat, phase: measuring ? "case" : "setup", name, args, response: native(response) || response.error, elapsedMs });
      episode.toolCalls = (episode.toolCalls || 0) + 1;
      episode.responseBytes = (episode.responseBytes || 0) + Buffer.byteLength(JSON.stringify(native(response) || response.error));
      if (!measuring) {
        episode.setupToolCalls = (episode.setupToolCalls || 0) + 1;
        episode.setupResponseBytes = (episode.setupResponseBytes || 0) + Buffer.byteLength(JSON.stringify(native(response) || response.error));
      }
      return response;
    };
    const connect = async () => { const s = new Session(); sessions.push(s); await s.initialize(); return s; };
    try {
      const session = await connect();
      fixture = new Fixture((entry) => trace.push({ ...entry, caseId, repeat }));
      let state = await fixture.ready;
      episode.fixtureNonce = state.runNonce;
      assert.equal(state.activationCount, 0); assert.notEqual(state.foregroundPID, state.pid);
      assert.equal(state.foregroundPID, state.startedForegroundPID);
      const setupStarted = performance.now();
      await until(async () => {
        const r = await call(session, "targets", { bundleId: "com.johnoba.cua.fixture" });
        return resultKind(r) === "targets" && receipt(r).targets.filter((t) => t.key.pid === state.pid).length === 2;
      });
      episode.registrationMs = performance.now() - setupStarted;
      const semanticStarted = performance.now();
      await until(async () => {
        const r = await call(session, "observe", { target: targetOf(state), budgetMs: 1000 });
        return resultKind(r) === "observe" && receipt(r).elements.some((e) => e.identifier === "primary.first");
      });
      episode.semanticReadinessMs = performance.now() - semanticStarted;
      if (["ignored-set", "delayed-set", "wait-delayed", "cross-helper-contention", "lock-owner-death"].includes(caseId)) {
        state = await fixture.call("configure", { control: "first", mode: caseId === "ignored-set" ? "ignored" : "delayed", delayMs: caseId === "lock-owner-death" ? 1500 : 200 });
      }
      if (caseId.startsWith("type-")) state = await fixture.call("configure", { control: "first", value: "A🙂e\u0301Z", selection: { location: 1, length: 2 } });
      if (["ambiguous-windows", "same-title-siblings"].includes(caseId)) {
        await fixture.call("configure", { window: "primary", title: "CUA Fixture Duplicate" });
        state = await fixture.call("configure", { window: "secondary", title: "CUA Fixture Duplicate",
          ...(caseId === "ambiguous-windows" ? { frame: windowOf(state).frame } : {}) });
        await until(async () => {
          const r = await call(session, "targets", { bundleId: "com.johnoba.cua.fixture" });
          const targets = receipt(r)?.targets?.filter((t) => t.key.pid === state.pid) || [];
          return targets.length === 2 && targets.every((t) => t.title === "CUA Fixture Duplicate") &&
            (caseId !== "ambiguous-windows" || JSON.stringify(targets[0].bounds) === JSON.stringify(targets[1].bounds));
        });
      }
      const before = state, target = targetOf(state), started = performance.now();
      caseStarted = started;
      episode.oracle = { before };
      measuring = true;
      const observeResponse = await call(session, "observe", { target, includeValues: caseId === "type-selection", budgetMs: 3000 });
      if (caseId === "ambiguous-windows") {
        assert.equal(resultKind(observeResponse), "error"); assert.equal(receipt(observeResponse).code, "ambiguousTarget");
        const after = await fixture.call("state"); stableValues(before, after);
        assert.equal(after.foregroundPID, before.foregroundPID); assert.equal(after.activationCount, before.activationCount);
        episode.foregroundPreserved = true;
        episode.outcome = "passed"; episode.elapsedMs = performance.now() - started; episode.oracle = { before, after }; continue;
      }
      assert.equal(resultKind(observeResponse), "observe", JSON.stringify(native(observeResponse)));
      const observation = receipt(observeResponse);
      assert.ok(["complete", "partial"].includes(observation.accessibility));
      assert.ok(observation.elements.length <= 256);
      const element = observation.elements.find((e) => e.identifier === "primary.first");
      assert.ok(element, "Primary control missing");
      assert.equal(new Set(observation.elements.map((e) => e.reference)).size, observation.elements.length);
      if (caseId !== "type-selection") assert.ok(observation.elements.every((e) => e.value === null));
      const set = (value, options = {}) => ({ observationId: observation.observationId, target, budgetMs: 1000,
        steps: [{ actionId: "edit", operation: { kind: "setValue", params: { elementRef: element.reference, value } } }], ...options });
      const value = `fixture-${repeat}-requested`;
      let response, after, expectedValue = value;
      if (caseId === "private-observation") {
        assert.equal(element.label, "Value"); assert.ok(observation.elements.filter((e) => e.label === "Value").length >= 2);
        after = await fixture.call("state"); stableValues(before, after);
      } else if (["recreated", "reopened", "reorder"].includes(caseId)) {
        const operation = { recreated: "recreate", reopened: "close_reopen", reorder: "reorder" }[caseId];
        const changed = await fixture.call(operation, { control: "first" });
        response = await call(session, "act", set(value)); after = await fixture.call("state");
        if (caseId === "reorder") { assert.equal(stepOf(response)?.verification, "confirmed"); assert.equal(fieldOf(after).modelValue, value); episode.goalSatisfied = true; stableValues(changed, after, ["primary.first"]); }
        else {
          expectRefusal(response); stableValues(changed, after);
          episode.refusalReceipt = native(response);
          trace.push({ event: "refusal_oracle", caseId, repeat, before: changed, after });
          const freshTarget = targetOf(changed);
          const fresh = await until(async () => {
            const r = await call(session, "observe", { target: freshTarget, budgetMs: 1000 });
            return resultKind(r) === "observe" && receipt(r).elements.some((e) => e.identifier === "primary.first") ? receipt(r) : false;
          });
          const replacement = fresh.elements.find((e) => e.identifier === "primary.first");
          assert.notEqual(replacement.reference, element.reference);
          const renewed = await call(session, "act", { observationId: fresh.observationId, target: freshTarget, budgetMs: 1000,
            steps: [{ actionId: "fresh-edit", operation: { kind: "setValue", params: { elementRef: replacement.reference, value } } }] });
          assert.equal(stepOf(renewed)?.verification, "confirmed");
          episode.freshReferenceReceipt = native(renewed); after = await fixture.call("state");
          assert.equal(fieldOf(after).modelValue, value); assert.equal(fieldOf(after).attempts, 1);
          stableValues(changed, after, ["primary.first"]);
        }
      } else if (caseId === "wrong-window") {
        response = await call(session, "act", set(value, { target: targetOf(state, "secondary") })); after = await fixture.call("state"); expectRefusal(response); stableValues(before, after);
      } else if (caseId === "different-session") {
        const other = await connect(); response = await call(other, "act", set(value)); after = await fixture.call("state"); expectRefusal(response); stableValues(before, after);
      } else if (caseId === "disabled") {
        const changed = await fixture.call("configure", { control: "first", enabled: false });
        response = await call(session, "act", set(value)); after = await fixture.call("state"); expectRefusal(response); stableValues(changed, after);
      } else if (caseId === "press") {
        const button = observation.elements.find((e) => e.identifier === "primary.press"); assert.ok(button?.actions.includes("press"));
        response = await call(session, "act", { observationId: observation.observationId, target, budgetMs: 1000,
          steps: [{ actionId: "press", operation: { kind: "press", params: { elementRef: button.reference } } }] });
        after = await fixture.call("state"); assert.equal(stepOf(response)?.delivery, "dispatched"); assert.equal(stepOf(response)?.route, "axPress");
        assert.equal(windowOf(after).pressCount, windowOf(before).pressCount + 1); episode.goalSatisfied = true;
        stableValues(before, { ...after, windows: after.windows.map((w) => w.key === "primary" ? { ...w, pressCount: windowOf(before).pressCount } : w) });
      } else if (caseId.startsWith("type-")) {
        assert.ok(element.actions.includes("typeText")); expectedValue = "AXYe\u0301Z";
        response = await call(session, "act", { observationId: observation.observationId, target, budgetMs: 1000,
          steps: [{ actionId: "type", operation: { kind: "typeText", params: { elementRef: element.reference, text: "XY" } } }] });
        after = await fixture.call("state"); assert.equal(fieldOf(after).modelValue, expectedValue); assert.equal(fieldOf(after).controlValue, expectedValue);
        assert.equal(stepOf(response)?.delivery, "dispatched"); assert.equal(stepOf(response)?.route, "axSelectedText");
        assert.equal(stepOf(response)?.verification, caseId === "type-private" ? "unverified" : "confirmed");
        if (caseId === "type-private") assert.deepEqual(stepOf(response).evidence, []);
        episode.goalSatisfied = true; stableValues(before, after, ["primary.first"]);
      } else if (caseId === "wait-already-satisfied") {
        response = await call(session, "waitFor", { observationId: observation.observationId, target, budgetMs: 1000,
          condition: { kind: "valueEquals", params: { elementRef: element.reference, value: fieldOf(before).controlValue } } });
        assert.equal(receipt(response).outcome, "satisfied"); assert.equal(receipt(response).alreadySatisfied, true);
        assert.notEqual(receipt(response).observation.observationId, observation.observationId);
        assert.ok(receipt(response).observation.elements.every((e) => e.value === null)); after = await fixture.call("state"); stableValues(before, after);
      } else if (caseId === "wait-delayed") {
        const edit = await call(session, "act", set(value, { budgetMs: 80 }));
        assert.ok(["dispatched", "unknown"].includes(stepOf(edit)?.delivery));
        response = await call(session, "waitFor", { observationId: observation.observationId, target, budgetMs: 1000,
          condition: { kind: "valueEquals", params: { elementRef: element.reference, value } } });
        assert.equal(receipt(response).outcome, "satisfied"); after = await fixture.call("state"); assert.equal(fieldOf(after).modelValue, value);
        episode.goalSatisfied = true; stableValues(before, after, ["primary.first"]);
      } else if (["cross-helper-contention", "lock-owner-death"].includes(caseId)) {
        const other = await connect(); const secondObservation = receipt(await call(other, "observe", { target, budgetMs: 3000 }));
        const second = secondObservation.elements.find((e) => e.identifier === "primary.second"); assert.ok(second);
        const a = call(session, "act", set(value, { budgetMs: caseId === "lock-owner-death" ? 3000 : 1000 }));
        await until(async () => fieldOf(await fixture.call("state")).attempts === 1);
        if (caseId === "lock-owner-death") process.kill(session.helperPid, "SIGKILL");
        const b = await call(other, "act", { observationId: secondObservation.observationId, target, budgetMs: caseId === "lock-owner-death" ? 1000 : 60,
          steps: [{ actionId: "second", operation: { kind: "setValue", params: { elementRef: second.reference, value: "second-requested" } } }] });
        const firstResult = await a; after = await fixture.call("state");
        if (caseId === "cross-helper-contention") {
          assert.equal(stepOf(b)?.delivery, "not_dispatched"); assert.equal(fieldOf(after, "second").attempts, 0);
          assert.equal(stepOf(firstResult)?.verification, "confirmed"); assert.equal(fieldOf(after).modelValue, value);
        } else {
          assert.equal(stepOf(firstResult)?.delivery, "unknown"); assert.equal(stepOf(b)?.verification, "confirmed");
          assert.equal(fieldOf(after, "second").modelValue, "second-requested");
        }
        stableValues(before, after, ["primary.first", "primary.second"]); response = firstResult;
      } else {
        expectedValue = caseId === "already-satisfied" ? fieldOf(before).controlValue : value;
        response = await call(session, "act", set(expectedValue, { budgetMs: caseId === "ignored-set" ? 150 : 1000 }));
        after = await fixture.call("state"); const step = stepOf(response); assert.ok(step, JSON.stringify(native(response)));
        if (caseId === "ignored-set") {
          assert.equal(step.delivery, "dispatched"); assert.ok(["mismatch", "unverified"].includes(step.verification));
          assert.notEqual(receipt(response).stopReason, "completed"); assert.equal(fieldOf(after).modelValue, fieldOf(before).modelValue); episode.goalSatisfied = false;
        } else {
          assert.equal(step.verification, "confirmed"); assert.equal(receipt(response).stopReason, "completed");
          assert.equal(fieldOf(after).modelValue, expectedValue); assert.equal(fieldOf(after).controlValue, expectedValue); episode.goalSatisfied = true;
          if (caseId === "already-satisfied") { assert.equal(step.delivery, "not_dispatched"); assert.equal(step.reason, "alreadySatisfied"); assert.equal(fieldOf(after).attempts, 0); }
          else { assert.equal(step.delivery, "dispatched"); assert.equal(step.route, "axSetValue"); }
        }
        stableValues(before, after, ["primary.first"]);
      }
      assert.equal(after.foregroundPID, before.foregroundPID, "Foreground endpoint changed (cause may be external)");
      assert.equal(after.activationCount, before.activationCount, "Fixture became active");
      episode.foregroundPreserved = true; episode.elapsedMs = performance.now() - started;
      episode.receipt = response ? native(response) : null; episode.oracle = { before, after }; episode.outcome = "passed";
    } catch (error) {
      episode.outcome = measuring ? "failed" : "setup_blocked"; episode.error = error.stack;
      if (fixture && episode.oracle) {
        try { episode.oracle.after = await fixture.call("state"); }
        catch (oracleError) { episode.oracleError = oracleError.message; }
      }
    }
    finally {
      if (caseStarted !== undefined) episode.elapsedMs ??= performance.now() - caseStarted;
      for (const session of sessions) { try { await session.close(); } catch (error) { episode.cleanupError = error.message; process.exitCode = 1; } }
      if (fixture) { try { await fixture.close(); } catch (error) { episode.cleanupError = error.message; process.exitCode = 1; } }
      episodes.push(episode); console.log(JSON.stringify({ caseId, repeat, outcome: episode.outcome, error: episode.error?.split("\n")[0] }));
    }
  }
} finally {
  report.finishedAt = new Date().toISOString();
  report.summary = { assigned: episodes.length, passed: episodes.filter((e) => e.outcome === "passed").length,
    failed: episodes.filter((e) => e.outcome === "failed").length, setupBlocked: episodes.filter((e) => e.outcome === "setup_blocked").length,
    verifiedDispatchedSteps: episodes.reduce((n, e) => n + e.verifiedDispatchedSteps, 0),
    unknownDeliverySteps: episodes.reduce((n, e) => n + e.unknownDeliverySteps, 0),
    latencyMs: distribution(episodes.map((e) => e.elapsedMs)), responseBytes: distribution(episodes.filter((e) => e.elapsedMs !== undefined).map((e) => (e.responseBytes || 0) - (e.setupResponseBytes || 0))),
    cleanupErrors: episodes.filter((e) => e.cleanupError).length };
  await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
  await fs.writeFile(path.join(output, "trace.jsonl"), trace.map((e) => JSON.stringify(e)).join("\n") + "\n");
  console.log(JSON.stringify({ report: path.join(output, "report.json"), summary: report.summary }, null, 2));
  if (report.summary.failed) process.exitCode = 1;
  if (report.summary.setupBlocked) process.exitCode = 2;
}
