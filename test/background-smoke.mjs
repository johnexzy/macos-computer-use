import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const targetApp = process.argv[2] || "Calculator";
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(repoDir, "server.mjs")],
  cwd: repoDir,
  stderr: "pipe",
});
const client = new Client({ name: "macos-computer-use-background-smoke", version: "1.0.0" });

function textJson(result) {
  const text = result.content.find((item) => item.type === "text")?.text;
  assert.ok(text, "tool result should contain text");
  return JSON.parse(text);
}

await client.connect(transport);
try {
  const before = textJson(await client.callTool({ name: "get_active_app", arguments: {} }));
  assert.notEqual(before.activeApp, targetApp, `${targetApp} must start in the background`);

  const launch = await client.callTool({
    name: "launch_app",
    arguments: { appName: targetApp, activate: false },
  });
  assert.equal(launch.isError, undefined, JSON.stringify(launch));
  const launchPayload = textJson(launch);
  assert.equal(launchPayload.execution.contractVersion, 1);
  assert.equal(launchPayload.execution.accepted, true);
  assert.equal(launchPayload.execution.verification, "window_observed");
  assert.equal(launchPayload.execution.foregroundPreserved, true);

  const inspected = await client.callTool({
    name: "inspect_accessibility",
    arguments: {
      appName: targetApp,
      roles: ["AXTextField", "AXTextArea", "AXSearchField", "AXButton"],
      maxResults: 100,
    },
  });
  assert.equal(inspected.isError, undefined, JSON.stringify(inspected));
  assert.ok(textJson(inspected).elements.length > 0, `${targetApp} should expose actionable controls`);

  const waited = await client.callTool({
    name: "wait_for_accessibility",
    arguments: {
      appName: targetApp,
      selector: { role: "AXButton" },
      timeoutMs: 2000,
    },
  });
  assert.equal(waited.isError, undefined, JSON.stringify(waited));
  assert.ok(textJson(waited).elements.length > 0, `${targetApp} should expose a button`);

  const after = textJson(await client.callTool({ name: "get_active_app", arguments: {} }));
  assert.equal(after.activeApp, before.activeApp, "background inspection must preserve the frontmost app");

  console.log(`Background smoke passed: ${targetApp} remained backgrounded and exposed controls.`);
} finally {
  await client.close();
}
