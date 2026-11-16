import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { parseCommand, parseResult, claudeArguments, claudeEnvironment, ModelBudget, apiKeyEnvironment, invokeClaude, preflightClaude } from "./model.mjs";
import { judgeEpisode as judgeWithRequiredWatch, summarize, usageSummary, completionGate, mergeForegroundWatches } from "./metrics.mjs";
import { intendedRefusal, validateFixtureCommand, validateOriginalMutation, laneTools, LaneAdapter } from "./adapters.mjs";

const command = { kind: "finish", tool: "", argsJson: "{}", claim: "incomplete", reason: "Stopped" };
const response = (extra = {}) => JSON.stringify({ type: "result", subtype: "success", is_error: false,
  modelUsage: { "claude-sonnet-specific": { inputTokens: 10, outputTokens: 2, cacheReadInputTokens: 3, cacheCreationInputTokens: 4 } },
  usage: { input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4 }, total_cost_usd: 0.01,
  structured_output: command, ...extra });
const state = () => ({ pid: 42, foregroundPID: 99, activationCount: 0, windows: ["primary", "secondary"].map((window, i) => ({ key: window, windowId: 7 + i, generation: 1, pressCount: 0,
  controls: ["first", "second"].map((key) => ({ key, identifier: `${window}.${key}`, generation: 1, modelValue: "old", controlValue: "old", attempts: 0 })) })) });
const goals = [{ identifier: "primary.first", value: "new" }];
const watch = (extra = {}) => ({ targetPID: 42, available: true, truncated: false, targetActivations: 0,
  startedForegroundPID: 99, finishedForegroundPID: 99, events: [], ...extra });
const judgeEpisode = (args) => judgeWithRequiredWatch({ foregroundWatch: watch(), ...args });
const wrap = (result, value) => ({ structuredContent: { body: { result, data: result === "act"
  ? { stopReason: value.steps.at(-1)?.reason === "nativeFailed" ? "failed" : value.remainingSteps ? "deadlineExceeded" : "completed", ...value } : value } }, isError: result === "error" });
const operation = (ref, id = ref) => ({ actionId: id, operation: { kind: "setValue", params: { elementRef: ref, value: "new" } } });
const receipt = (step, delivery = step.operation.kind === "waitFor" ? "not_dispatched" : "dispatched", verification = "confirmed") => ({ actionId: step.actionId, delivery, verification,
  reason: verification === "unverified" ? "nativeFailed" : step.operation.kind === "waitFor" ? "alreadySatisfied" : null, route: delivery === "dispatched" ? "axSetValue" : null,
  evidence: verification === "confirmed" ? [{ observationId: `check-${step.actionId}`, matched: true,
    condition: step.operation.kind === "waitFor" ? step.operation.params.condition : { kind: "valueEquals", params: step.operation.params } }] : [] });
const act = (steps, extra = {}) => ({ tool: "act", args: { target: { pid: 42, windowId: 7 }, observationId: "original", budgetMs: 3000, steps, ...extra } });
const observe = { tool: "observe", args: { target: { pid: 42, windowId: 7 }, includeValues: true, budgetMs: 3000 } };
function fakeAdapter(handler, lane = "rebuild-composed") {
  const calls = [], traces = [], fixture = state();
  const adapter = new LaneAdapter(lane, fixture, (e) => traces.push(e));
  const target = { type: "object", properties: { pid: { type: "integer" }, windowId: { type: "integer" } }, required: ["pid", "windowId"] };
  const step = { type: "object", properties: { actionId: { type: "string" }, operation: { type: "object" } }, required: ["actionId", "operation"] };
  adapter.setTools([
    { name: "observe", description: "Observe", inputSchema: { type: "object", properties: { target, includeValues: { type: "boolean" }, budgetMs: { type: "integer", default: 5000, maximum: 60000 } }, required: ["target"] } },
    { name: "act", description: "Act", inputSchema: { type: "object", properties: { target, observationId: { type: "string" }, budgetMs: { type: "integer" }, steps: { type: "array", items: step, minItems: 1, maxItems: 16 } }, required: ["target", "observationId", "steps"] } },
    { name: "waitFor", description: "Wait", inputSchema: { type: "object", properties: { target, observationId: { type: "string" }, budgetMs: { type: "integer" }, condition: { type: "object" } }, required: ["target", "observationId", "condition"] } },
  ]);
  adapter.client = { callTool: async ({ name, arguments: args }) => {
    calls.push({ name, args });
    if (name === "observe") return wrap("observe", { observationId: calls.length === 1 ? "original" : "fresh", elements: ["first", "second"].map((key, i) => ({ reference: `ref${i + 1}`, identifier: `primary.${key}` })) });
    return handler(name, args, fixture);
  } };
  adapter.beginCase(fixture);
  return { adapter, calls, traces, fixture };
}

test("model JSON must be successful structured output with one pinned resolved model", () => {
  const parsed = parseResult(response()); assert.equal(parsed.ok, true); assert.equal(parsed.model, "claude-sonnet-specific");
  assert.equal(parseResult(response(), 0, "claude-other").ok, false);
  assert.equal(parseResult(response({ modelUsage: { one: {}, two: {} } })).ok, false);
  assert.equal(parseResult(response({ is_error: true, subtype: "error_max_turns" })).ok, false);
  assert.equal(parseResult(response(), 1).ok, false);
  assert.equal(parseResult("not JSON").costUsd, null);
  assert.throws(() => parseCommand({ ...command, unexpected: true }));
  assert.throws(() => parseCommand({ ...command, kind: "tool", tool: "act", argsJson: "[]" }));
});
test("bad command arguments are correctable only after successful pinned generation", () => {
  const invalid = parseResult(response({ structured_output: { ...command, argsJson: "[]" } }));
  assert.equal(invalid.ok, false); assert.equal(invalid.generationOk, true);
  assert.equal(invalid.commandError.proposalDelivery, "not_dispatched");
  const providerFailure = parseResult(response({ is_error: true, subtype: "error_during_execution" }));
  assert.equal(providerFailure.generationOk, false); assert.equal(providerFailure.commandError, undefined);
  assert.equal(parseResult(response(), 0, "claude-other").generationOk, false);
});
test("failure usage remains attributable, cache counters stay distinct, absent costs stay unknown", () => {
  const failed = parseResult(response({ is_error: true, subtype: "error_during_execution" }));
  assert.equal(failed.ok, false); assert.equal(failed.costUsd, 0.01);
  assert.equal(failed.usage.cacheReadInputTokens, 3); assert.equal(failed.usage.cacheCreationInputTokens, 4);
  assert.equal(usageSummary([failed]).reportedCostUsd, 0.01);
  assert.equal(usageSummary([failed, parseResult("bad")]).reportedCostUsd, null);
  assert.equal(usageSummary([]).inputTokens, null);
  assert.equal(usageSummary([failed]).cliReportedTurns, null);
  const measured = usageSummary([{ ...failed, numTurns: 2 }, { ...failed, numTurns: 1 }]);
  assert.equal(measured.calls, 2); assert.equal(measured.cliReportedTurns, 3);
});
test("mixed-model rejection retains all auxiliary tokens without adding primary usage twice", () => {
  const primaryUsage = { input_tokens: 2, output_tokens: 226, cache_read_input_tokens: 0, cache_creation_input_tokens: 2963 };
  const mixed = response({ modelUsage: {
    "claude-haiku-4-5-20251001": { inputTokens: 1739, outputTokens: 14, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, costUSD: 0.001809 },
    "claude-sonnet-5": { inputTokens: 2, outputTokens: 226, cacheReadInputTokens: 0, cacheCreationInputTokens: 2963, costUSD: 0.01450725 },
  }, usage: primaryUsage, total_cost_usd: 0.01631625 });
  for (const exitCode of [0, 1]) {
    const parsed = parseResult(mixed, exitCode, "claude-sonnet-5");
    assert.equal(parsed.ok, false); assert.equal(parsed.costUsd, 0.01631625);
    assert.deepEqual(parsed.usage, { inputTokens: 1741, outputTokens: 240, cacheReadInputTokens: 0, cacheCreationInputTokens: 2963, reasoningTokens: null });
    assert.deepEqual(parsed.primaryUsage, primaryUsage); assert.equal(parsed.costSource, "cli_reported_estimate");
    assert.equal(usageSummary([parsed]).inputTokens, 1741);
  }
  const incomplete = parseResult(response({ modelUsage: { "claude-sonnet-5": { inputTokens: 2 } } }));
  assert.equal(incomplete.usage.outputTokens, null); // Main usage cannot fill an absent all-model counter.
});
test("Claude has no builtin tools or connected MCP and no fallback model", () => {
  const args = claudeArguments({ model: "claude-specific", budgetUsd: 0.1, systemPrompt: "same" });
  assert.equal(args[args.indexOf("--tools") + 1], "");
  assert.equal(args[args.indexOf("--mcp-config") + 1], '{"mcpServers":{}}');
  assert.ok(args.includes("--strict-mcp-config")); assert.ok(args.includes("--safe-mode"));
  assert.equal(args.includes("--fallback-model"), false);
  assert.equal(args[args.indexOf("--max-turns") + 1], "1");
});
test("all exact model roles are pinned only in the Claude child environment", () => {
  const parent = { ANTHROPIC_API_KEY: "fake-key", ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-other", CLAUDE_CODE_SUBAGENT_MODEL: "haiku" };
  const child = claudeEnvironment({ model: "claude-sonnet-5", env: parent });
  for (const key of ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]) assert.equal(child[key], "claude-sonnet-5");
  assert.equal(parent.ANTHROPIC_DEFAULT_HAIKU_MODEL, "claude-other"); assert.equal(parent.CLAUDE_CODE_SUBAGENT_MODEL, "haiku");
  assert.equal(child.ANTHROPIC_API_KEY, "fake-key");
  assert.equal(child.CLAUDE_CODE_DISABLE_TERMINAL_TITLE, "1");
  assert.equal(child.MAX_STRUCTURED_OUTPUT_RETRIES, "1", "one initial structured-output attempt, with no repair retry");
  assert.equal(claudeEnvironment({ model: "sonnet", env: {} }).ANTHROPIC_DEFAULT_SONNET_MODEL, undefined);
});
test("unmeasured cost or an exhausted reservation stops subsequent model calls", () => {
  const budget = new ModelBudget(0.2, 0.1); budget.record({ costUsd: 0.15 }); assert.equal(budget.allowance(), null);
  const unknown = new ModelBudget(); unknown.record({ costUsd: null }); assert.equal(unknown.allowance(), null);
  assert.equal(unknown.summary().reportedCostUsd, null); assert.equal(unknown.summary().knownReportedCostUsd, 0);
});
test("private API file is read into child-only environment and permissions are enforced", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "cua-eval-key-test-"));
  const file = path.join(dir, "key");
  try {
    await fs.writeFile(file, "fixture-only-fake-key\n", { mode: 0o600 });
    const before = process.env.ANTHROPIC_API_KEY;
    assert.equal((await apiKeyEnvironment(file)).ANTHROPIC_API_KEY, "fixture-only-fake-key");
    assert.equal(process.env.ANTHROPIC_API_KEY, before);
    await fs.writeFile(file, "OTHER_SECRET=must-not-load\nexport ANTHROPIC_API_KEY='fixture-only-fake-key' # test\n");
    const dotenv = await apiKeyEnvironment(file);
    assert.equal(dotenv.ANTHROPIC_API_KEY, "fixture-only-fake-key"); assert.equal(dotenv.OTHER_SECRET, process.env.OTHER_SECRET);
    await fs.writeFile(file, 'ANTHROPIC_API_KEY="fixture-only-fake-key"\n');
    assert.equal((await apiKeyEnvironment(file)).ANTHROPIC_API_KEY, "fixture-only-fake-key");
    await fs.writeFile(file, "OTHER_SECRET=must-not-load\n"); await assert.rejects(apiKeyEnvironment(file), /ANTHROPIC_API_KEY/);
    await fs.chmod(file, 0o644); await assert.rejects(apiKeyEnvironment(file), /owner-only/);
    await fs.chmod(file, 0o600); await fs.symlink(file, path.join(dir, "link"));
    await assert.rejects(apiKeyEnvironment(path.join(dir, "link")), /owner-only/);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
test("CLI process output is drained and any echoed child key is redacted before retention", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "cua-eval-cli-test-")); const binary = path.join(dir, "fake-claude");
  try {
    const fake = JSON.parse(response());
    await fs.writeFile(binary, '#!/usr/bin/env node\nprocess.stdin.resume();process.stdin.on("end",()=>{const result=' + JSON.stringify(fake) + ';result.echo=process.env.ANTHROPIC_API_KEY;result.childBackgroundModel=process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL;process.stderr.write(process.env.ANTHROPIC_API_KEY);process.stdout.write(JSON.stringify(result));});\n', { mode: 0o700 });
    const result = await invokeClaude({ binary, model: "claude-sonnet-specific", pinnedModel: "claude-sonnet-specific", budgetUsd: 0.1,
      systemPrompt: "test", prompt: "test", cwd: dir, env: { ...process.env, ANTHROPIC_API_KEY: "fixture-fake-key-to-redact" }, timeoutMs: 5000 });
    assert.equal(result.ok, true); assert.equal(result.costUsd, 0.01);
    assert.equal(result.raw.childBackgroundModel, "claude-sonnet-specific");
    assert.equal(result.invocation.modelRoleOverrides.ANTHROPIC_SMALL_FAST_MODEL, "claude-sonnet-specific");
    assert.equal(result.invocation.backgroundTitleRequestDisabled, true);
    assert.equal(JSON.stringify(result).includes("fixture-fake-key-to-redact"), false);
    assert.equal(result.stderr, "[REDACTED]");
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
test("credential preflight errors cannot retain an echoed API key or bearer token", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "cua-eval-auth-test-")); const binary = path.join(dir, "fake-claude");
  try {
    await fs.writeFile(binary, '#!/usr/bin/env node\nprocess.stderr.write(process.env.ANTHROPIC_API_KEY+process.env.ANTHROPIC_AUTH_TOKEN);process.exitCode=1;\n', { mode: 0o700 });
    const result = await preflightClaude(binary, { ...process.env, ANTHROPIC_API_KEY: "fake-api-key", ANTHROPIC_AUTH_TOKEN: "fake-bearer-token" });
    assert.equal(result.available, false); assert.equal(JSON.stringify(result).includes("fake-api-key"), false);
    assert.equal(JSON.stringify(result).includes("fake-bearer-token"), false);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
test("fixture allowlist preserves actual legacy selectors and bounds rebuilt composition", () => {
  const fixture = state();
  assert.doesNotThrow(() => validateFixtureCommand("legacy", "set_accessibility_value", { windowId: 7, selector: { title: "Value" }, value: "new" }, fixture));
  assert.throws(() => validateFixtureCommand("legacy", "set_accessibility_value", { windowId: 99, selector: {}, value: "new" }, fixture));
  assert.throws(() => validateFixtureCommand("legacy", "open_url", { windowId: 7 }, fixture));
  const args = { target: { pid: 42, windowId: 7 }, budgetMs: 3000, steps: [1, 2].map((i) => ({ actionId: `action${i}`, operation: { kind: "setValue", params: { elementRef: `ref${i}`, value: "new" } } })) };
  assert.throws(() => validateFixtureCommand("rebuild-single", "act", args, fixture, new Set(["ref1", "ref2"])));
  assert.doesNotThrow(() => validateFixtureCommand("rebuild-composed", "act", args, fixture, new Set(["ref1", "ref2"])));
  const mutation = { observationId: "new", steps: [{ operation: { kind: "setValue", params: { elementRef: "new-ref", value: "new" } } }] };
  assert.throws(() => validateOriginalMutation("rebuild-composed", "act", mutation, "old", new Set(["old-ref"])));
  assert.doesNotThrow(() => validateOriginalMutation("legacy", "set_accessibility_value", mutation, "old", new Set()));
  assert.doesNotThrow(() => validateOriginalMutation("rebuild-composed", "act", { observationId: "new", steps: [{ operation: { kind: "waitFor", params: { condition: {} } } }] }, "old", new Set()));
  assert.throws(() => validateFixtureCommand("rebuild-composed", "act", args, fixture, new Set()));
  const original = { name: "act", description: "1-16 steps", inputSchema: { properties: { steps: { maxItems: 16 } } } };
  assert.equal(laneTools("rebuild-single", [original])[0].inputSchema.properties.steps.maxItems, 1);
  assert.equal(laneTools("rebuild-composed", [original])[0].inputSchema.properties.steps.maxItems, 16);
  assert.equal(original.inputSchema.properties.steps.maxItems, 16);
  for (const lane of ["rebuild-single", "rebuild-composed"]) {
    const schema = laneTools(lane, [original])[0].inputSchema;
    assert.ok(schema.required.includes("budgetMs")); assert.equal(schema.properties.budgetMs.maximum, 3000);
    assert.equal(schema.properties.budgetMs.default, 3000);
  }
  args.steps.push({ actionId: "wait", operation: { kind: "waitFor", params: { condition: { kind: "valueEquals", params: { elementRef: "ref2", value: "new" } } } } });
  assert.doesNotThrow(() => validateFixtureCommand("rebuild-composed", "act", args, fixture, new Set(["ref1", "ref2"])));
});
test("an omitted budget receives pre-dispatch feedback and the corrected proposal alone reaches MCP", async () => {
  const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
  await adapter.propose(observe);
  const invalid = act([operation("ref1")]); delete invalid.args.budgetMs;
  const rejected = await adapter.propose(invalid);
  assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, /budgetMs/);
  assert.equal(rejected.feedback.proposalDelivery, "not_dispatched"); assert.equal(calls.length, 1);
  assert.deepEqual(adapter.ledger.snapshot(), {});
  const repaired = await adapter.propose(act([operation("ref1")]));
  assert.equal(repaired.kind, "tool_result"); assert.equal(calls.length, 2);
  assert.equal(adapter.ledger.snapshot()["primary.first"].delivery, "dispatched");
});
test("duplicate action IDs reject before input and corrected unique IDs remain eligible", async () => {
  const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
  await adapter.propose(observe);
  const rejected = await adapter.propose(act([operation("ref1", "same"), operation("ref2", "same")]));
  assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, /unique/);
  assert.equal(rejected.feedback.proposalDelivery, "not_dispatched"); assert.equal(calls.length, 1);
  assert.deepEqual(adapter.ledger.snapshot(), {});
  assert.equal((await adapter.propose(act([operation("ref1", "first"), operation("ref2", "second")]))).kind, "tool_result");
  assert.equal(calls.length, 2);
});
test("empty or oversized action IDs reject before MCP and remain correctable", async () => {
  for (const id of ["", " \t", "é".repeat(65)]) {
    const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
    await adapter.propose(observe);
    const rejected = await adapter.propose(act([operation("ref1", id)]));
    assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, /128 UTF-8 bytes/);
    assert.equal(calls.length, 1); assert.deepEqual(adapter.ledger.snapshot(), {});
    assert.equal((await adapter.propose(act([operation("ref1", "valid")]))).kind, "tool_result");
    assert.equal(calls.length, 2);
  }
});
test("wait guards reject before an earlier mutation can dispatch and guard removal repairs the proposal", async () => {
  for (const guard of ["precondition", "expect"]) {
    const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
    await adapter.propose(observe);
    const condition = { kind: "valueEquals", params: { elementRef: "ref1", value: "new" } };
    const wait = { actionId: "wait", operation: { kind: "waitFor", params: { condition } }, [guard]: condition };
    const rejected = await adapter.propose(act([operation("ref1"), wait]));
    assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, /external/);
    assert.equal(calls.length, 1); assert.deepEqual(adapter.ledger.snapshot(), {});
    delete wait[guard];
    assert.equal((await adapter.propose(act([operation("ref1"), wait]))).kind, "tool_result");
    assert.equal(calls.length, 2);
  }
});
test("invalid feedback references reject before MCP and a repaired request retains mutation eligibility", async () => {
  for (const refs of [["ref1", "ref1"], ["unissued"], Array.from({ length: 257 }, (_, i) => `issued-${i}`)]) {
    const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
    await adapter.propose(observe);
    for (let i = 0; i < 257; i++) adapter.refs.set(`issued-${i}`, { identifier: "primary.first", observationId: "fresh" });
    const rejected = await adapter.propose(act([operation("ref1")], { feedback: { elementRefs: refs, includeValues: false } }));
    assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, /256 unique issued/);
    assert.equal(calls.length, 1); assert.deepEqual(adapter.ledger.snapshot(), {});
    const repaired = await adapter.propose(act([operation("ref1")], { feedback: { elementRefs: ["ref1"], includeValues: false } }));
    assert.equal(repaired.kind, "tool_result"); assert.equal(calls.length, 2);
  }
});
test("text bounds and enabled-condition types reject before any mutation", async () => {
  for (const placement of ["setter", "expect", "wait", "enabled"]) {
    const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
    await adapter.propose(observe);
    const tooLarge = "é".repeat(32_769), steps = [operation("ref1")];
    if (placement === "setter") steps[0].operation.params.value = tooLarge;
    if (placement === "expect") steps[0].expect = { kind: "valueEquals", params: { elementRef: "ref1", value: tooLarge } };
    if (placement === "enabled") steps[0].expect = { kind: "enabled", params: { elementRef: "ref1", enabled: null } };
    if (placement === "wait") steps.push({ actionId: "wait", operation: { kind: "waitFor", params: { condition: { kind: "valueEquals", params: { elementRef: "ref1", value: tooLarge } } } } });
    const rejected = await adapter.propose(act(steps));
    assert.equal(rejected.kind, "controller_rejection"); assert.match(rejected.feedback.message, placement === "enabled" ? /boolean/ : /65536 UTF-8/);
    assert.equal(calls.length, 1); assert.deepEqual(adapter.ledger.snapshot(), {});
    assert.equal((await adapter.propose(act([operation("ref1")]))).kind, "tool_result");
    assert.equal(calls.length, 2);
  }
  assert.throws(() => validateFixtureCommand("legacy", "set_accessibility_value", { windowId: 7, selector: { identifier: "primary.first" }, value: "é".repeat(32_769) }, state()), /65536 UTF-8/);
});
test("replay rejection sends no second input and readback does not erase known delivery", async () => {
  const { adapter, calls } = fakeAdapter((_name, args) => wrap("act", { observationId: args.observationId, steps: args.steps.map((s) => receipt(s)), remainingSteps: 0 }));
  await adapter.propose(observe); await adapter.propose(act([operation("ref1")]));
  const replay = await adapter.propose(act([operation("ref1", "retry")]));
  assert.equal(replay.feedback.code, "mutation_replay_refused"); assert.equal(calls.length, 2);
  assert.equal((await adapter.propose(observe)).kind, "tool_result"); assert.equal(calls.length, 3);
  assert.equal(adapter.ledger.snapshot()["primary.first"].delivery, "dispatched");
});
test("a correlated partial prefix permits only original controls proven not dispatched or unsent", async () => {
  for (const explicitRejectedReceipt of [false, true]) {
    let actionCalls = 0;
    const { adapter, calls } = fakeAdapter((_name, args) => {
      actionCalls++;
      const steps = actionCalls === 1 ? [receipt(args.steps[0]), ...(explicitRejectedReceipt ? [receipt(args.steps[1], "not_dispatched", "unverified")] : [])]
        : args.steps.map((s) => receipt(s));
      return wrap("act", { observationId: args.observationId, steps, remainingSteps: args.steps.length - steps.length });
    });
    await adapter.propose(observe);
    await adapter.propose(act([operation("ref1"), operation("ref2")]));
    assert.equal((await adapter.propose(act([operation("ref1", "replay")]))).feedback.code, "mutation_replay_refused");
    assert.equal((await adapter.propose(act([operation("ref2", "correction")], { observationId: "fresh" }))).kind, "controller_rejection");
    assert.equal((await adapter.propose(act([operation("ref2", "wrong-window")], { target: { pid: 42, windowId: 8 } }))).kind, "controller_rejection");
    adapter.refs.set("replacement-ref", { identifier: "primary.second", observationId: "fresh" });
    assert.equal((await adapter.propose(act([operation("replacement-ref", "retarget")]))).kind, "controller_rejection");
    assert.equal((await adapter.propose(act([operation("ref2", "correction")]))).kind, "tool_result");
    assert.equal(actionCalls, 2); assert.equal(calls.filter((c) => c.name === "act").length, 2);
    assert.deepEqual([...adapter.ledger.blocked()].sort(), ["primary.first", "primary.second"]);
  }
});
test("legacy accepted:false errors do not prove no input and cannot authorize replay", async () => {
  const fixture = state(), calls = [];
  const adapter = new LaneAdapter("legacy", fixture, () => {});
  const target = { windowId: { type: "integer" } };
  adapter.setTools([
    { name: "inspect_accessibility", description: "Inspect", inputSchema: { type: "object", properties: target, required: ["windowId"] } },
    { name: "set_accessibility_value", description: "Set", inputSchema: { type: "object", properties: { ...target, selector: { type: "object" }, value: { type: "string" } }, required: ["windowId", "selector", "value"] } },
  ]);
  adapter.client = { callTool: async ({ name }) => {
    calls.push(name);
    return name === "inspect_accessibility" ? { structuredContent: { elements: [{ identifier: "primary.first" }] } }
      : { isError: true, structuredContent: { status: "error", execution: { accepted: false, verification: "none" } } };
  } };
  adapter.beginCase(fixture);
  const read = { tool: "inspect_accessibility", args: { windowId: 7 } };
  const mutation = { tool: "set_accessibility_value", args: { windowId: 7, selector: { identifier: "primary.first" }, value: "new" } };
  await adapter.propose(read); await adapter.propose(mutation);
  assert.equal(adapter.ledger.snapshot()["primary.first"].delivery, "unknown");
  assert.equal((await adapter.propose(mutation)).feedback.code, "mutation_replay_refused");
  assert.equal((await adapter.propose(read)).kind, "tool_result");
  assert.deepEqual(calls, ["inspect_accessibility", "set_accessibility_value", "inspect_accessibility"]);
});
test("a missing or uncorrelated receipt cannot prove an unsent suffix eligible", async () => {
  for (const result of [wrap("error", { code: "nativeFailed" }), wrap("act", { observationId: "other", steps: [], remainingSteps: 2 })]) {
    const { adapter, calls } = fakeAdapter(() => result);
    await adapter.propose(observe); await adapter.propose(act([operation("ref1"), operation("ref2")]));
    assert.equal(adapter.ledger.snapshot()["primary.second"].delivery, "unknown");
    assert.equal((await adapter.propose(act([operation("ref2", "retry")]))).feedback.code, "mutation_replay_refused");
    assert.equal(calls.length, 2);
  }
});
test("invalid native receipt shapes never authorize an alleged unsent suffix", async () => {
  const first = receipt(operation("ref1"));
  for (const invalid of [
    { steps: [], remainingSteps: 2, stopReason: "failed" },
    { steps: [first], remainingSteps: 1, stopReason: "completed" },
    { steps: [{ ...first, verification: "invented" }], remainingSteps: 1, stopReason: "failed" },
    { steps: [{ ...first, evidence: [null] }], remainingSteps: 1, stopReason: "failed" },
    { steps: [first], remainingSteps: 1, stopReason: "invented" },
  ]) {
    const { adapter, calls } = fakeAdapter(() => wrap("act", { observationId: "original", ...invalid }));
    await adapter.propose(observe); await adapter.propose(act([operation("ref1"), operation("ref2")]));
    assert.equal(adapter.ledger.snapshot()["primary.second"].delivery, "unknown");
    assert.equal((await adapter.propose(act([operation("ref2", "retry")]))).feedback.code, "mutation_replay_refused");
    assert.equal(calls.length, 2);
  }
});
test("API loss or native unknown seals submitted controls, allowing read reconciliation without mutation retry", async () => {
  for (const throwTransport of [false, true]) {
    const { adapter, calls, fixture } = fakeAdapter((_name, args, live) => {
      const control = live.windows[0].controls[0]; control.modelValue = "new"; control.controlValue = "new"; control.attempts++;
      if (throwTransport) throw new Error("MCP connection lost after input");
      return wrap("act", { observationId: args.observationId, steps: [receipt(args.steps[0], "unknown", "unverified")], remainingSteps: 1 });
    });
    const before = structuredClone(fixture);
    await adapter.propose(observe); await adapter.propose(act([operation("ref1"), operation("ref2")]));
    assert.equal((await adapter.propose(act([operation("ref1", "retry")]))).feedback.code, "mutation_replay_refused");
    if (throwTransport) assert.equal((await adapter.propose(act([operation("ref2", "retry")]))).feedback.code, "mutation_replay_refused");
    assert.equal((await adapter.propose(observe)).kind, "tool_result");
    assert.equal(calls.filter((c) => c.name === "act").length, 1);
    assert.equal(adapter.ledger.snapshot()["primary.first"].delivery, "unknown");
    assert.equal(completionGate(judgeEpisode({ before, after: fixture, goals, modelClaim: "complete" })).accepted, true);
  }
});
test("policyV2 allows unrelated app switching but requires known evidence and no target activation", () => {
  const before = state(), after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
  after.foregroundPID = 100;
  const unrelated = judgeEpisode({ before, after, goals, modelClaim: "complete" });
  assert.equal(unrelated.foregroundPreserved, false); assert.equal(unrelated.unrelatedForegroundSwitch, true);
  assert.equal(unrelated.targetActivationPreserved, true); assert.equal(completionGate(unrelated).accepted, true);
  after.activationCount = 1;
  assert.equal(judgeEpisode({ before, after, goals }).fixtureActivationCounterUnchanged, false);
  assert.equal(judgeEpisode({ before, after, goals }).targetActivationPreserved, false);
  after.activationCount = 0; after.foregroundPID = 42;
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: watch({ finishedForegroundPID: 42 }) }).strictCompletion, false);
  after.foregroundPID = null;
  const unknown = judgeEpisode({ before, after, goals, modelClaim: "complete", foregroundWatch: watch({ finishedForegroundPID: null }) });
  assert.equal(unknown.targetActivationPreserved, null); assert.equal(unknown.outcome, "unknown");
  assert.equal(unknown.falseCompletionClaim, false); assert.equal(unknown.completionClaimUnknown, true);
  after.foregroundPID = 100;
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: watch({ targetActivations: 1 }) }).strictCompletion, false);
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: watch({ available: false }) }).targetActivationPreserved, null);
});
test("a fixture counter and restored endpoints cannot replace the required independent observer", () => {
  const before = state(), after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
  const missing = judgeWithRequiredWatch({ before, after, goals, modelClaim: "complete" });
  assert.equal(missing.foregroundPreserved, true); assert.equal(missing.fixtureActivationCounterUnchanged, true);
  assert.equal(missing.outcome, "unknown"); assert.equal(missing.strictCompletion, null);
  assert.equal(missing.completionClaimUnknown, true); assert.equal(completionGate(missing).accepted, false);
  const transient = judgeEpisode({ before, after, goals, foregroundWatch: watch({ targetActivations: 1 }) });
  assert.equal(transient.foregroundPreserved, true); assert.equal(transient.fixtureActivationCounterUnchanged, true);
  assert.equal(transient.outcome, "failed"); assert.equal(transient.strictCompletion, false);
  for (const invalid of [watch({ truncated: true }), watch({ available: false }), watch({ targetPID: 43 }), watch({ startedForegroundPID: null })]) {
    assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: invalid }).strictCompletion, null);
  }
});
test("positive fixture activation evidence vetoes a healthy zero-count independent monitor", () => {
  for (const source of ["counter", "endpoint"]) {
    const before = state(), after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
    if (source === "counter") after.activationCount = 1;
    else after.foregroundPID = 42;
    const independent = watch();
    const result = judgeEpisode({ before, after, goals, foregroundWatch: independent });
    assert.equal(independent.targetActivations, 0);
    assert.equal(result.positiveFixtureActivation, true); assert.equal(result.strictCompletion, false); assert.equal(result.outcome, "failed");
  }
  const before = state(), after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new"; after.activationCount = null;
  assert.equal(judgeWithRequiredWatch({ before, after, goals }).strictCompletion, null);
  assert.equal(judgeEpisode({ before, after, goals }).strictCompletion, true);
});
test("the final monitor stop can downgrade a pass and later gaps cannot erase a known activation", () => {
  const before = state(), after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
  const initial = watch(), preCleanup = watch({ finishedForegroundPID: 100 }), final = watch({ targetActivations: 1, finishedForegroundPID: 99 });
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: mergeForegroundWatches([initial, preCleanup], 42) }).strictCompletion, true);
  const late = mergeForegroundWatches([initial, preCleanup, final], 42);
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: late }).strictCompletion, false);
  const sampledTransition = mergeForegroundWatches([initial, watch({ finishedForegroundPID: 42 }), preCleanup], 42);
  assert.equal(sampledTransition.targetActivations, 0); // Preserve the counter; retain the independent endpoint witness separately.
  assert.equal(sampledTransition.observedTargetForegroundTransition, true);
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: sampledTransition }).strictCompletion, false);
  const failedStop = { targetPID: 42, available: false, truncated: false };
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: mergeForegroundWatches([initial, preCleanup, failedStop], 42) }).strictCompletion, null);
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: mergeForegroundWatches([initial, final, failedStop], 42) }).strictCompletion, false);
  assert.equal(judgeEpisode({ before, after, goals, foregroundWatch: mergeForegroundWatches([initial, failedStop, preCleanup], 42) }).strictCompletion, null);
});
test("independent completion rejects protected state changes, lost controls and false model claims", () => {
  const before = state(), after = state();
  let judgment = judgeEpisode({ before, after, goals, modelClaim: "complete" });
  assert.equal(judgment.falseCompletionClaim, true); assert.equal(completionGate(judgment).accepted, false);
  after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
  before.windows[1].controls[0].selection = { location: 0, length: 0 };
  after.windows[1].controls[0].selection = { length: 0, location: 0 };
  assert.equal(judgeEpisode({ before, after, goals }).strictCompletion, true);
  for (const change of [s => s.windows[1].controls.pop(), s => { s.windows[1].controls[0].enabled = false; }, s => { s.windows[1].controls[0].attached = false; }]) {
    const modified = structuredClone(after); change(modified);
    judgment = judgeEpisode({ before, after: modified, goals, modelClaim: "complete" });
    assert.equal(judgment.protectedStatePreserved, false); assert.equal(completionGate(judgment).accepted, false);
  }
});
test("infrastructure failures cannot masquerade as intended stale-target refusals", () => {
  assert.equal(intendedRefusal({ isError: true, structuredContent: { body: { result: "error", data: { code: "nativeFailed" } } } }), false);
  assert.equal(intendedRefusal({ isError: true, content: [{ type: "text", text: '{"code":"TOOL_FAILED"}' }] }), false);
  assert.equal(intendedRefusal({ isError: true, structuredContent: { body: { result: "error", data: { code: "staleElement" } } } }), true);
  assert.equal(intendedRefusal({ isError: true, structuredContent: { body: { result: "error", data: { code: "targetNotFound" } } } }, "ambiguous"), false);
  const before = state();
  assert.equal(judgeEpisode({ before, after: before, goals, refusalExpected: true, refusalObserved: false }).correctRefusal, false);
});
test("oracle catches sibling input, recreated control redirection and button side effects", () => {
  const before = state(); const after = state(); after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new"; after.windows[0].controls[0].attempts++;
  assert.equal(judgeEpisode({ before, after, goals }).strictCompletion, true);
  after.windows[1].controls[1].attempts++;
  assert.equal(judgeEpisode({ before, after, goals }).wrongTargetDispatch, true);
  const recreated = state(); recreated.windows[0].controls[0].generation = 2; recreated.windows[0].controls[0].attempts = 1;
  assert.equal(judgeEpisode({ before, after: recreated, goals, origin: before }).wrongTargetDispatch, true);
  const pressed = state(); pressed.windows[1].pressCount = 1;
  assert.equal(judgeEpisode({ before, after: pressed, goals }).wrongTargetDispatch, true);
});
test("an ignored write can pass honest conformance without strict goal completion", () => {
  const before = state(), after = state(); after.windows[0].controls[0].attempts = 1;
  const result = judgeEpisode({ before, after, goals, expectedNoncompletion: true });
  assert.equal(result.outcome, "passed"); assert.equal(result.strictCompletion, false); assert.equal(result.correctNoncompletion, true);
  assert.equal(judgeEpisode({ before, after: before, goals, expectedNoncompletion: true }).correctNoncompletion, false);
});
test("endpoint oracle cannot contradict a prefix witness changed by a later composed mutation", () => {
  const before = state(), after = state();
  for (const c of after.windows[0].controls) { c.modelValue = "new"; c.controlValue = "new"; c.attempts = 1; }
  const adapter = new LaneAdapter("rebuild-composed", before, () => {}); adapter.origin = before;
  adapter.refs.set("ref1", { identifier: "primary.first" }); adapter.refs.set("ref2", { identifier: "primary.second" });
  adapter.referenceOracle.set("ref1", { generation: 1, windowGeneration: 1 }); adapter.referenceOracle.set("ref2", { generation: 1, windowGeneration: 1 });
  const condition = (ref, value) => ({ kind: "valueEquals", params: { elementRef: ref, value } });
  const args = { steps: ["ref1", "ref2"].map((elementRef) => ({ operation: { kind: "setValue", params: { elementRef, value: "new" } } })) };
  const step = (actionId, conditions) => ({ actionId, delivery: "dispatched", verification: "confirmed", evidence: conditions.map((condition) => ({ condition, matched: true, observationId: `check-${actionId}` })) });
  const result = { structuredContent: { body: { result: "act", data: { steps: [step("a", [condition("ref1", "new"), condition("ref2", "old")]), step("b", [condition("ref2", "new")])] } } } };
  const claims = adapter.confirmations("act", args, result, after);
  assert.deepEqual(claims.map((c) => c.truth), [true, null, true]);
  assert.equal(claims[1].oracleLimit, "later_step_may_change_witness");
  assert.equal(claims.filter((c) => c.truth === false).length, 0);
});
test("satisfied standalone waits are checked independently and fresh read identity is separate from task origin", () => {
  const before = state(), after = state(); const adapter = new LaneAdapter("rebuild-single", before, () => {}); adapter.origin = before;
  adapter.refs.set("ref", { identifier: "primary.first" }); adapter.referenceOracle.set("ref", { generation: 1, windowGeneration: 1 });
  const args = { condition: { kind: "valueEquals", params: { elementRef: "ref", value: "new" } } };
  const result = { structuredContent: { body: { result: "waitFor", data: { outcome: "satisfied", evidence: { observationId: "check", condition: args.condition,
    matched: true, collected: { startedUnixMs: 1, finishedUnixMs: 2 } } } } } };
  assert.equal(adapter.confirmations("waitFor", args, result, after)[0].truth, false);
  after.windows[0].controls[0].modelValue = "new"; after.windows[0].controls[0].controlValue = "new";
  assert.equal(adapter.confirmations("waitFor", args, result, after)[0].truth, true);
  after.windows[0].controls[0].generation = 2;
  adapter.captureOracle({ structuredContent: { body: { result: "observe", data: { observationId: "fresh", elements: [{ reference: "ref", identifier: "primary.first" }] } } } }, after);
  assert.equal(adapter.confirmations("waitFor", args, result, after)[0].truth, true);
  assert.equal(judgeEpisode({ before, origin: before, after, goals }).strictCompletion, false);
  result.structuredContent.body.data.evidence.collected = null;
  assert.equal(adapter.confirmations("waitFor", args, result, after)[0].truth, null);
});
test("native safety gate and model claims remain separate; blocked lanes and missing repeats stay visible", () => {
  const judged = judgeEpisode({ before: state(), after: state(), goals, claims: [{ truth: false }], modelClaim: "complete" });
  const episodes = [{ lane: "legacy", caseId: "ignored", repeat: 0, ...judged, modelTurns: [] },
    { lane: "rebuild-single", caseId: "ignored", repeat: 0, outcome: "setup_blocked", modelTurns: [] }];
  const summary = summarize(episodes, 3);
  assert.equal(summary.assigned, 2); assert.equal(summary.setupBlocked, 1); assert.equal(summary.falseConfirmations, 1);
  assert.equal(summary.falseCompletionClaims, 1); assert.equal(summary.safetyGate, "blocked");
  assert.equal(summary.repeatConsistency.allPassedRatio, null); assert.equal(summary.model.reportedCostUsd, null);
  const modelOnly = summarize([{ lane: "rebuild-single", caseId: "ignored", repeat: 0,
    ...judgeEpisode({ before: state(), after: state(), goals, modelClaim: "complete" }), modelTurns: [] }], 1);
  assert.equal(modelOnly.falseCompletionClaims, 1); assert.equal(modelOnly.safetyGate, "passed");
  const unjudgeable = summarize([{ lane: "rebuild-single", caseId: "clean", repeat: 0, outcome: "unknown", modelClaim: "complete", modelTurns: [] }], 1);
  assert.equal(unjudgeable.unknownCompletionClaims, 1); assert.equal(unjudgeable.falseCompletionClaims, 0);
});
