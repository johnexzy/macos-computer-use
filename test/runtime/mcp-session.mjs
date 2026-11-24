import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const host = path.join(root, ".artifacts/runtime-install/useui");
export const deadline = async (promise, ms = 5000) => {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("process test deadline exceeded")), ms); })]); }
  finally { clearTimeout(timer); }
};
export const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { if (e.code === "ESRCH") return false; throw e; } };

export class Session {
  constructor(args = []) {
    // Verify the installed pair works outside the repository and SwiftPM build directory.
    this.child = spawn(host, args, { cwd: os.tmpdir(), stdio: ["pipe", "pipe", "pipe"] });
    this.exit = once(this.child, "exit");
    this.pending = new Map(); this.next = 0; this.diagnostics = "";
    this.ready = new Promise((resolve) => { this.resolveReady = resolve; });
    this.output = createInterface({ input: this.child.stdout });
    this.output.on("line", (line) => {
      const response = JSON.parse(line); // Any non-protocol stdout fails the test.
      const pending = this.pending.get(response.id);
      assert.ok(pending, `Unexpected or duplicate MCP response ${response.id}`);
      this.pending.delete(response.id); pending.resolve(response);
    });
    this.child.stderr.on("data", (bytes) => {
      this.diagnostics += bytes.toString();
      for (const line of this.diagnostics.split("\n")) {
        try { const event = JSON.parse(line); if (event.event === "runtime_started") { this.helperPid = event.helperPid; this.resolveReady(event); } }
        catch {} // Stderr may include compiler/framework diagnostics, never stdout.
      }
    });
    this.child.on("exit", () => {
      for (const pending of this.pending.values()) pending.reject(new Error("Host exited before response"));
      this.pending.clear();
    });
  }
  notify(method, params) { this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n"); }
  request(method, params, timeoutMs = 5000) {
    const id = ++this.next;
    return deadline(new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    }), timeoutMs);
  }
  async initialize() {
    await deadline(this.ready);
    const response = await this.request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "runtime-process-tests", version: "1" } });
    assert.equal(response.result.protocolVersion, "2025-11-25");
    this.notify("notifications/initialized");
    return response;
  }
  tool(name, args = {}) {
    const timeoutMs = Math.max(5000, (typeof args?.budgetMs === "number" ? args.budgetMs : 5000) + 2000);
    return this.request("tools/call", { name, arguments: args }, timeoutMs);
  }
  async close(signal) {
    if (this.child.exitCode === null && this.child.signalCode === null) {
      if (signal) this.child.kill(signal); else this.child.stdin.end();
    }
    const [code, receivedSignal] = await deadline(this.exit);
    assert.equal(receivedSignal, null);
    assert.equal(code, 0, this.diagnostics);
    if (this.helperPid) assert.equal(alive(this.helperPid), false, "Native helper was not reaped");
    this.output.close();
  }
}
