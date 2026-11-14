// Native conformance and causal fault gates. Mutations are confined to the disposable fixture.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { performance } from "node:perf_hooks";
import { Session, root, alive, deadline } from "./mcp-session.mjs";
import { Fixture } from "../fixtures/macos/client.mjs";
import { distribution } from "../baseline/metrics.mjs";

const { values } = parseArgs({
  options: {
    repetitions: { type: "string", default: "3" },
    output: { type: "string" },
  },
});
const repetitions = Number(values.repetitions);
assert.ok(Number.isInteger(repetitions) && repetitions > 0 && repetitions <= 5);
const output = path.resolve(
  values.output ||
    path.join(
      root,
      ".artifacts/composition-live",
      new Date().toISOString().replaceAll(":", "-"),
    ),
);
await fs.mkdir(output, { recursive: true });
const trace = [],
  episodes = [];
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(probe, ms = 3000) {
  const end = performance.now() + ms;
  while (performance.now() < end) {
    const v = await probe();
    if (v) return v;
    await pause(10);
  }
  throw new Error("Bounded causal gate/oracle did not become ready");
}
const win = (s, key = "primary") => s.windows.find((w) => w.key === key);
const field = (s, key = "first") => win(s).controls.find((c) => c.key === key);
const target = (s) => ({ pid: s.pid, windowId: win(s).windowId });
const native = (r) => r.result?.structuredContent;
const body = (r) => native(r)?.body;
const data = (r) => body(r)?.data;
const cases = [
  "mixed-sequence",
  "stop-on-failure",
  "wait-timeout-unsent",
  "element-absence",
  "enabled-privacy-feedback",
  "presence-waits",
  "window-absence-hidden",
  "window-absence-reopened",
  "already-feedback",
  "death-before-dispatch",
  "death-during-effect",
  "death-after-effect-prefix",
];
const git = (...a) =>
  execFileSync("git", a, { cwd: root, encoding: "utf8" }).trim();
const hash = async (f) =>
  createHash("sha256")
    .update(await fs.readFile(f))
    .digest("hex");
const report = {
  schemaVersion: 1,
  startedAt: new Date().toISOString(),
  source: {
    revision: git("rev-parse", "HEAD"),
    dirty: Boolean(git("status", "--porcelain")),
    hostSha256: await hash(
      path.join(root, ".artifacts/runtime-install/cua-host"),
    ),
    helperSha256: await hash(
      path.join(root, ".artifacts/runtime-install/cua-runtime"),
    ),
    fixtureSha256: await hash(
      path.join(
        root,
        "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture",
      ),
    ),
  },
  repetitions,
  cases,
  episodes,
  model: { runs: false, tokens: null, costUsd: null },
  notes: [
    "Scripted native conformance, not autonomous task reliability.",
    "Setup CG/AX readiness is separate from measured cases. Exact window absence includes offscreen rows.",
    "Kill phases use lock/request/fixture-effect/final-frame gates, not sleeps. Relays add no input or retries.",
    "Foreground endpoint samples and activation counts do not exclude transient/external changes.",
  ],
};
let preflight = new Session();
try {
  await preflight.initialize();
  report.permissions = data(await preflight.tool("capabilities")).permissions;
} finally {
  await preflight.close();
}
for (let repeat = 0; repeat < repetitions; repeat++)
  for (const caseId of cases) {
    const episode = { caseId, repeat, outcome: "setup_blocked" };
    episodes.push(episode);
    let fixture,
      blocker,
      blockerExit,
      measuring = false,
      start;
    const sessions = [],
      appliedEvents = [];
    const call = async (s, name, args) => {
      const began = performance.now();
      const r = await s.tool(name, args);
      trace.push({
        event: "tool",
        caseId,
        repeat,
        phase: measuring ? "case" : "setup",
        name,
        args,
        response: native(r) || r.error,
        elapsedMs: performance.now() - began,
      });
      return r;
    };
    const connect = async (args = []) => {
      const s = new Session(args);
      sessions.push(s);
      await s.initialize();
      return s;
    };
    const markerPrefix = path.join(
      output,
      `${repeat}-${caseId}-${randomUUID()}`,
    );
    try {
      if (!report.permissions.accessibility)
        throw new Error("Accessibility permission unavailable");
      let relayArgs = [];
      if (caseId.startsWith("death-")) {
        const wrapper = markerPrefix + ".relay";
        const program = path.join(
          root,
          ".artifacts/runtime-install/cua-runtime",
        );
        const relay = path.join(root, "test/runtime/support/native-relay.py");
        await fs.writeFile(
          wrapper,
          `#!/usr/bin/env python3\nimport os\nos.execvp('python3', ['python3', ${JSON.stringify(relay)}, ${JSON.stringify(program)}, ${JSON.stringify(caseId === "death-after-effect-prefix" ? "hold-act-final" : "passthrough")}, ${JSON.stringify(markerPrefix)}])\n`,
          { mode: 0o755 },
        );
        relayArgs = ["--helper", wrapper];
      }
      const session = await connect(relayArgs);
      fixture = new Fixture((e) => {
        trace.push({ ...e, caseId, repeat });
        if (e.event === "fixture_write_applied") appliedEvents.push(e);
      });
      let state = await fixture.ready;
      assert.equal(state.activationCount, 0);
      assert.notEqual(state.foregroundPID, state.pid);
      await until(async () => {
        const r = await call(session, "observe", {
          target: target(state),
          includeValues: true,
          budgetMs: 1000,
        });
        return (
          body(r)?.result === "observe" &&
          data(r).elements.some((e) => e.identifier === "primary.first")
        );
      });
      if (caseId === "element-absence")
        state = await fixture.call("configure", {
          pressEffect: "removeSecond",
        });
      if (caseId === "enabled-privacy-feedback")
        state = await fixture.call("configure", {
          pressEffect: "disableSecond",
        });
      if (caseId === "death-during-effect")
        state = await fixture.call("configure", {
          control: "first",
          mode: "delayed",
          delayMs: 500,
        });
      if (caseId === "death-after-effect-prefix")
        state = await fixture.call("configure", {
          control: "second",
          pauseAfterApplyMs: 500,
        });
      const before = state;
      episode.oracle = { before };
      start = performance.now();
      measuring = true;
      const observationResponse = await call(session, "observe", {
        target: target(state),
        includeValues: caseId !== "enabled-privacy-feedback",
        budgetMs: 3000,
      });
      const o = data(observationResponse);
      episode.epoch = native(observationResponse)?.epoch;
      assert.ok(o?.elements, "Graded observation unavailable");
      episode.observationId = o.observationId;
      const ref = (id) => {
        const e = o.elements.find((e) => e.identifier === id);
        assert.ok(e, `Missing ${id}`);
        return e.reference;
      };
      const first = ref("primary.first"),
        second = ref("primary.second"),
        button = ref("primary.press");
      const exact = (elementRef, value) => ({
        kind: "valueEquals",
        params: { elementRef, value },
      });
      const step = (actionId, kind, params, extra = {}) => ({
        actionId,
        operation: { kind, params },
        ...extra,
      });
      const set = (id, r, v, extra = {}) =>
        step(id, "setValue", { elementRef: r, value: v }, extra);
      const wait = (id, condition) => step(id, "waitFor", { condition });
      const x = `composed-${repeat}-first`,
        y = `composed-${repeat}-second`;
      const act = (steps, budgetMs = 3000, feedback) =>
        call(session, "act", {
          observationId: o.observationId,
          target: target(state),
          steps,
          budgetMs,
          ...(feedback ? { feedback } : {}),
        });
      let response;
      if (caseId === "mixed-sequence") {
        response = await act(
          [
            set("first", first, x),
            wait("wait-first", exact(first, x)),
            set("second", second, y),
            wait("wait-second", exact(second, y)),
          ],
          3000,
          { elementRefs: [first, second], includeValues: true },
        );
        assert.equal(data(response).stopReason, "completed");
        assert.deepEqual(
          data(response).steps.map((s) => s.delivery),
          ["dispatched", "not_dispatched", "dispatched", "not_dispatched"],
        );
        assert.ok(
          data(response).steps.every((s) => s.verification === "confirmed"),
        );
        assert.deepEqual(
          data(response).feedback.controls.map((c) => c.state),
          ["changed", "changed"],
        );
      } else if (caseId === "stop-on-failure") {
        response = await act([
          set("first", first, x),
          step("unsupported", "press", { elementRef: first }),
          set("unsent", second, y),
        ]);
        assert.equal(data(response).steps[0].verification, "confirmed");
        assert.equal(data(response).steps[1].delivery, "not_dispatched");
        assert.equal(data(response).remainingSteps, 1);
        assert.equal(data(response).stopReason, "unsupported");
      } else if (caseId === "wait-timeout-unsent") {
        response = await act(
          [
            set("first", first, x),
            wait("wait", exact(second, "never")),
            set("unsent", second, y),
          ],
          500,
        );
        assert.equal(data(response).steps[0].verification, "confirmed");
        assert.equal(data(response).steps[1].delivery, "not_dispatched");
        assert.equal(data(response).remainingSteps, 1);
        assert.equal(data(response).stopReason, "deadlineExceeded");
      } else if (
        caseId === "element-absence" ||
        caseId === "enabled-privacy-feedback"
      ) {
        const condition =
          caseId === "element-absence"
            ? {
                kind: "elementAbsent",
                params: {
                  selector: {
                    role: "AXTextField",
                    identifier: "primary.second",
                  },
                },
              }
            : {
                kind: "enabled",
                params: { elementRef: second, enabled: false },
              };
        response = await act(
          [
            step("press", "press", { elementRef: button }),
            wait("wait", condition),
            set("first", first, x, { precondition: condition }),
          ],
          3000,
          {
            elementRefs: [first, second],
            includeValues: caseId === "element-absence",
          },
        );
        assert.equal(data(response).stopReason, "completed");
        assert.equal(data(response).steps[1].delivery, "not_dispatched");
        assert.equal(data(response).steps[1].verification, "confirmed");
        assert.equal(data(response).feedback.invalidated, false);
        if (caseId === "element-absence")
          assert.equal(
            data(response).feedback.controls[1].state,
            "invalidated",
          );
        else {
          assert.deepEqual(
            data(response).feedback.controls.map((c) => c.state),
            ["unchanged", "changed"],
          );
          assert.equal(data(response).feedback.controls[1].element.value, null);
        }
      } else if (caseId === "presence-waits") {
        for (const [kind, identifier] of [
          ["elementExists", "primary.second"],
          ["elementAbsent", "never-created"],
        ]) {
          response = await call(session, "waitFor", {
            observationId: o.observationId,
            target: target(state),
            condition: {
              kind,
              params: { selector: { role: "AXTextField", identifier } },
            },
            budgetMs: 1000,
          });
          assert.equal(data(response).outcome, "satisfied");
          assert.notEqual(
            data(response).observation.observationId,
            o.observationId,
          );
          assert.ok(data(response).evidence.collected);
        }
      } else if (caseId.startsWith("window-absence-")) {
        if (caseId === "window-absence-hidden")
          await fixture.call("hide_window");
        const waiting = call(session, "waitFor", {
          observationId: o.observationId,
          target: target(state),
          condition: { kind: "windowAbsent", params: {} },
          budgetMs: caseId === "window-absence-hidden" ? 150 : 2000,
        });
        if (caseId === "window-absence-reopened")
          await fixture.call("close_reopen");
        response = await waiting;
        if (caseId === "window-absence-hidden")
          assert.equal(data(response).outcome, "timedOut");
        else {
          assert.equal(data(response).outcome, "satisfied");
          assert.equal(data(response).observation, null);
          assert.equal(data(response).evidence.condition.kind, "windowAbsent");
          assert.ok(data(response).evidence.collected);
        }
      } else if (caseId === "already-feedback") {
        response = await act(
          [set("existing", first, field(before).modelValue)],
          1000,
          { elementRefs: [first], includeValues: false },
        );
        assert.equal(data(response).steps[0].reason, "alreadySatisfied");
        assert.equal(data(response).steps[0].delivery, "not_dispatched");
        assert.equal(data(response).feedback.controls[0].state, "unchanged");
      } else {
        if (caseId === "death-before-dispatch") {
          blocker = spawn(
            "python3",
            [
              "-u",
              "-c",
              "import os,pwd,fcntl,sys; p=os.path.join(pwd.getpwuid(os.geteuid()).pw_dir,'Library/Caches/macos-computer-use'); os.makedirs(p,mode=0o700,exist_ok=True); f=open(os.path.join(p,'mutation.lock'),'a'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.read()",
            ],
            { stdio: ["pipe", "pipe", "pipe"] },
          );
          blockerExit = once(blocker, "exit");
          await deadline(once(blocker.stdout, "data"));
        }
        const steps =
          caseId === "death-after-effect-prefix"
            ? [
                set("first", first, x),
                wait("wait", exact(first, x)),
                set("second", second, y),
              ]
            : [set("first", first, x)];
        const ready = JSON.parse(
          await fs.readFile(markerPrefix + ".ready.json", "utf8"),
        );
        const pending = act(steps);
        // The phase gate may fail first; cleanup must not leave an unhandled pending call.
        void pending.catch(() => {});
        const forwarded = await until(async () => {
          try {
            return JSON.parse(
              await fs.readFile(markerPrefix + ".request.json", "utf8"),
            );
          } catch {
            return false;
          }
        });
        if (caseId === "death-during-effect")
          await until(async () => {
            const f = field(await fixture.call("state"));
            return f.attempts === 1 && f.appliedWrites === 0;
          });
        episode.forwardedRequest = forwarded.request;
        assert.equal(forwarded.request.message.epoch, episode.epoch);
        assert.equal(forwarded.request.message.body.method, "act");
        assert.equal(
          forwarded.request.message.body.params.observationId,
          o.observationId,
        );
        assert.deepEqual(
          forwarded.request.message.body.params.target,
          target(state),
        );
        assert.deepEqual(
          forwarded.request.message.body.params.steps.map((s) => s.actionId),
          steps.map((s) => s.actionId),
        );
        if (caseId === "death-after-effect-prefix") {
          episode.appliedEvent = await until(() =>
            appliedEvents.find(
              (e) =>
                e.identifier === "primary.second" &&
                field(e.state, "second").appliedWrites === 1,
            ),
          );
          assert.equal(
            field(episode.appliedEvent.state, "second").modelValue,
            y,
          );
          let responseAlreadyProduced = false;
          try {
            await fs.access(markerPrefix + ".response.json");
            responseAlreadyProduced = true;
          } catch (error) {
            if (error.code !== "ENOENT") throw error;
          }
          assert.equal(
            responseAlreadyProduced,
            false,
            "Native reply was produced before the after-effect crash gate",
          );
        }
        episode.nativeChildPid = ready.childPid;
        assert.equal(alive(ready.childPid), true);
        process.kill(ready.childPid, "SIGKILL");
        response = await pending;
        assert.equal(body(response)?.result, "act");
        assert.equal(data(response).stopReason, "helperDied");
        if (caseId === "death-after-effect-prefix") {
          assert.deepEqual(
            data(response).steps.map((s) => s.delivery),
            ["dispatched", "not_dispatched", "unknown"],
          );
          assert.ok(
            data(response)
              .steps.slice(0, 2)
              .every((s) => s.verification === "confirmed"),
          );
        } else assert.equal(data(response).steps[0].delivery, "unknown");
        if (caseId === "death-during-effect")
          await until(
            async () => field(await fixture.call("state")).appliedWrites === 1,
          );
        await until(() => !alive(ready.childPid));
      }
      episode.receipt = native(response);
      const after = await fixture.call("state");
      episode.oracle.after = after;
      for (const w of before.windows)
        for (const f of w.controls) {
          const current = win(after, w.key).controls.find(
            (c) => c.key === f.key,
          );
          const allowed =
            w.key === "primary" &&
            ((f.key === "first" &&
              [
                "mixed-sequence",
                "stop-on-failure",
                "wait-timeout-unsent",
                "element-absence",
                "enabled-privacy-feedback",
                "death-during-effect",
                "death-after-effect-prefix",
              ].includes(caseId)) ||
              (f.key === "second" &&
                ["mixed-sequence", "death-after-effect-prefix"].includes(
                  caseId,
                )));
          assert.equal(
            current.modelValue,
            allowed ? (f.key === "first" ? x : y) : f.modelValue,
          );
          assert.equal(current.controlValue, current.modelValue);
          assert.equal(current.attempts, allowed ? 1 : f.attempts);
          assert.equal(
            current.enabled,
            caseId === "enabled-privacy-feedback" &&
              w.key === "primary" &&
              f.key === "second"
              ? false
              : f.enabled,
          );
          assert.equal(
            current.attached,
            caseId === "element-absence" &&
              w.key === "primary" &&
              f.key === "second"
              ? false
              : f.attached,
          );
        }
      for (const w of before.windows)
        assert.equal(
          win(after, w.key).pressCount,
          w.pressCount +
            (w.key === "primary" &&
            ["element-absence", "enabled-privacy-feedback"].includes(caseId)
              ? 1
              : 0),
        );
      if (caseId === "element-absence")
        assert.equal(field(after, "second").attached, false);
      if (caseId === "enabled-privacy-feedback")
        assert.equal(field(after, "second").enabled, false);
      assert.equal(after.foregroundPID, before.foregroundPID);
      assert.equal(after.activationCount, before.activationCount);
      episode.foregroundPreserved = true;
      episode.outcome = "passed";
    } catch (error) {
      episode.outcome = measuring ? "failed" : "setup_blocked";
      episode.error = error.stack;
      if (fixture && episode.oracle) {
        try {
          episode.oracle.after = await fixture.call("state");
        } catch {}
      }
    } finally {
      if (start !== undefined) episode.elapsedMs = performance.now() - start;
      if (blocker) {
        try {
          blocker.stdin.end();
          try {
            await deadline(blockerExit, 500);
          } catch {
            blocker.kill("SIGKILL");
            await deadline(blockerExit, 1500);
          }
        } catch (error) {
          episode.cleanupError = error.message;
        }
      }
      for (const s of sessions) {
        try {
          await s.close();
        } catch (e) {
          episode.cleanupError = e.message;
        }
      }
      if (fixture) {
        try {
          await fixture.close();
        } catch (e) {
          episode.cleanupError = e.message;
        }
      }
      console.log(
        JSON.stringify({
          caseId,
          repeat,
          outcome: episode.outcome,
          error: episode.error?.split("\n")[0],
        }),
      );
    }
  }
report.finishedAt = new Date().toISOString();
report.summary = {
  assigned: episodes.length,
  passed: episodes.filter((e) => e.outcome === "passed").length,
  failed: episodes.filter((e) => e.outcome === "failed").length,
  setupBlocked: episodes.filter((e) => e.outcome === "setup_blocked").length,
  cleanupErrors: episodes.filter((e) => e.cleanupError).length,
  latencyMs: distribution(episodes.map((e) => e.elapsedMs)),
};
await fs.writeFile(
  path.join(output, "report.json"),
  JSON.stringify(report, null, 2) + "\n",
);
await fs.writeFile(
  path.join(output, "trace.jsonl"),
  trace.map((e) => JSON.stringify(e)).join("\n") + "\n",
);
console.log(
  JSON.stringify(
    { report: path.join(output, "report.json"), summary: report.summary },
    null,
    2,
  ),
);
if (report.summary.failed || report.summary.cleanupErrors) process.exitCode = 1;
else if (report.summary.setupBlocked) process.exitCode = 2;
