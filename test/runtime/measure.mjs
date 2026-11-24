// Read-only capabilities timing; no model inference or native UI mutations.
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { distribution } from "../baseline/metrics.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const output = path.resolve(process.argv[2] || path.join(root, ".artifacts/runtime-timing.json"));
const host = path.join(root, ".artifacts/runtime-install/useui");
const helper = path.join(root, ".artifacts/runtime-install/useui-runtime");
const child = spawn(host, [], { cwd: os.tmpdir(), stdio: ["pipe", "pipe", "pipe"] });
const exited = once(child, "exit");
const pending = new Map();
const traces = new Map();
const samples = [];
const helperPids = new Set(), epochs = new Set();
let nextId = 0, diagnosticPartial = "";
child.stderr.on("data", (bytes) => {
  diagnosticPartial += bytes.toString();
  let newline;
  while ((newline = diagnosticPartial.indexOf("\n")) >= 0) {
    const line = diagnosticPartial.slice(0, newline); diagnosticPartial = diagnosticPartial.slice(newline + 1);
    try {
      const event = JSON.parse(line);
      if (event.event === "runtime_started") helperPids.add(event.helperPid);
      if (event.event === "tool_finished") traces.set(event.requestId, event);
    } catch { /* Native framework stderr is outside the timing schema. */ }
  }
});
const reader = createInterface({ input: child.stdout });
reader.on("line", (line) => {
  const response = JSON.parse(line);
  const request = pending.get(response.id);
  if (!request) throw new Error("Unexpected MCP response");
  pending.delete(response.id);
  request.resolve({ response, elapsedMs: performance.now() - request.started, responseBytes: Buffer.byteLength(line) });
});
const request = (method, params) => {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Timing request exceeded 5s")), 5000);
    pending.set(id, { started: performance.now(), resolve: (value) => { clearTimeout(timer); resolve(value); } });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
};
try {
  const initialized = await request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "runtime-timing", version: "1" } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  for (let i = 0; i < 55; i++) {
    const sample = await request("tools/call", { name: "capabilities", arguments: {} });
    if (sample.response.result?.isError !== false) throw new Error("Capabilities probe failed");
    epochs.add(sample.response.result.structuredContent.epoch);
    if (i >= 5) samples.push({ requestId: sample.response.result.structuredContent.id,
      mcpRoundtripMs: sample.elapsedMs, responseBytes: sample.responseBytes });
  }
  child.stdin.end();
  const [code, signal] = await exited;
  if (code !== 0 || signal !== null) throw new Error("Installed host did not shut down cleanly");
  const matched = samples.map((sample) => {
    const trace = traces.get(sample.requestId);
    if (!trace || !Number.isFinite(trace.nativeClientElapsedMs)) throw new Error("Missing attributable client timing");
    return { ...sample, adapterElapsedMs: trace.elapsedMs, nativeClientElapsedMs: trace.nativeClientElapsedMs,
      adapterWrappingMs: trace.elapsedMs - trace.nativeClientElapsedMs };
  });
  const hash = async (file) => createHash("sha256").update(await fs.readFile(file)).digest("hex");
  const report = { schemaVersion: 1, recordedAt: new Date().toISOString(), sdk: "rmcp 3.10.0",
    mcpProtocol: initialized.response.result.protocolVersion, privateProtocol: 1,
    source: { revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
      dirty: Boolean(execFileSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" }).trim()),
      hostSha256: await hash(host), helperSha256: await hash(helper) },
    environment: { macOS: execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).trim(),
      architecture: os.arch(), cpu: os.cpus()[0].model },
    operation: "capabilities", warmupCalls: 5, recordedCalls: matched.length,
    observedHelperProcesses: helperPids.size || null, observedEpochs: epochs.size,
    metrics: Object.fromEntries(["mcpRoundtripMs", "adapterElapsedMs", "nativeClientElapsedMs", "adapterWrappingMs", "responseBytes"]
      .map((key) => [key, distribution(matched.map((s) => s[key]))])),
    notes: ["Sequential read-only permission queries; no AX traversal, capture, mutation or model inference.",
      "MCP roundtrip includes public JSON encoding/decoding, transport, SDK, client IPC and native work.",
      "Native client timing includes request validation/encoding, queueing, private IPC and native work.",
      "Adapter wrapping is a per-request difference of nested intervals; it excludes MCP parse and response transport. Scheduling can affect all samples.",
      "These are warm same-machine preflight timings, not task completion or a matched legacy/new semantic comparison."],
    tokens: null, costUsd: null, samples: matched };
  await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ report: output, metrics: report.metrics }, null, 2));
} finally {
  reader.close();
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
}
