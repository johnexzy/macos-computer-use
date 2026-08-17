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

async function withClient(run) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(repoDir, "server.mjs")],
    cwd: repoDir,
    stderr: "pipe",
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

test("invalid AppleScript is an MCP error", async () => {
  await withClient(async (client) => {
    const result = await client.callTool({
      name: "run_applescript",
      arguments: { script: "this is intentionally invalid AppleScript syntax" },
    });

    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /APPLESCRIPT_FAILED/);
  });
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

test("live cursor overlay accepts movement and feedback commands", { timeout: 5000 }, async () => {
  const helper = path.join(repoDir, "native_helper");
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
