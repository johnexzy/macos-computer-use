// Live capture is confined to a disposable fixture. The test retains no bitmaps.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { Fixture } from "../fixtures/macos/client.mjs";
import { Session } from "./mcp-session.mjs";

const session = new Session(["--allow-foreground"]);
const fixture = new Fixture();
const bundleId = "com.johnoba.cua.fixture";
const primary = (state) => state.windows.find((win) => win.key === "primary");

async function tool(name, args = {}) {
  const call = (await session.tool(name, args)).result;
  assert.ok(call, `Missing MCP tool result for ${name}`);
  return call;
}

function body(result, method) {
  const body = result.structuredContent?.body;
  assert.equal(body?.result, method, body?.data?.message);
  return body.data;
}

async function currentBounds(target, match = () => true) {
  let seen;
  for (let tries = 0; tries < 25; tries++) {
    const { targets } = body(await tool("targets", { bundleId }), "targets");
    const found = targets.find(({ key }) => key.pid === target.pid && key.windowId === target.windowId);
    seen = found?.bounds;
    if (seen && match(seen)) return seen;
    await pause(50);
  }
  assert.fail(`Fixture window catalog did not settle. Last bounds: ${JSON.stringify(seen)}`);
}

function near(a, b) {
  assert.ok(Math.abs(a - b) < 1e-6, `Expected ${a} to equal ${b}`);
}

function checkFrame(observation, expectedBounds) {
  const { visual } = observation;
  assert.equal(visual.captureStatus, "captured");
  assert.equal(visual.geometryMatchesAX, true);
  const frame = visual.frame;
  const whole = { x: 0, y: 0, width: frame.widthPx, height: frame.heightPx };
  assert.deepEqual(frame.captureWindowBounds, expectedBounds);
  for (const [axis, size] of [["X", "width"], ["Y", "height"]]) {
    const origin = axis.toLowerCase();
    const scale = `scale${axis}`, offset = `offset${axis}`;
    near(frame.imageToScreen[scale] * whole[size], frame.captureScreenBounds[size]);
    near(frame.imageToScreen[offset], frame.captureScreenBounds[origin]);
    near(frame.imageToWindow[scale], frame.imageToScreen[scale]);
    near(frame.imageToWindow[offset], frame.imageToScreen[offset] - expectedBounds[origin]);
  }
  assert.deepEqual(frame.imageToWindow.validImageBounds, whole);
  assert.deepEqual(frame.imageToScreen.validImageBounds, whole);
  assert.ok(observation.accessibilityCollected.finishedUnixMs <= visual.collected.startedUnixMs);
  return frame;
}

async function checkImage(result, observation, frame) {
  const image = result.content.find((item) => item.type === "image");
  assert.equal(image?.mimeType, "image/jpeg");
  assert.equal(observation.screenshot.dataBase64, undefined);
  assert.ok(result.content.filter((block) => block.type === "text").every(({ text }) => !text.includes("dataBase64")));
  const dir = await mkdtemp(join(tmpdir(), "cua-visual-fixture-"));
  try {
    const path = join(dir, "fixture.jpg");
    await writeFile(path, Buffer.from(image.data, "base64"), { mode: 0o600 });
    const dimensions = execFileSync("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", path], { encoding: "utf8" });
    assert.equal(Number(dimensions.match(/pixelWidth: (\d+)/)?.[1]), frame.widthPx);
    assert.equal(Number(dimensions.match(/pixelHeight: (\d+)/)?.[1]), frame.heightPx);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function run() {
  await session.initialize();
  const initial = await fixture.ready;
  const target = { pid: initial.pid, windowId: primary(initial).windowId };
  assert.notEqual(initial.foregroundPID, initial.pid);
  const capabilities = await tool("capabilities");
  const permissions = body(capabilities, "capabilities").permissions;
  await fixture.call("configure", { control: "first", value: "Cobalt Widget" });
  const bounds = await currentBounds(target);
  const semantic = body(await tool("observe", { target }), "observe");
  assert.equal(semantic.visual, undefined);
  assert.equal(semantic.screenshot, null);
  const fullResult = await tool("observe", { target, includeScreenshot: true, includeOcr: true, ocrQuery: "Cobalt" });
  const full = body(fullResult, "observe");
  const macOS = Number(execFileSync("/usr/bin/sw_vers", ["-productVersion"], { encoding: "utf8" }).split(".")[0]);
  if (macOS < 14 || !permissions.screenRecording) {
    assert.equal(full.visual.captureStatus, macOS < 14 ? "unsupported" : "permission_denied");
    assert.equal(full.visual.ocr.status, "unavailable");
    assert.equal(full.screenshot, null);
    assert.ok(fullResult.content.every((item) => item.type !== "image"));
    return { captureStatus: full.visual.captureStatus };
  }
  const frame = checkFrame(full, bounds);
  await checkImage(fullResult, full, frame);
  const field = full.elements.find(({ identifier }) => identifier === "primary.first");
  assert.ok(field, "Fixture field must be independently visible via AX");
  assert.equal(field.value, null);
  const [hit] = full.visual.ocr.matches;
  assert.equal(full.visual.ocr.status, "complete");
  assert.equal(hit?.text.toLowerCase(), "cobalt");
  assert.ok(full.visual.ocr.collected.startedUnixMs >= full.visual.collected.finishedUnixMs);
  const css = frame.imageToScreen;
  const x = (hit.imageBounds.x + hit.imageBounds.width / 2) * css.scaleX + css.offsetX;
  const y = (hit.imageBounds.y + hit.imageBounds.height / 2) * css.scaleY + css.offsetY;
  assert.ok(x >= field.bounds.x && x < field.bounds.x + field.bounds.width, "OCR center must map inside the field horizontally");
  assert.ok(y >= field.bounds.y && y < field.bounds.y + field.bounds.height, "OCR center must map inside the field vertically");

  const crop = { x: 12.25, y: 10.25, width: 280, height: 135 };
  const ocrResult = await tool("observe", { target, includeOcr: true, ocrQuery: "Cobalt", cropWindow: crop, maxImageDimensionPx: 512 });
  const ocr = body(ocrResult, "observe");
  const cropped = checkFrame(ocr, bounds);
  assert.equal(ocr.screenshot, null);
  assert.ok(ocrResult.content.every((item) => item.type !== "image"));
  assert.equal(ocr.visual.ocr.matches[0]?.text.toLowerCase(), "cobalt");
  assert.ok(cropped.captureScreenBounds.width < bounds.width && cropped.captureScreenBounds.height < bounds.height);
  assert.ok(Math.max(cropped.widthPx, cropped.heightPx) <= 512);
  assert.ok(Math.abs(cropped.imageToWindow.offsetX - crop.x) <= cropped.imageToWindow.scaleX);
  assert.ok(Math.abs(cropped.imageToWindow.offsetY - crop.y) <= cropped.imageToWindow.scaleY);

  const resized = await fixture.call("configure", { frame: { x: 180, y: 140, width: 390, height: 500 } });
  assert.notDeepEqual(primary(initial).frame, primary(resized).frame);
  const resizedWindow = primary(resized).frame;
  const movedBounds = await currentBounds(target, (bounds) =>
    bounds.width === resizedWindow.width && bounds.height === resizedWindow.height);
  assert.notDeepEqual(movedBounds, bounds);
  const portraitResult = await tool("observe", { target, includeScreenshot: true, maxImageDimensionPx: 360 });
  const portrait = body(portraitResult, "observe");
  const resizedFrame = checkFrame(portrait, movedBounds);
  assert.ok(resizedFrame.heightPx > resizedFrame.widthPx && resizedFrame.heightPx <= 360);
  await checkImage(portraitResult, portrait, resizedFrame);
  assert.equal(portrait.visual.ocr, null);

  for (const observationId of [full.observationId, portrait.observationId]) {
    const click = { actionId: "image-click", operation: { kind: "click", params: { point: { x: 30, y: 80 }, space: "imagePixels" } } };
    const refusal = body(await tool("act", { observationId, target, steps: [click] }), "act");
    assert.equal(refusal.steps[0].delivery, "not_dispatched");
  }
  const final = await fixture.call("state");
  assert.equal(final.foregroundPID, initial.foregroundPID);
  assert.equal(final.activationCount, initial.activationCount);
  assert.equal(primary(final).pressCount, primary(initial).pressCount);
  return { captureStatus: full.visual.captureStatus, full: [frame.widthPx, frame.heightPx],
    cropped: [cropped.widthPx, cropped.heightPx], portrait: [resizedFrame.widthPx, resizedFrame.heightPx],
    substringMappedInsideFixtureField: true, coordinateClicksRefused: 2, fixtureActivations: 0 };
}

try {
  console.log(JSON.stringify(await run()));
} finally {
  await Promise.all([fixture.close(), session.close()]);
}
