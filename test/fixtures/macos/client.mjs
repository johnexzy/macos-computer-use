import { spawn } from "node:child_process";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

export class Fixture {
  constructor(trace = () => {}) {
    const directory = path.dirname(fileURLToPath(import.meta.url));
    this.child = spawn(path.join(directory, ".build/CUAFixture.app/Contents/MacOS/CUAFixture"), [], { stdio: ["pipe", "pipe", "pipe"] });
    this.exited = once(this.child, "exit"); this.pending = new Map(); this.trace = trace;
    this.ready = new Promise((resolve, reject) => { this.resolveReady = resolve; this.rejectReady = reject; });
    this.timer = setTimeout(() => this.rejectReady(new Error("Fixture readiness exceeded 8s")), 8000);
    this.reader = createInterface({ input: this.child.stdout });
    this.reader.on("line", (line) => {
      const message = JSON.parse(line);
      if (message.event === "ready") { clearTimeout(this.timer); this.resolveReady(message.state); }
      else if (message.event === "write_applied") trace({ event: "fixture_write_applied", identifier: message.identifier, state: message.state });
      else {
        const pending = this.pending.get(message.id);
        if (pending) { this.pending.delete(message.id); clearTimeout(pending.timer); pending.resolve(message); }
      }
    });
    this.child.stderr.on("data", (data) => trace({ event: "fixture_diagnostic", text: data.toString() }));
    this.child.on("error", (error) => this.fail(error));
    this.child.on("exit", () => this.fail(new Error("Fixture exited")));
  }
  fail(error) {
    clearTimeout(this.timer); this.rejectReady(error);
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); }
    this.pending.clear();
  }
  async call(command, args = {}) {
    const request = { id: randomUUID(), command, ...args };
    const response = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(request.id); reject(new Error(`Fixture ${command} exceeded 5s`)); }, 5000);
      this.pending.set(request.id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify(request) + "\n");
    });
    this.trace({ event: "fixture_call", request, response });
    if (response.status !== "ok") throw new Error(response.error);
    return response.state;
  }
  async close() {
    try {
      if (this.child.exitCode === null && this.child.signalCode === null) await this.call("quit");
      const [code, signal] = await this.exited;
      if (code !== 0 || signal !== null) throw new Error("Fixture did not close cleanly");
    } finally {
      this.reader.close();
      if (this.child.exitCode === null && this.child.signalCode === null) this.child.kill();
    }
  }
}
