import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const execFileAsync = promisify(execFile);

async function withClient(run, { unsafe = false } = {}) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(repoDir, "server.mjs")],
    cwd: repoDir,
    stderr: "pipe",
    env: {
      ...process.env,
      MACOS_COMPUTER_USE_UNSAFE: unsafe ? "1" : "0",
    },
  });
  const client = new Client({ name: "macos-computer-use-tests", version: "1.0.0" });
  await client.connect(transport);
  try {
    return await run(client);
  } finally {
    await client.close();
  }
}

test("invalid window screenshot fails closed without returning an image", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "screenshot",
      arguments: { windowId: 999999999, format: "png", maxWidth: 100 },
    });

    assert.equal(result.isError, true);
    assert.equal(result.content.some((item) => item.type === "image"), false);
    assert.match(result.content[0].text, /TARGET_NOT_FOUND/);
  });
});

test("invalid AppleScript is an MCP error when unsafe mode is enabled", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "run_applescript",
      arguments: { script: "this is intentionally invalid AppleScript syntax" },
    });

    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /APPLESCRIPT_FAILED/);
  }, { unsafe: true });
});

test("relative coordinates require an explicit target", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "mouse_click",
      arguments: { x: 10, y: 10, relativeCoords: true },
    });

    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /INVALID_TARGET/);
  });
});

test("background automation exposes semantic Accessibility tools", async () => {
  await withClient(async (client) => {
    const result = await client.listTools();
    const names = new Set(result.tools.map((tool) => tool.name));

    assert.equal(names.has("inspect_accessibility"), true);
    assert.equal(names.has("wait_for_accessibility"), true);
    assert.equal(names.has("set_accessibility_value"), true);
    assert.equal(names.has("perform_accessibility_action"), true);
    assert.equal(names.has("get_capabilities"), true);
    assert.equal(names.has("run_applescript"), false);

    for (const tool of result.tools) {
      assert.equal(typeof tool.annotations?.readOnlyHint, "boolean", `${tool.name} readOnlyHint`);
      assert.equal(typeof tool.annotations?.destructiveHint, "boolean", `${tool.name} destructiveHint`);
      assert.equal(typeof tool.annotations?.idempotentHint, "boolean", `${tool.name} idempotentHint`);
      assert.equal(typeof tool.annotations?.openWorldHint, "boolean", `${tool.name} openWorldHint`);
    }

    const perform = result.tools.find((tool) => tool.name === "perform_accessibility_action");
    const launch = result.tools.find((tool) => tool.name === "launch_app");
    assert.equal(perform.inputSchema.properties.action.enum.includes("focus"), true);
    assert.equal(launch.inputSchema.properties.activate.default, false);
  });
});

test("capability inspection is read-only and does not request permission", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({ name: "get_capabilities", arguments: {} });
    assert.equal(result.isError, undefined, JSON.stringify(result));

    const capabilities = JSON.parse(result.content[0].text);
    assert.equal(capabilities.status, "ok");
    assert.equal(capabilities.permissionPromptRequested, false);
    assert.equal(typeof capabilities.permissions.accessibility, "boolean");
    assert.equal(typeof capabilities.permissions.screenRecording, "boolean");
    assert.equal(typeof capabilities.permissions.inputPosting, "boolean");
    assert.equal(capabilities.policy.unsafeMode, false);
    assert.equal(capabilities.policy.globalInputEnabled, false);
    assert.equal(capabilities.policy.appleScriptEnabled, false);
    assert.equal(capabilities.policy.foregroundActivationEnabled, false);
  });
});

test("unsafe tools and global input require explicit opt-in", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "press_key",
      arguments: { key: "return", executionMode: "foreground_allowed" },
    });
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /UNSAFE_MODE_REQUIRED/);

    const activation = await client.callTool({
      name: "launch_app",
      arguments: { appName: "Finder", activate: true },
    });
    assert.equal(activation.isError, true);
    assert.match(activation.content[0].text, /UNSAFE_MODE_REQUIRED/);

    const failure = JSON.parse(result.content[0].text);
    assert.equal(failure.status, "error");
    assert.equal(failure.execution.contractVersion, 1);
    assert.equal(failure.execution.accepted, false);
  });

  await withClient(async (client) => {
    const tools = await client.listTools();
    assert.equal(tools.tools.some((tool) => tool.name === "run_applescript"), true);
    const capabilities = await client.callTool({ name: "get_capabilities", arguments: {} });
    assert.equal(JSON.parse(capabilities.content[0].text).policy.unsafeMode, true);
  }, { unsafe: true });
});

test("background-required key presses fail closed without a target", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "press_key",
      arguments: { key: "return", executionMode: "background_required" },
    });

    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /BACKGROUND_TARGET_REQUIRED/);
  });
});

test("semantic waits fail closed without a target", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "wait_for_accessibility",
      arguments: { selector: { role: "AXButton" }, timeoutMs: 100 },
    });

    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /BACKGROUND_TARGET_REQUIRED/);
  });
});

test("word matching excludes substrings and preserves duplicate occurrences", async () => {
  const helper = path.join(repoDir, "native_helper");
  const excluded = JSON.parse(
    (await execFileAsync(helper, ["match_text", "Test macOS computer-use MCP", "AC", "word"]))
      .stdout,
  );
  const exact = JSON.parse(
    (await execFileAsync(helper, ["match_text", "AC", "AC", "word"])).stdout,
  );
  const duplicates = JSON.parse(
    (await execFileAsync(helper, ["match_text", "Duplicate Duplicate", "Duplicate", "word"]))
      .stdout,
  );

  assert.equal(excluded.count, 0);
  assert.deepEqual(exact.types, ["exact"]);
  assert.equal(duplicates.count, 2);
  assert.deepEqual(duplicates.types, ["word", "word"]);
});

test("live cursor overlay accepts movement and feedback commands", { timeout: 5000 }, async (context) => {
  const helper = path.join(repoDir, "native_helper");
  const frontmost = JSON.parse((await execFileAsync(helper, ["frontmost_app"])).stdout);
  if (frontmost.bundleIdentifier === "com.apple.loginwindow") {
    context.skip("live cursor overlay requires an unlocked interactive desktop session");
    return;
  }
  const display = JSON.parse((await execFileAsync(helper, ["size"])).stdout);
  const child = spawn(helper, ["cursor_overlay"], { stdio: ["pipe", "pipe", "pipe"] });
  const reader = createInterface({ input: child.stdout });
  const messages = [];
  const waiters = [];

  reader.on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else messages.push(message);
  });

  const nextMessage = () => {
    if (messages.length > 0) return Promise.resolve(messages.shift());
    return new Promise((resolve) => waiters.push(resolve));
  };
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);

  try {
    assert.deepEqual(await nextMessage(), { status: "ready" });

    send({
      id: "move",
      action: "move",
      x: display.width / 2,
      y: display.height / 2,
      durationMs: 0,
    });
    assert.deepEqual(await nextMessage(), {
      id: "move",
      status: "ok",
      action: "move",
      visible: true,
    });

    send({ id: "click", action: "click" });
    assert.deepEqual(await nextMessage(), { id: "click", status: "ok", action: "click" });

    send({ id: "offscreen", action: "move", x: -999999, y: -999999, durationMs: 0 });
    assert.deepEqual(await nextMessage(), {
      id: "offscreen",
      status: "error",
      action: "move",
      visible: false,
      error: "Target coordinate is outside connected displays",
    });

    send({ id: "hide", action: "hide" });
    assert.deepEqual(await nextMessage(), { id: "hide", status: "ok", action: "hide" });

    send({ id: "quit", action: "quit" });
    assert.deepEqual(await nextMessage(), { id: "quit", status: "ok", action: "quit" });
    await once(child, "exit");
  } finally {
    reader.close();
    if (child.exitCode === null) child.kill();
  }
});
