import assert from "node:assert/strict";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(repoDir, "server.mjs")],
  cwd: repoDir,
  stderr: "pipe",
});
const client = new Client({ name: "macos-computer-use-live-smoke", version: "1.0.0" });

function textJson(result) {
  const text = result.content.find((item) => item.type === "text")?.text;
  assert.ok(text, "tool result should contain text");
  return JSON.parse(text);
}

async function call(name, args = {}) {
  return client.callTool({ name, arguments: args });
}

async function listTextEditWindows() {
  return textJson(await call("list_windows", { appName: "TextEdit" })).filter(
    (window) => window.title,
  );
}

async function waitForNewTextEditWindow(existingIds) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const created = (await listTextEditWindows()).find(
      (window) => !existingIds.has(window.windowId),
    );
    if (created) return created;
    await delay(100);
  }
  assert.fail("TextEdit did not expose the new test window");
}

const suffix = Date.now().toString().slice(-6);
const testPrefix = `MCP-LIVE-${suffix}`;
const ambiguousToken = `AMBIG-${suffix}`;

await client.connect(transport);
try {
  await call("launch_app", { appName: "Calculator" });
  const calculatorWindows = textJson(await call("list_windows", { appName: "Calculator" })).filter(
    (window) => window.title,
  );
  assert.ok(calculatorWindows.length > 0, "Calculator window should be open");
  const mismatch = await call("screenshot", {
    appName: "TextEdit",
    windowId: calculatorWindows[0].windowId,
    maxWidth: 100,
  });
  assert.equal(mismatch.isError, true);
  assert.equal(mismatch.content.some((item) => item.type === "image"), false);
  assert.match(mismatch.content[0].text, /TARGET_MISMATCH/);

  await call("type_text", { windowId: calculatorWindows[0].windowId, text: "9" });
  const digitResult = await call("click_text", {
    text: "7",
    appName: "Calculator",
    matchMode: "exact",
  });
  assert.equal(digitResult.isError, undefined, JSON.stringify(digitResult));
  const digitPayload = textJson(digitResult);
  assert.equal(digitPayload.action.action, "AXPress");
  assert.equal(digitPayload.cursorOverlay.status, "ok");
  const clearResult = await call("mouse_click", {
    windowId: calculatorWindows[0].windowId,
    x: 502,
    y: 158,
    relativeCoords: true,
  });
  assert.equal(clearResult.isError, undefined, JSON.stringify(clearResult));
  const clearPayload = textJson(clearResult);
  assert.equal(clearPayload.action.action, "AXPress");
  assert.equal(clearPayload.cursorOverlay.status, "ok");
  const cleared = textJson(
    await call("find_text", { text: "AC", appName: "Calculator", matchMode: "exact" }),
  );
  assert.equal(cleared.found, true);
  const globalAC = textJson(await call("find_text", { text: "AC", matchMode: "word" }));
  assert.equal(globalAC.found, true);
  assert.equal(
    globalAC.allMatches.some((match) => match.text.toLocaleLowerCase().includes("macos")),
    false,
  );

  const existingWindowIds = new Set((await listTextEditWindows()).map((window) => window.windowId));
  await call("run_applescript", {
    script: `tell application "TextEdit" to make new document with properties {text:"${testPrefix}-A ${ambiguousToken} ${ambiguousToken}"}`,
  });
  const windowA = await waitForNewTextEditWindow(existingWindowIds);
  existingWindowIds.add(windowA.windowId);
  await call("run_applescript", {
    script: `tell application "TextEdit" to make new document with properties {text:"${testPrefix}-B"}`,
  });
  const windowB = await waitForNewTextEditWindow(existingWindowIds);
  await call("launch_app", { appName: "Calculator" });

  const ambiguousClick = await call("click_text", {
    windowId: windowA.windowId,
    text: ambiguousToken,
    matchMode: "word",
  });
  assert.equal(ambiguousClick.isError, true);
  assert.match(ambiguousClick.content[0].text, /AMBIGUOUS_TEXT/);

  const tokenA = `LIVE-A-${suffix}`;
  const tokenB = `LIVE-B-${suffix}`;
  await call("type_text", { windowId: windowA.windowId, text: ` ${tokenA}` });
  await call("type_text", { windowId: windowB.windowId, text: ` ${tokenB}` });
  const documentDump = (
    await call("run_applescript", {
      script: `tell application "TextEdit"
set resultA to "missing"
set resultB to "missing"
repeat with d in documents
set bodyText to text of d as string
if bodyText contains "${testPrefix}-A" then set resultA to ((bodyText contains "${tokenA}") as string) & tab & ((bodyText contains "${tokenB}") as string)
if bodyText contains "${testPrefix}-B" then set resultB to ((bodyText contains "${tokenA}") as string) & tab & ((bodyText contains "${tokenB}") as string)
end repeat
return resultA & linefeed & resultB
end tell`,
    })
  ).content[0].text;
  assert.equal(documentDump, "true\tfalse\nfalse\ttrue");

  const settingsWindows = textJson(await call("list_windows", { appName: "System Settings" })).filter(
    (window) => window.title,
  );
  assert.ok(settingsWindows.length > 0, "System Settings window should be open");
  const settings = settingsWindows[0];
  const scrollResult = await call("scroll", {
    windowId: settings.windowId,
    x: 150,
    y: 760,
    relativeCoords: true,
    deltaY: -640,
  });
  assert.equal(scrollResult.isError, undefined, JSON.stringify(scrollResult));
  assert.equal(textJson(scrollResult).cursorOverlay.status, "ok");
  const privacy = textJson(
    await call("find_text", {
      windowId: settings.windowId,
      text: "Privacy & Security",
      matchMode: "word",
    }),
  );
  assert.equal(privacy.found, true);

  console.log("Live smoke passed: live cursor, targeted AX click, exact-window typing, and AX scrolling.");
} finally {
  try {
    await call("run_applescript", {
      script: `tell application "TextEdit"
repeat with documentIndex from (count of documents) to 1 by -1
set bodyText to text of document documentIndex as string
if bodyText contains "${testPrefix}" then close document documentIndex saving no
end repeat
end tell`,
    });
  } catch {}
  await client.close();
}
