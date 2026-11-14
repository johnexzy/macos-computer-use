import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const host = path.join(root, ".artifacts/runtime-install/cua-host");
const deadline = async (promise, ms = 5000) => {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("process test deadline exceeded")), ms); })]); }
  finally { clearTimeout(timer); }
};
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { if (e.code === "ESRCH") return false; throw e; } };
async function fakeHelper(mode) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cua-mcp-test-"));
  const program = path.join(directory, "helper");
  const pidFile = path.join(directory, "pid");
  const handoffFile = path.join(directory, "act-started");
  const source = path.join(root, "crates/cua-client/tests/support/fake_helper.py");
  await fs.writeFile(program, `#!/usr/bin/env python3
import json, runpy, sys
source = ${JSON.stringify(source)}
sys.argv = [source, ${JSON.stringify(mode)}, ${JSON.stringify(pidFile)}]
original_stdin = sys.stdin
class ObservedInput:
    def __iter__(self):
        for line in original_stdin:
            if json.loads(line)["message"]["body"]["method"] == "act":
                with open(${JSON.stringify(handoffFile)}, "w") as marker:
                    marker.write("handed-to-helper")
            yield line
sys.stdin = ObservedInput()
runpy.run_path(source, run_name="__main__")
`, { mode: 0o755 });
  return { program, directory, async pid() {
    for (let i = 0; i < 100; i++) {
      try { return Number(await fs.readFile(pidFile, "utf8")); } catch (e) { if (e.code !== "ENOENT") throw e; }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error("Fake helper did not start");
  }, async actStarted() {
    for (let i = 0; i < 100; i++) {
      try { await fs.access(handoffFile); return; } catch (e) { if (e.code !== "ENOENT") throw e; }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error("Act was not handed to the fake helper");
  } };
}

class Session {
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
  request(method, params) {
    const id = ++this.next;
    return deadline(new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    }));
  }
  async initialize() {
    await deadline(this.ready);
    const response = await this.request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "runtime-process-tests", version: "1" } });
    assert.equal(response.result.protocolVersion, "2025-11-25");
    this.notify("notifications/initialized");
    return response;
  }
  tool(name, args = {}) { return this.request("tools/call", { name, arguments: args }); }
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

test("installed Rust MCP host keeps one native epoch and rejects model policy upgrades", { timeout: 15000 }, async () => {
  await fs.access(host);
  const session = new Session();
  try {
    await session.initialize();
    const listed = await session.request("tools/list", {});
    assert.deepEqual(listed.result.tools.map((t) => t.name).sort(), ["act", "capabilities", "observe", "targets", "waitFor"].sort());
    for (const tool of listed.result.tools) {
      assert.equal(tool.inputSchema.additionalProperties, false);
      for (const forbidden of ["grantId", "mode", "epoch", "authority"]) assert.equal(tool.inputSchema.properties[forbidden], undefined);
    }
    const results = await Promise.all(Array.from({ length: 8 }, () => session.tool("capabilities")));
    const responses = results.map((r) => r.result.structuredContent);
    assert.equal(new Set(responses.map((r) => r.id)).size, 8);
    assert.equal(new Set(responses.map((r) => r.epoch)).size, 1);
    assert.ok(responses.every((r) => r.body.data.mode === "backgroundRequired"));
    assert.ok(responses.every((r) => r.body.data.actions.length === 0));
    assert.ok(responses.every((r) => Object.values(r.body.data.permissions).every((v) => typeof v === "boolean")));
    const forged = await session.tool("capabilities", { mode: "foregroundAllowed" });
    assert.equal(forged.result.isError, true);
    assert.match(forged.result.content[0].text, /unknown field/);
    const sensitive = await session.tool("capabilities", { secret: "must-never-appear-in-diagnostics" });
    assert.equal(sensitive.result.isError, true);
    assert.equal(session.diagnostics.includes("must-never-appear-in-diagnostics"), false);
    const badBudget = await session.tool("capabilities", { budgetMs: 0 });
    assert.equal(badBudget.error.code, -32602);
    const following = await session.tool("capabilities");
    const sequence = (id) => Number(id.match(/\d+$/)[0]);
    assert.equal(sequence(following.result.structuredContent.id), Math.max(...responses.map((r) => sequence(r.id))) + 1,
      "Rejected model arguments reached the native connection");
    assert.equal(alive(session.helperPid), true);
  } finally { await session.close(); }
});

test("SIGINT with stdin open shuts down host and persistent helper", { timeout: 10000 }, async () => {
  const session = new Session();
  await session.initialize();
  await session.tool("capabilities");
  await session.close("SIGINT");
});

test("operator foreground grant is explicit and remains process configured", { timeout: 10000 }, async () => {
  const session = new Session(["--allow-foreground"]);
  try {
    await session.initialize();
    const response = await session.tool("capabilities");
    assert.equal(response.result.structuredContent.body.data.mode, "foregroundAllowed");
  } finally { await session.close(); }
});

test("helper death is surfaced without automatic restart", { timeout: 10000 }, async () => {
  const session = new Session();
  try {
    await session.initialize();
    process.kill(session.helperPid, "SIGKILL");
    const response = await session.tool("capabilities");
    assert.equal(response.result.isError, true);
    assert.ok(["helper_died", "closed"].includes(response.result.structuredContent.error.code));
    const again = await session.tool("capabilities");
    assert.equal(again.result.isError, true);
    assert.equal(alive(session.helperPid), false);
  } finally { await session.close(); }
});

test("modern MCP discovery and per-request metadata work without initialize", { timeout: 10000 }, async () => {
  const session = new Session();
  const meta = { "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": { name: "runtime-modern-tests", version: "1" } };
  try {
    await deadline(session.ready);
    const discovery = await session.request("server/discover", { _meta: meta });
    assert.ok(discovery.result.supportedVersions.includes("2026-07-28"));
    const response = await session.request("tools/call", { name: "capabilities", arguments: {}, _meta: meta });
    assert.equal(response.result.structuredContent.body.data.mode, "backgroundRequired");
  } finally { await session.close(); }
});

test("host admission rejects excess calls before native dispatch", { timeout: 10000 }, async () => {
  const helper = await fakeHelper("block_then_success");
  const session = new Session(["--helper", helper.program]);
  try {
    await session.initialize();
    const results = await Promise.all(Array.from({ length: 32 }, () => session.tool("capabilities")));
    const rejected = results.filter((r) => r.result.structuredContent?.error?.code === "resourceLimit");
    assert.ok(rejected.length >= 16);
    assert.ok(rejected.every((r) => r.result.structuredContent.delivery === "not_dispatched"));
  } finally { await session.close(); await fs.rm(helper.directory, { recursive: true }); }
});

test("MCP cancellation reconciles native progress before reusing the helper", { timeout: 10000 }, async () => {
  const helper = await fakeHelper("cooperative_cancel");
  const session = new Session(["--helper", helper.program]);
  try {
    await session.initialize();
    const before = await session.tool("capabilities");
    const id = ++session.next;
    session.pending.set(id, { resolve() { assert.fail("SDK returned a cancelled request response"); }, reject() {} });
    session.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: {
      name: "act", arguments: { observationId: "fake-observation", target: { pid: 42, windowId: 7 },
        steps: ["first", "second"].map((actionId) => ({ actionId,
          operation: { kind: "press", params: { elementRef: "fake-element" } } })) },
    } }) + "\n");
    await helper.actStarted();
    session.notify("notifications/cancelled", { requestId: id, reason: "test cancellation" });
    const following = await session.tool("capabilities");
    assert.equal(following.result.structuredContent.epoch, before.result.structuredContent.epoch);
    const trace = session.diagnostics.split("\n").flatMap((line) => { try { return [JSON.parse(line)]; } catch { return []; } })
      .find((event) => event.event === "tool_finished" && event.method === "act");
    assert.equal(trace.stopReason, "cancelled");
    assert.equal(trace.delivery, "not_dispatched");
    session.pending.delete(id);
  } finally { await session.close(); await fs.rm(helper.directory, { recursive: true }); }
});

for (const signal of [null, "SIGINT", "SIGTERM"]) {
  test(`${signal || "EOF"} during stalled native hello promptly reaps the helper`, { timeout: 5000 }, async () => {
    const helper = await fakeHelper("handshake_hang");
    const session = new Session(["--helper", helper.program]);
    try {
      session.helperPid = await helper.pid();
      const started = performance.now();
      await session.close(signal);
      assert.ok(performance.now() - started < 1500, "Shutdown waited for the hello deadline");
    } finally {
      if (session.child.exitCode === null && session.child.signalCode === null) session.child.kill("SIGTERM");
      await fs.rm(helper.directory, { recursive: true });
    }
  });
}
