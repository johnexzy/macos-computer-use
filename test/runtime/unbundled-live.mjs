// Copy the fixture executable outside its bundle. Capture only synthetic fixture content.
import assert from "node:assert/strict";
import { chmod, copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { Fixture } from "../fixtures/macos/client.mjs";
import { Session, root } from "./mcp-session.mjs";

const bundledFixture = join(root, "test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture");
const marker = "Marigold Compass";
const directory = await mkdtemp(join(tmpdir(), "cua-unbundled-fixture-"));
let session;
let fixture;

async function tool(name, args = {}) {
  const response = await session.tool(name, args);
  assert.ok(response.result, JSON.stringify(response.error));
  return response.result;
}

function data(result, method) {
  const body = result.structuredContent?.body;
  assert.equal(body?.result, method, body?.data?.message ?? result.structuredContent?.error?.message);
  return body.data;
}

async function findWindow(target) {
  for (let attempt = 0; attempt < 30; attempt++) {
    const { targets } = data(await tool("targets"), "targets");
    const found = targets.find(({ key }) => key.pid === target.pid && key.windowId === target.windowId);
    if (found) return found;
    await pause(50);
  }
  assert.fail("Unfiltered discovery did not list the unbundled fixture window");
}

async function run() {
  await session.initialize();
  const initial = await fixture.ready;
  const primary = initial.windows.find(({ key }) => key === "primary");
  const target = { pid: initial.pid, windowId: primary.windowId };
  assert.ok(initial.foregroundPID > 0);
  assert.equal(initial.foregroundPID, initial.startedForegroundPID);
  assert.notEqual(initial.foregroundPID, initial.pid);
  assert.equal(initial.activationCount, 0);

  const capabilities = data(await tool("capabilities"), "capabilities");
  assert.equal(capabilities.mode, "backgroundRequired");
  assert.ok(capabilities.permissions.screenRecording, "The live fixture requires Screen Recording");
  await fixture.call("configure", { control: "first", value: marker });

  const found = await findWindow(target);
  assert.equal(found.bundleId ?? null, null, "The executable must run without a bundle ID");
  if (found.ownerName != null) assert.ok(found.ownerName.trim());
  const filtered = data(await tool("targets", { bundleId: "com.johnoba.cua.fixture" }), "targets");
  assert.ok(filtered.targets.every(({ key }) => key.pid !== target.pid));

  const wrong = await tool("observe", {
    target: { pid: process.pid, windowId: target.windowId }, includeScreenshot: true,
  });
  assert.equal(wrong.structuredContent?.body?.result, "error");
  assert.equal(wrong.structuredContent.body.data.code, "targetNotFound");
  assert.ok(wrong.content.every(({ type }) => type !== "image"));

  const result = await tool("observe", {
    target, includeScreenshot: true, includeOcr: true, ocrQuery: marker, budgetMs: 3000,
  });
  const observation = data(result, "observe");
  assert.deepEqual(observation.target, target);
  assert.deepEqual(observation.windowBounds, found.bounds);
  assert.equal(observation.accessibility, "unavailable");
  assert.deepEqual(observation.elements, []);
  assert.equal(observation.visual.captureStatus, "captured");
  assert.deepEqual(observation.visual.frame.captureWindowBounds, found.bounds);
  assert.equal(observation.visual.ocr.status, "complete");
  assert.ok(observation.visual.ocr.matches.some(({ text }) => text.toLowerCase() === marker.toLowerCase()));
  const image = result.content.find(({ type }) => type === "image");
  assert.equal(image?.mimeType, "image/jpeg");
  const pixels = Buffer.from(image.data, "base64");
  assert.ok(pixels.length > 4 && pixels.readUInt16BE(0) === 0xffd8 && pixels.readUInt16BE(pixels.length - 2) === 0xffd9);

  const final = await fixture.call("state");
  assert.equal(final.foregroundPID, initial.foregroundPID);
  assert.equal(final.activationCount, 0);
  console.log(JSON.stringify({ screenshot: "captured", recognizedText: marker, wrongPIDRejected: true,
    actionableRefs: observation.elements.length, fixtureActivations: final.activationCount }));
}

try {
  const executable = join(directory, "CUAFixtureUnbundled");
  await copyFile(bundledFixture, executable);
  await chmod(executable, 0o700);
  session = new Session();
  fixture = new Fixture(undefined, [], executable);
  await run();
} finally {
  try {
    await Promise.all([fixture?.close(), session?.close()]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
