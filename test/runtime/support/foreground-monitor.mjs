import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const foregroundMonitorSource = path.join(root, "test/runtime/support/foreground-monitor.swift");
export async function buildForegroundMonitor() {
  const binary = path.join(root, ".artifacts/foreground-monitor");
  await fs.mkdir(path.dirname(binary), { recursive: true });
  execFileSync("xcrun", ["swiftc", "-O", "-swift-version", "6", "-framework", "AppKit", foregroundMonitorSource, "-o", binary], { timeout: 60000 });
  return binary;
}

export class ForegroundMonitor {
  constructor(binary) {
    this.child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.exit = once(this.child, "exit");
    this.exit.catch(() => {}); // Spawn failure may precede the caller's cleanup await.
    this.pending = new Map();
    this.failure = null;
    this.ready = new Promise((resolve, reject) => { this.resolveReady = resolve; this.rejectReady = reject; });
    this.ready.catch(() => {}); // Preserve a startup rejection until the caller awaits its first request.
    this.reader = createInterface({ input: this.child.stdout });
    this.readyTimer = setTimeout(() => this.fail(new Error("Foreground monitor did not become ready")), 5000);
    this.reader.on("line", (line) => {
      let message;
      try { message = JSON.parse(line); } catch { this.fail(new Error("Invalid foreground monitor output")); return; }
      if (message.event === "ready") { clearTimeout(this.readyTimer); this.resolveReady(); return; }
      const pending = this.pending.get(message.id);
      if (!pending) { this.fail(new Error("Uncorrelated foreground monitor reply")); return; }
      clearTimeout(pending.timer); this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error)); else pending.resolve(message.state);
    });
    this.child.stderr.resume();
    this.child.stdin.on("error", (error) => this.fail(error));
    this.child.on("error", (error) => this.fail(error));
    this.child.on("exit", () => this.fail(new Error("Foreground monitor exited")));
  }
  fail(error) {
    this.failure ??= error;
    clearTimeout(this.readyTimer); this.rejectReady(error);
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  async request(command, targetPID) {
    await this.ready;
    if (this.failure) throw this.failure;
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error("Foreground monitor request exceeded budget")); }, 3000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, command, targetPID }) + "\n");
    });
  }
  begin(targetPID) { return this.request("begin", targetPID); }
  snapshot() { return this.request("snapshot"); }
  async close() {
    let finalState;
    try {
      if (this.child.exitCode !== null || this.child.signalCode !== null) throw new Error("Foreground monitor stopped before its final sample");
      finalState = await this.request("stop");
    }
    finally {
      this.child.stdin.end();
      let timer;
      try {
        const [code, signal] = await Promise.race([this.exit, new Promise((_, reject) => {
          timer = setTimeout(() => { this.child.kill("SIGKILL"); reject(new Error("Foreground monitor did not exit")); }, 3000);
        })]);
        if (code !== 0 || signal) throw new Error("Foreground monitor failed");
      } finally { clearTimeout(timer); this.reader.close(); }
    }
    return finalState;
  }
}
