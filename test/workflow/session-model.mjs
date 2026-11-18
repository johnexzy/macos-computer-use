import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { setTimeout as sleep } from "node:timers/promises";
import { claudeEnvironment } from "../evaluation/model.mjs";
import { laneName } from "./session-lane.mjs";

const maxStreamBytes = 32 * 1024 * 1024;
const valid = (value) => Number.isFinite(value) && value >= 0 ? value : null;
const usageFields = ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"];
const namespaced = (tools) => tools.map(tool => `mcp__${laneName}__${tool.name}`).sort();

export const workflowSystemPrompt = [
  "Complete the disposable macOS workflow using only the supplied MCP tools. Discover the owned source and work windows and read the actual source through the tools.",
  "Act only on the intended work fields. Leave Notes and any already-correct settings untouched. Use exact identifiers and the observed target; refresh observations after tabs, replacements or stale references.",
  "Keep the fixture in the background. Use semantic actions for input. For rebuilt calls, at most 3000ms per request; use current refs tied to that exact window.",
  "An unknown or uncertain result is never permission to repeat input. Read current state and preserve the receipt. Correct a settled validation clear only after freshly observing the cleared field and validation message. A decimal may already be normalized even when an exact receipt mismatches.",
  "For the invoice, find confirmation after submission and verify the original form is closed. For settings, compare the values for all three pages. Finish with exactly COMPLETE or INCOMPLETE.",
].join("\n");

export function workflowPrompt(task) {
  return task === "invoice"
    ? "Enter the invoice from Source Invoice into Invoice Entry. Enter every line, preserve Notes, and submit once. Verify confirmation."
    : "Make Workflow Settings match the Settings Specification. Check all three pages, change only differences, and leave Notes untouched.";
}

export function sessionArguments({ model, budgetUsd, turns, config, tools }) {
  return ["--bare", "-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--allowedTools", namespaced(tools).join(","),
    "--disable-slash-commands", "--no-chrome", "--strict-mcp-config", "--mcp-config", JSON.stringify(config),
    "--setting-sources", "", "--no-session-persistence", "--permission-mode", "dontAsk", "--max-turns", String(turns),
    "--max-budget-usd", String(budgetUsd), "--effort", "low", "--model", model, "--system-prompt", workflowSystemPrompt];
}

function matchesInit(init, tools, model) {
  const connected = init?.mcp_servers;
  return typeof init?.session_id === "string" && init.model === model &&
    Array.isArray(init.tools) && JSON.stringify([...init.tools].sort()) === JSON.stringify(namespaced(tools)) &&
    connected?.length === 1 && connected[0]?.name === laneName && connected[0]?.status === "connected" &&
    !init.mcp_server_errors?.length && !init.plugin_errors?.length && !init.skills?.length &&
    (init.plugins ?? []).every(plugin => plugin.path === "builtin" && plugin.source?.endsWith("@builtin"));
}

export function summarizeSession(records, { model, tools, exitCode, failure }) {
  const inits = records.filter(record => record.type === "system" && record.subtype === "init");
  const results = records.filter(record => record.type === "result");
  const init = inits.length === 1 ? inits[0] : null;
  const result = results.length === 1 ? results[0] : null;
  const models = Object.keys(result?.modelUsage ?? {});
  const usage = Object.fromEntries(usageFields.map(field => [field,
    models.length && models.every(key => valid(result.modelUsage[key]?.[field]) !== null)
      ? models.reduce((sum, key) => sum + result.modelUsage[key][field], 0) : null]));
  const sessionId = init?.session_id ?? null;
  const inventoryOk = matchesInit(init, tools, model);
  const ordered = init && result && records.indexOf(init) < records.indexOf(result);
  const modelOk = models.length === 1 && models[0] === model;
  const sameSession = Boolean(sessionId && result?.session_id === sessionId && records.every(r => !r.session_id || r.session_id === sessionId));
  const text = typeof result?.result === "string" ? result.result.trim() : "";
  const claim = text === "COMPLETE" ? "complete" : text === "INCOMPLETE" ? "incomplete" : null;
  return { ok: Boolean(!failure && exitCode === 0 && ordered && result.subtype === "success" && result.is_error !== true && inventoryOk && modelOk && sameSession && claim !== null),
    sessionId, sameSession, inventoryOk, modelOk, models, usage, costUsd: valid(result?.total_cost_usd), costSource: "cli_reported_estimate",
    numTurns: valid(result?.num_turns), apiMs: valid(result?.duration_api_ms), subtype: result?.subtype ?? null, claim,
    terminalResults: results.length, initEvents: inits.length, exitCode, failure };
}

export async function runSession({ binary, prefix = [], env, cwd, model, tools, config, prompt, budgetUsd, turns, timeoutMs, onReady, onStop }) {
  const args = sessionArguments({ model, budgetUsd, turns, config, tools });
  const childEnv = { ...claudeEnvironment({ env, model }), CLAUDE_CODE_MAX_OUTPUT_TOKENS: "8192", ENABLE_TOOL_SEARCH: "false",
    DISABLE_NON_ESSENTIAL_MODEL_CALLS: "1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", MCP_TIMEOUT: "10000" };
  const secrets = [childEnv.ANTHROPIC_API_KEY, childEnv.ANTHROPIC_AUTH_TOKEN, childEnv.CLAUDE_CODE_OAUTH_TOKEN].filter(Boolean);
  const redact = (value) => secrets.reduce((text, secret) => text.replaceAll(secret, "[REDACTED]"), value);
  const started = performance.now();
  const child = spawn(binary, [...prefix, ...args], { cwd, env: childEnv, detached: true, stdio: ["pipe", "pipe", "pipe"] });
  let failure, forceStop, pending = "", stderr = "", bytes = 0, terminalSeen = false, initialized = false, finished = false;
  const records = [];
  const hash = createHash("sha256");
  const utf8 = new StringDecoder("utf8");
  const signal = (name) => {
    if (!child.pid) return false;
    try { return process.kill(-child.pid, name); } catch (err) { if (err.code !== "ESRCH") throw err; return false; }
  };
  const stop = (reason) => {
    if (failure) return;
    failure = reason;
    onStop?.();
    if (finished) return;
    signal("SIGTERM");
    forceStop = new AbortController();
    // The direct child may exit while a relay or descendant remains in its group.
    void sleep(1000, null, { signal: forceStop.signal }).then(() => signal("SIGKILL"), () => {});
  };
  const line = (raw) => {
    if (!raw.trim()) return;
    const text = redact(raw);
    let record;
    try { record = JSON.parse(text); } catch { stop("Malformed Claude stream record"); return; }
    if (!record || typeof record !== "object" || !record.type) { stop("Invalid Claude stream record"); return; }
    hash.update(`${text}\n`);
    records.push(record);
    if (record.type === "system" && record.subtype === "init") {
      if (terminalSeen || initialized || !matchesInit(record, tools, model)) stop("Unexpected CLI tool inventory, model, server status or stream order");
      else if (!failure) {
        initialized = true;
        onReady?.();
      }
    }
    if (record.type === "result") {
      onStop?.();
      if (terminalSeen) stop("Duplicate terminal result");
      if (!initialized) {
        // Auth and launch errors may legitimately precede init. They carry no tool admission.
        if (record.subtype === "success") stop("Successful result preceded CLI initialization");
      }
      terminalSeen = true;
    }
  };
  const exited = new Promise((resolve) => {
    child.once("error", (err) => stop(redact(err.message)));
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  const timer = setTimeout(() => stop("Agent session wall-clock budget exceeded"), timeoutMs);
  child.stdout.on("data", (chunk) => {
    bytes += chunk.length;
    if (bytes > maxStreamBytes) { stop("Agent stream exceeded byte limit"); return; }
    pending += utf8.write(chunk);
    const lines = pending.split("\n");
    pending = lines.pop();
    for (const raw of lines) line(raw);
  });
  child.stderr.on("data", (chunk) => { if (stderr.length < 16384) stderr += chunk.toString().slice(0, 16384 - stderr.length); });
  child.stdin.on("error", () => {});
  child.stdin.end(prompt);
  const exit = await exited;
  finished = true;
  clearTimeout(timer);
  if (forceStop) {
    if (signal(0)) signal("SIGKILL");
    forceStop.abort();
  }
  pending += utf8.end();
  if (pending.trim() && bytes <= maxStreamBytes) line(pending);
  onStop?.();
  const summary = summarizeSession(records, { model, tools, exitCode: exit.code, failure });
  return { ...summary, elapsedMs: performance.now() - started, signal: exit.signal, stdoutBytes: bytes, stderr: redact(stderr),
    records, streamSha256: hash.digest("hex"), streamContract: 1, args };
}
