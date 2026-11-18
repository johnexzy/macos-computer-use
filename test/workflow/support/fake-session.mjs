import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { data, payload } from "../../evaluation/adapters.mjs";

// A deterministic test process. It reads through the same MCP connection as the
// CLI would, with no provider transport and no access to the fixture oracle.
const args = process.argv.slice(2);
const option = name => args[args.indexOf(name) + 1];
const config = JSON.parse(option("--mcp-config"));
assert.deepEqual(Object.keys(config.mcpServers), ["workflow"]);
assert.equal(option("--tools"), "");
assert.ok(args.includes("--bare") && args.includes("--strict-mcp-config"));
const model = option("--model");
let prompt = "";
for await (const chunk of process.stdin) prompt += chunk;
assert.ok(prompt.includes("Workflow Settings"));
const client = new Client({ name: "fake-workflow-cli", version: "1" });
await client.connect(new StdioClientTransport(config.mcpServers.workflow));
const { tools } = await client.listTools();
const sessionId = `mock-${process.pid}`;
const emit = entry => console.log(JSON.stringify({ session_id: sessionId, ...entry }));
emit({ type: "system", subtype: "init", model, tools: tools.map(t => `mcp__workflow__${t.name}`),
  mcp_servers: [{ name: "workflow", status: "connected" }], plugins: [] });
let calls = 0;
async function call(name, args = {}) {
  calls++;
  emit({ type: "assistant", message: { content: [{ type: "tool_use", name: `mcp__workflow__${name}`, input: args }] } });
  const result = await client.callTool({ name, arguments: args });
  emit({ type: "user", message: { content: [{ type: "tool_result", is_error: Boolean(result.isError) }] } });
  return result;
}
const legacy = tools.some(t => t.name === "list_windows");
const single = tools.find(t => t.name === "act")?.inputSchema.properties.steps.maxItems === 1;
const list = await call(legacy ? "list_windows" : "targets");
const windows = legacy ? payload(list).map(w => ({ ...w, key: { pid: w.pid, windowId: w.windowId } })) : data(list).targets;
assert.equal(windows.length, 2);
const source = windows.find(window => window.title === "Settings Specification").key;
const work = windows.find(window => window.title === "Workflow Settings").key;
const invalid = legacy ? await call("inspect_accessibility", { windowId: 4294967295 }) : await call("observe", { target: { pid: 1, windowId: 1 } });
assert.equal(payload(invalid).delivery, "not_dispatched");
const observe = async (target) => {
  const result = legacy ? await call("inspect_accessibility", { windowId: target.windowId, includeValues: true })
    : await call("observe", { target, includeValues: true, budgetMs: 3000 });
  assert.ok(!result.isError, JSON.stringify(result));
  return legacy ? payload(result) : data(result);
};
const element = (observed, id) => observed.elements.find(e => e.identifier === id);
const spec = element(await observe(source), "source.instructions").value;
const pages = spec.split("\n\n").slice(0, 3).map(page => page.split("\n").slice(1).map(line => line.slice(line.indexOf(": ") + 2)));
const mutate = async (observed, changes, target = work) => {
  if (legacy) {
    const [{ control, value }] = changes;
    return value === undefined ? call("perform_accessibility_action", { windowId: target.windowId, selector: { identifier: control.identifier }, action: "press" })
      : call("set_accessibility_value", { windowId: target.windowId, selector: { identifier: control.identifier }, value });
  }
  return call("act", { target, observationId: observed.observationId, budgetMs: 3000, steps: changes.map(({ control, value }) => ({
    actionId: control.identifier,
    operation: value === undefined ? { kind: "press", params: { elementRef: control.reference } }
      : { kind: "setValue", params: { elementRef: control.reference, value } },
  })) });
};

try {
  for (const [page, settings] of pages.entries()) {
    let snapshot = await observe(work);
    if (page) {
      const switched = await mutate(snapshot, [{ control: element(snapshot, `settings.tab.${page}`) }]);
      assert.ok(!switched.isError, JSON.stringify(switched));
      snapshot = await observe(work);
    }
    const changes = settings.flatMap((setting, i) => {
      const control = element(snapshot, `settings.${page * 5 + i}`);
      const checkbox = control.role === "AXCheckBox";
      const expected = checkbox ? String(Number(setting === "On")) : setting;
      return String(control.value) === expected ? [] : [{ control, value: checkbox ? undefined : expected }];
    });
    for (const batch of legacy || single ? changes.map(change => [change]) : [changes]) {
      const result = await mutate(snapshot, batch);
      assert.ok(!result.isError, JSON.stringify(result));
      if (legacy) assert.ok(!payload(result).foreground.before && !payload(result).foreground.after);
      else assert.equal(data(result).stopReason, "completed");
    }
    if (process.env.FAKE_WORKFLOW_CASE === "incomplete") break;
    const final = await observe(work);
    const firstText = changes.find(({ value }) => value !== undefined);
    const replay = await mutate(final, [{ ...firstText, control: element(final, firstText.control.identifier) }]);
    assert.equal(payload(replay).delivery, "not_dispatched");
  }
  if (process.env.FAKE_WORKFLOW_CASE === "decoy") {
    const snapshot = await observe(source);
    const edited = await mutate(snapshot, [{ control: element(snapshot, "source.notes"), value: "Edited the wrong fixture control" }], source);
    assert.equal(data(edited).stopReason, "completed");
  }
} finally { await client.close(); }

emit({ type: "result", subtype: "success", is_error: false, result: "COMPLETE", num_turns: calls, total_cost_usd: 0.07,
  usage: { input_tokens: 999 }, modelUsage: { [model]: { inputTokens: 30, outputTokens: 10, cacheReadInputTokens: 20, cacheCreationInputTokens: 25 } } });
