import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { parseCommand, parseResult, claudeArguments, claudeEnvironment, ModelBudget, apiKeyEnvironment, invokeClaude, preflightClaude } from "./model.mjs";
import { judgeEpisode, summarize, usageSummary } from "./metrics.mjs";
import { intendedRefusal, validateFixtureCommand, validateOriginalMutation, laneTools, LaneAdapter } from "./adapters.mjs";

const command = { kind: "finish", tool: "", argsJson: "{}", claim: "incomplete", reason: "Stopped" };
const response = (extra = {}) => JSON.stringify({ type: "result", subtype: "success", is_error: false,
  modelUsage: { "claude-sonnet-specific": { inputTokens: 10, outputTokens: 2, cacheReadInputTokens: 3, cacheCreationInputTokens: 4 } },
  usage: { input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4 }, total_cost_usd: 0.01,
  structured_output: command, ...extra });
const state = () => ({ pid: 42, foregroundPID: 99, activationCount: 0, windows: ["primary", "secondary"].map((window, i) => ({ key: window, windowId: 7 + i, generation: 1, pressCount: 0,
  controls: ["first", "second"].map((key) => ({ key, identifier: `${window}.${key}`, generation: 1, modelValue: "old", controlValue: "old", attempts: 0 })) })) });
const goals = [{ identifier: "primary.first", value: "new" }];

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
  const args = { target: { pid: 42, windowId: 7 }, budgetMs: 3000, steps: [1, 2].map((i) => ({ operation: { kind: "setValue", params: { elementRef: `ref${i}`, value: "new" } } })) };
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
  args.steps.push({ operation: { kind: "waitFor", params: { condition: { kind: "valueEquals", params: { elementRef: "ref2", value: "new" } } } } });
  assert.doesNotThrow(() => validateFixtureCommand("rebuild-composed", "act", args, fixture, new Set(["ref1", "ref2"])));
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
