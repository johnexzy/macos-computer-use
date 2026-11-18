import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdir, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { openGateway } from "./session-gateway.mjs";
import { runSession, workflowPrompt } from "./session-model.mjs";

// Run the installed Claude CLI against an in-process Messages API test double.
// It receives only a dummy key and a loopback URL. It cannot spend provider credits.
const output = path.resolve(process.argv[2]);
await mkdir(output, { mode: 0o700 });
const configDirectory = path.join(output, "cli-config");
await mkdir(configDirectory, { mode: 0o700 });
const dummyKey = "offline-loopback-test-key";
const model = "claude-sonnet-5";
const calls = [], requests = [];
const lane = { stopped: true, tools: [{ name: "targets", description: "List fixture targets.", inputSchema: { type: "object", properties: {} } }],
  async call(name) {
    calls.push({ name, admitted: !this.stopped });
    return this.stopped ? { content: [{ type: "text", text: "Not admitted" }], isError: true }
      : { content: [{ type: "text", text: "Owned mock fixture" }] };
  } };
const api = createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  const pathname = new URL(request.url, "http://127.0.0.1").pathname;
  requests.push({ path: pathname, dummyKey: request.headers["x-api-key"] === dummyKey });
  if (pathname !== "/v1/messages" || request.headers["x-api-key"] !== dummyKey) {
    response.writeHead(400, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "Unexpected loopback request" } }));
    return;
  }
  const input = JSON.parse(body);
  const returned = input.messages.some(message => Array.isArray(message.content) && message.content.some(item => item.type === "tool_result"));
  const name = input.tools?.find(tool => tool.name === "mcp__workflow__targets")?.name;
  if (!name && !returned) {
    response.writeHead(400, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "Expected scoped MCP tool" } }));
    return;
  }
  const outputBlock = returned ? { type: "text", text: "COMPLETE" } : { type: "tool_use", id: "toolu_loopback_targets", name, input: {} };
  const stopReason = returned ? "end_turn" : "tool_use";
  const usage = { input_tokens: 20, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  const message = { id: `msg_loopback_${requests.length}`, type: "message", role: "assistant", model, content: [outputBlock], stop_reason: stopReason, stop_sequence: null, usage };
  if (!input.stream) {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify(message));
    return;
  }
  const event = (record) => response.write(`event: ${record.type}\ndata: ${JSON.stringify(record)}\n\n`);
  response.writeHead(200, { "Content-Type": "text/event-stream" });
  event({ type: "message_start", message: { ...message, content: [], stop_reason: null, usage: { ...usage, output_tokens: 0 } } });
  event({ type: "content_block_start", index: 0, content_block: returned ? { type: "text", text: "" } : outputBlock });
  event({ type: "content_block_delta", index: 0, delta: returned ? { type: "text_delta", text: "COMPLETE" } : { type: "input_json_delta", partial_json: "{}" } });
  event({ type: "content_block_stop", index: 0 });
  event({ type: "message_delta", delta: { stop_reason: stopReason, stop_sequence: null }, usage });
  event({ type: "message_stop" });
  response.end();
});

api.listen(0, "127.0.0.1");
await once(api, "listening");
const gateway = await openGateway(lane);
try {
  const result = await runSession({ binary: "claude", env: { PATH: process.env.PATH, HOME: process.env.HOME, CLAUDE_CONFIG_DIR: configDirectory,
    ANTHROPIC_API_KEY: dummyKey, ANTHROPIC_BASE_URL: `http://127.0.0.1:${api.address().port}` }, cwd: output,
    model, tools: lane.tools, config: gateway.config, prompt: workflowPrompt("settings"), budgetUsd: 1, turns: 4, timeoutMs: 20000,
    authMode: process.argv[3],
    onReady: () => { lane.stopped = false; }, onStop: () => { lane.stopped = true; } });
  await writeFile(path.join(output, "report.json"), JSON.stringify({ mode: "installed_cli_loopback_api", providerCalls: 0, result, calls, requests }, null, 2), { mode: 0o600 });
  assert.equal(result.ok, true, JSON.stringify({ ...result, records: undefined, args: undefined }));
  assert.deepEqual(calls, [{ name: "targets", admitted: true }]);
  assert.equal(requests.filter(request => request.path === "/v1/messages" && request.dummyKey).length, 2);
  console.log(JSON.stringify({ actualClaudeCli: true, loopbackRequests: requests.length, calls, providerCalls: 0, sessionId: result.sessionId, turns: result.numTurns }));
} finally {
  await gateway.close();
  api.closeAllConnections();
  await new Promise(resolve => api.close(resolve));
}
