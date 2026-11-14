import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import { constants } from "node:fs";

const exec = promisify(execFile);
const redact = (text, env) => ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]
  .reduce((value, key) => env[key] ? value.replaceAll(env[key], "[REDACTED]") : value, text);
export const commandSchema = {
  type: "object", additionalProperties: false,
  properties: { kind: { enum: ["tool", "finish"] }, tool: { type: "string" }, argsJson: { type: "string" },
    claim: { enum: ["complete", "refuse", "incomplete"] }, reason: { type: "string" } },
  required: ["kind", "tool", "argsJson", "claim", "reason"],
};
const finite = (value) => Number.isFinite(value) && value >= 0 ? value : null;
export function parseCommand(value) {
  if (!value || Object.keys(value).sort().join() !== "argsJson,claim,kind,reason,tool" ||
      !["tool", "finish"].includes(value.kind) || !["complete", "refuse", "incomplete"].includes(value.claim) ||
      ![value.tool, value.argsJson, value.reason].every((v) => typeof v === "string")) throw new Error("Invalid model command shape");
  const args = JSON.parse(value.argsJson);
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("Model tool arguments must be an object");
  if (value.kind === "tool" && (!value.tool || value.claim !== "incomplete")) throw new Error("A tool proposal cannot claim completion");
  if (value.kind === "finish" && (value.tool !== "" || Object.keys(args).length)) throw new Error("Finish cannot dispatch a tool");
  return { ...value, args };
}
export function parseResult(stdout, exitCode = 0, pinnedModel = null) {
  let result;
  try { result = JSON.parse(stdout); } catch { return { ok: false, error: "Claude returned non-JSON output", model: null, usage: null, costUsd: null }; }
  const models = Object.keys(result.modelUsage || {});
  const model = models.length === 1 && models[0].startsWith("claude-") ? models[0] : null;
  // Top-level usage covers the main conversation only. modelUsage also includes auxiliary calls.
  const sum = (field) => models.length && models.every((key) => finite(result.modelUsage[key]?.[field]) !== null)
    ? models.reduce((total, key) => total + result.modelUsage[key][field], 0) : null;
  const usage = { inputTokens: sum("inputTokens"), outputTokens: sum("outputTokens"),
    cacheReadInputTokens: sum("cacheReadInputTokens"), cacheCreationInputTokens: sum("cacheCreationInputTokens"),
    reasoningTokens: null };
  const parsed = { ok: false, error: null, model, models, usage, costUsd: finite(result.total_cost_usd),
    usageSource: "cli_model_usage_all_models", primaryUsage: result.usage ?? null, costSource: "cli_reported_estimate",
    sessionId: result.session_id ?? null, durationApiMs: finite(result.duration_api_ms), numTurns: finite(result.num_turns),
    subtype: result.subtype ?? null, raw: result };
  if (exitCode !== 0 || result.is_error === true || result.type !== "result" || result.subtype !== "success") {
    parsed.error = `Claude invocation failed (${result.subtype || exitCode})`; return parsed;
  }
  if (!model || (pinnedModel && model !== pinnedModel)) { parsed.error = "Resolved model missing, mixed, or changed"; return parsed; }
  try { parsed.command = parseCommand(result.structured_output ?? JSON.parse(result.result)); parsed.ok = true; }
  catch (error) { parsed.error = error.message; }
  return parsed;
}

export async function apiKeyEnvironment(file) {
  if (!file) return process.env;
  let handle;
  try {
    handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0) throw new Error();
    const text = (await handle.readFile("utf8")).trim();
    const assignment = text.match(/^[ \t]*(?:export[ \t]+)?ANTHROPIC_API_KEY[ \t]*=[ \t]*(.*)$/m);
    if (!assignment && /^[ \t]*(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=/m.test(text)) throw new Error();
    let key = assignment ? assignment[1].trim() : text;
    if (assignment && (key.startsWith('"') || key.startsWith("'"))) {
      const quote = key[0], end = key.indexOf(quote, 1);
      if (end < 0 || !/^(?:\s*#.*)?$/.test(key.slice(end + 1))) throw new Error();
      key = key.slice(1, end);
    } else if (assignment) key = key.replace(/\s+#.*$/, "").trim();
    if (!key || /\s/.test(key)) throw new Error();
    return { ...process.env, ANTHROPIC_API_KEY: key };
  } catch { throw new Error("API key file must be an owner-only regular file containing a bare key or ANTHROPIC_API_KEY entry"); }
  finally { await handle?.close(); }
}

export async function preflightClaude(binary = "claude", env = process.env) {
  const envPresence = Object.fromEntries(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_BASE_URL"]
    .map((key) => [key, Boolean(env[key])]));
  let version = null, auth = {}, error = null;
  try {
    version = redact((await exec(binary, ["--version"], { timeout: 10000, env })).stdout.trim(), env);
    let stdout;
    try { stdout = (await exec(binary, ["auth", "status", "--json"], { timeout: 10000, env })).stdout; }
    catch (failure) { stdout = failure.stdout; }
    const status = JSON.parse(stdout);
    auth = { loggedIn: status.loggedIn === true, authMethod: typeof status.authMethod === "string" ? redact(status.authMethod, env) : null,
      apiProvider: typeof status.apiProvider === "string" ? redact(status.apiProvider, env) : null };
  } catch (failure) { error = redact(failure.message, env); }
  const credentialsPresent = auth.loggedIn === true || Object.entries(envPresence).some(([key, value]) => key !== "ANTHROPIC_BASE_URL" && value);
  return { version, auth, envPresence, available: Boolean(version && credentialsPresent), error: error || (!credentialsPresent ? "Claude authentication unavailable" : null) };
}

export function claudeArguments({ model, budgetUsd, systemPrompt }) {
  return ["--safe-mode", "-p", "--output-format", "json", "--json-schema", JSON.stringify(commandSchema),
    "--tools", "", "--disable-slash-commands", "--no-chrome", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
    "--setting-sources", "", "--no-session-persistence", "--permission-mode", "dontAsk", "--max-turns", "1",
    "--max-budget-usd", String(budgetUsd), "--effort", "low", "--model", model, "--system-prompt", systemPrompt];
}
export function claudeEnvironment({ model, env = process.env }) {
  // Alias probes have no exact ID yet. Once known, pin both current and deprecated background selectors.
  const roles = model.startsWith("claude-") ? Object.fromEntries([
    "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
  ].map((key) => [key, model])) : {};
  return { ...env, ...roles, CLAUDE_CODE_DISABLE_TERMINAL_TITLE: "1", CLAUDE_CODE_MAX_OUTPUT_TOKENS: "1500", MAX_STRUCTURED_OUTPUT_RETRIES: "0" };
}
export async function invokeClaude({ binary = "claude", model, budgetUsd, systemPrompt, prompt, cwd, timeoutMs = 60000, pinnedModel, env = process.env }) {
  const args = claudeArguments({ model, budgetUsd, systemPrompt });
  const childEnv = claudeEnvironment({ model: pinnedModel || model, env });
  const start = performance.now();
  const child = spawn(binary, args, { cwd, stdio: ["pipe", "pipe", "pipe"],
    env: childEnv });
  let stdout = "", stderr = "", failure = null;
  const stop = () => { child.kill("SIGKILL"); };
  const timer = setTimeout(() => { failure = "Model wall-clock budget exceeded"; stop(); }, timeoutMs);
  const exited = new Promise((resolve) => {
    child.on("error", (error) => { failure = error.message; });
    child.on("close", (code, signal) => resolve([code, signal]));
  });
  child.stdout.on("data", (bytes) => { stdout += bytes; if (Buffer.byteLength(stdout) > 2 * 1024 * 1024) { failure = "Model output limit exceeded"; stop(); } });
  child.stderr.on("data", (bytes) => { if (stderr.length < 16384) stderr += bytes.toString().slice(0, 16384 - stderr.length); });
  child.stdin.on("error", () => {});
  child.stdin.end(prompt);
  const [code, signal] = await exited; clearTimeout(timer);
  // Provider/CLI errors must never persist a supplied key, even if an upstream message echoes it.
  const parsed = parseResult(redact(stdout, env), code, pinnedModel);
  return { ...parsed, ok: parsed.ok && !failure && signal === null, error: failure || parsed.error,
    elapsedMs: performance.now() - start, exitCode: code, signal, stderr: redact(stderr, env),
    invocation: { binary, args, timeoutMs, backgroundTitleRequestDisabled: true, modelRoleOverrides: Object.fromEntries(Object.entries(childEnv)
      .filter(([key]) => ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"].includes(key))) }, responseBytes: Buffer.byteLength(stdout) };
}

export class ModelBudget {
  constructor(limitUsd = 5, perCallUsd = 0.1) { this.limitUsd = limitUsd; this.perCallUsd = perCallUsd; this.spentUsd = 0; this.measured = true; this.calls = 0; }
  allowance() { return this.measured && this.limitUsd - this.spentUsd >= this.perCallUsd ? this.perCallUsd : null; }
  record(result) { this.calls++; if (result.costUsd === null) this.measured = false; else this.spentUsd += result.costUsd; }
  summary() { return { limitUsd: this.limitUsd, perCallUsd: this.perCallUsd, calls: this.calls,
    costSource: "cli_reported_estimate",
    reportedCostUsd: this.calls && this.measured ? this.spentUsd : null, knownReportedCostUsd: this.calls ? this.spentUsd : null,
    exceeded: this.spentUsd > this.limitUsd, measured: this.measured }; }
}
