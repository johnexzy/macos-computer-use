import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { copyFile, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const userActiveSource = "test/workflow/support/user-active-actor.swift";

export async function buildUserActiveActors() {
  const binaries = [];
  for (const label of ["A", "B"]) {
    const contents = path.join(root, `.artifacts/workflow-actor-${label}.app/Contents`);
    await mkdir(path.join(contents, "MacOS"), { recursive: true });
    const binary = path.join(contents, "MacOS/WorkflowActor");
    if (!binaries.length) execFileSync("xcrun", ["swiftc", "-O", "-swift-version", "6", "-framework", "AppKit", path.join(root, userActiveSource), "-o", binary], { timeout: 60000 });
    else await copyFile(binaries[0], binary);
    await writeFile(path.join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.johnoba.cua.workflow-actor.${label.toLowerCase()}</string><key>CFBundleName</key><string>Workflow Actor ${label}</string><key>CFBundleExecutable</key><string>WorkflowActor</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSUIElement</key><true/></dict></plist>`);
    binaries.push(binary);
  }
  return binaries;
}

class ActorClient {
  constructor(binary, label, nonce) {
    this.child = spawn(binary, [label, nonce], { stdio: ["pipe", "pipe", "pipe"] });
    this.exit = once(this.child, "exit"); this.exit.catch(() => {});
    this.pending = new Map(); this.failure = null;
    this.ready = new Promise((resolve, reject) => { this.resolveReady = resolve; this.rejectReady = reject; });
    this.ready.catch(() => {});
    this.timer = setTimeout(() => this.fail(new Error("Activity actor readiness exceeded budget")), 3000);
    this.reader = createInterface({ input: this.child.stdout });
    this.reader.on("line", line => {
      let message;
      try { message = JSON.parse(line); } catch { this.fail(new Error("Invalid activity actor output")); return; }
      if (message.event === "ready") { clearTimeout(this.timer); this.resolveReady(message.state); return; }
      const pending = this.pending.get(message.id);
      if (!pending) { this.fail(new Error("Uncorrelated activity actor response")); return; }
      clearTimeout(pending.timer); this.pending.delete(message.id);
      if (message.status !== "ok") pending.reject(new Error(message.reason ?? "Activity actor failed"));
      else pending.resolve(message);
    });
    this.child.stderr.resume();
    this.child.stdin.on("error", error => this.fail(error));
    this.child.on("error", error => this.fail(error));
    this.child.on("exit", () => this.fail(new Error("Activity actor exited")));
  }
  fail(error) {
    this.failure ??= error; clearTimeout(this.timer); this.rejectReady(error);
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  async call(command, args) {
    await this.ready;
    if (this.failure) throw this.failure;
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error("Activity actor request exceeded budget")); }, 3000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, command, ...args }) + "\n");
    });
  }
  async close() {
    try {
      if (this.failure) throw this.failure;
      await this.call("quit");
    }
    finally {
      this.child.stdin.end();
      let timer;
      try {
        const outcome = await Promise.race([this.exit, new Promise(resolve => {
          timer = setTimeout(() => resolve(null), 2000);
        })]);
        if (outcome === null) {
          this.child.kill("SIGKILL");
          await Promise.race([this.exit, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error("Activity actor exit remains unknown")), 1000);
          })]);
          throw new Error("Activity actor required forced termination");
        }
        const [code, signal] = outcome;
        if (code !== 0 || signal) throw new Error("Activity actor failed to close");
      } finally { clearTimeout(timer); this.reader.close(); }
    }
  }
}

export class UserActiveActivity {
  constructor({ binaries, targetPID, milestones, snapshot, makeActor = (binary, label, nonce) => new ActorClient(binary, label, nonce) }) {
    this.nonce = randomUUID(); this.targetPID = targetPID; this.snapshot = snapshot;
    this.actors = binaries.map((binary, i) => makeActor(binary, ["A", "B"][i], this.nonce));
    this.evidence = { actorPIDs: [], targetPID, transitions: [], cleanupComplete: false,
      restorationGuard: "owned_foreground_at_check_non_atomic" };
    this.milestones = milestones; this.nextMilestone = 0; this.observedCounts = new Map();
  }
  async start() {
    const states = await Promise.all(this.actors.map(actor => actor.ready));
    const pids = states.map(s => s.pid);
    assert.equal(pids.length, 2); assert.equal(new Set(pids).size, 2);
    assert.ok(pids.every((pid, i) => Number.isSafeInteger(pid) && pid > 0 && pid !== this.targetPID &&
      this.actors[i].child.pid === pid && states[i].nonce === this.nonce && states[i].label === ["A", "B"][i]));
    const previous = states[0].previousForegroundPID;
    assert.ok(Number.isSafeInteger(previous) && previous > 0 && previous !== this.targetPID && !pids.includes(previous));
    assert.ok(states.every(s => s.previousIdentityKnown && s.previousForegroundPID === previous && s.foregroundPID === previous), "Foreground identity changed or unavailable during actor setup");
    this.evidence.actorPIDs = pids; this.evidence.previousForegroundPID = previous; this.foregroundPID = previous;
    await this.transition("task_start", 0);
  }
  async transition(checkpoint, index, signal) {
    signal?.throwIfAborted();
    const actorPID = this.evidence.actorPIDs[index];
    const previousActor = this.evidence.actorPIDs.indexOf(this.foregroundPID);
    if (previousActor !== -1) {
      await this.actors[previousActor].call("yield", { ownedPIDs: this.evidence.actorPIDs, nextActorPID: actorPID });
    }
    signal?.throwIfAborted();
    const response = await this.actors[index].call("activate", { ownedPIDs: this.evidence.actorPIDs, expectedForegroundPID: this.foregroundPID });
    assert.equal(response.state.pid, actorPID); assert.equal(response.state.foregroundPID, actorPID);
    const deadline = performance.now() + 1000;
    let monitor, event;
    do {
      monitor = await this.snapshot();
      assert.ok(monitor.available && !monitor.truncated && monitor.targetPID === this.targetPID && monitor.targetActivations === 0, "Activity monitor is unavailable or target activated");
      const count = monitor.events.filter(event => event.pid === actorPID).length;
      if (monitor.finishedForegroundPID === actorPID && count > (this.observedCounts.get(actorPID) ?? 0)) {
        event = monitor.events.filter(event => event.pid === actorPID).at(-1);
        this.observedCounts.set(actorPID, count); break;
      }
      assert.ok(performance.now() < deadline, "Actor activation was not independently observed");
      await sleep(10);
    } while (true);
    this.evidence.transitions.push({ checkpoint, beforePID: this.foregroundPID, actorPID,
      activationCount: response.state.activationCount, monitorKnown: true, observedUptimeNs: event.observedUptimeNs });
    this.foregroundPID = actorPID;
  }
  isMilestone(id) { return this.milestones.includes(id); }
  async afterMutation(ids) {
    const milestone = this.milestones[this.nextMilestone];
    if (!milestone || !ids.includes(milestone)) return;
    assert.equal(ids.at(-1), milestone, "A causal actor milestone must end its mutation batch");
    await this.advance();
  }
  async advance(signal) {
    const milestone = this.milestones[this.nextMilestone];
    assert.ok(milestone, "No planned actor switch remains");
    await this.transition(`after:${milestone}`, (this.nextMilestone + 1) % 2, signal);
    this.nextMilestone += 1;
  }
  async close() {
    let failure;
    try {
      if (this.evidence.actorPIDs.length === 2) {
        const current = (await this.snapshot()).finishedForegroundPID;
        const actor = this.evidence.actorPIDs.indexOf(current);
        this.evidence.restore = actor === -1 ? { restored: false, reason: "unowned_foreground_preserved" }
          : await this.actors[actor].call("restore", { ownedPIDs: this.evidence.actorPIDs });
      }
    } catch (error) { failure = error; }
    const results = await Promise.allSettled(this.actors.map(actor => actor.close()));
    this.evidence.cleanupComplete = results.every(result => result.status === "fulfilled");
    for (const result of results) if (result.status === "rejected") failure ??= result.reason;
    if (failure) throw failure;
  }
}

export const agentActivityOffsetsMs = [750, 2000];

export async function exerciseDuringAgent(activity, signal, offsets = agentActivityOffsetsMs) {
  const start = performance.now();
  for (const offset of offsets) {
    await sleep(Math.max(0, offset - (performance.now() - start)), undefined, { signal });
    await activity.advance(signal);
    // Only switches confirmed while the session is live count toward coverage.
    if (signal.aborted) activity.evidence.sessionEndedDuringSwitch = true;
    signal.throwIfAborted();
  }
}
