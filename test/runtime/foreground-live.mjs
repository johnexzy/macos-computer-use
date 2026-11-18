// Foreground input is confined to the known disposable fixture window and control.
import assert from "node:assert/strict";
import { setTimeout as pause } from "node:timers/promises";
import { Fixture } from "../fixtures/macos/client.mjs";
import { Session } from "./mcp-session.mjs";

const targetFixture = new Fixture();
const priorFixture = new Fixture();
const session = new Session(["--allow-foreground"]);
const locked = new Session();
let stage = "launch";

const primary = (state) => state.windows.find((window) => window.key === "primary");
async function until(read, matches, label) {
  for (let tries = 0; tries < 40; tries++) {
    const value = await read();
    if (matches(value)) return value;
    await pause(15);
  }
  assert.fail(`Fixture did not reach ${label}`);
}

async function tool(conn, name, args = {}) {
  const { result, error } = await conn.tool(name, args);
  assert.ok(result, `Missing ${name} result: ${JSON.stringify(error)}`);
  return result.structuredContent;
}

function body(receipt, method) {
  assert.equal(receipt.body?.result, method, receipt.body?.data?.message);
  return receipt.body.data;
}

async function run() {
  await Promise.all([session.initialize(), locked.initialize()]);
  const [original, peer] = await Promise.all([targetFixture.ready, priorFixture.ready]);
  const target = { pid: original.pid, windowId: primary(original).windowId };
  stage = "permissions";
  const caps = body(await tool(session, "capabilities"), "capabilities");
  assert.equal(caps.mode, "foregroundAllowed");
  assert.ok(caps.permissions.accessibility && caps.permissions.inputPosting && caps.permissions.screenRecording,
    "Live foreground fixture requires Accessibility, Input Posting and Screen Recording");
  assert.ok(caps.actions.includes("click") && caps.actions.includes("key"));

  const refused = await tool(locked, "act", {
    target, observationId: "missing", foreground: true,
    steps: [{ actionId: "unauthorized", operation: { kind: "click", params: { point: { x: 1, y: 1 }, space: "imagePixels" } } }],
  });
  assert.equal(refused.error.code, "authorityDenied");
  assert.equal(refused.delivery, "not_dispatched");

  stage = "peer focus";
  await priorFixture.call("configure", { frame: { x: 710, y: 320, width: 440, height: 230 } });
  await priorFixture.call("focus", { expectedForegroundPID: peer.foregroundPID });
  await until(() => priorFixture.call("state"), (state) => state.foregroundPID === peer.pid && primary(state).keyWindow, "prior fixture focus");
  const registered = () => tool(session, "targets", { bundleId: "com.johnoba.cua.fixture" })
    .then((receipt) => body(receipt, "targets").targets.some(({ key }) => key.pid === target.pid && key.windowId === target.windowId));
  await until(registered, Boolean, "target registration");
  const observe = () => tool(session, "observe", { target, includeScreenshot: true, budgetMs: 2500 })
    .then((receipt) => body(receipt, "observe"));
  const click = (element, actionId) => ({
    actionId,
    operation: { kind: "click", params: { space: "screenPoints",
      point: { x: element.bounds.x + element.bounds.width / 2, y: element.bounds.y + element.bounds.height / 2 } } },
  });
  const act = (obs, steps) => tool(session, "act", { target, observationId: obs.observationId, foreground: true, steps, budgetMs: 2800 })
    .then((receipt) => body(receipt, "act"));
  function control(obs, name) {
    assert.equal(obs.visual?.captureStatus, "captured");
    const match = obs.elements.find((element) => element.identifier === `primary.${name}`);
    assert.ok(match, `Missing fixture control ${name}`);
    return match;
  }
  function resultSummary(result) {
    return JSON.stringify({ stop: result.stopReason, foreground: result.foreground, steps: result.steps.map(({ delivery, route }) => ({ delivery, route })) });
  }

  stage = "verified click and restoration";
  await targetFixture.call("configure", { pressEffect: "disableSecond" });
  const originalObservation = await observe();
  const press = click(control(originalObservation, "press"), "press");
  press.expect = { kind: "enabled", params: { elementRef: control(originalObservation, "second").reference, enabled: false } };
  const success = await act(originalObservation, [press]);
  assert.equal(success.stopReason, "completed", resultSummary(success));
  assert.equal(success.steps[0].route, "foregroundClick");
  assert.equal(success.steps[0].delivery, "dispatched");
  assert.equal(success.steps[0].verification, "confirmed");
  assert.equal(success.foreground.restoration, "restored", resultSummary(success));
  const afterClick = await targetFixture.call("state");
  assert.equal(primary(afterClick).pressCount, primary(original).pressCount + 1);
  assert.equal(primary(afterClick).controls.find((control) => control.key === "second").enabled, false);
  assert.equal(afterClick.foregroundPID, peer.pid);

  stage = "stale pixels";
  const stale = await observe();
  const field = control(stale, "first");
  await targetFixture.call("configure", { control: "first", value: "Changed pixels at unchanged window bounds" });
  const changed = await act(stale, [click(field, "stale-pixel")]);
  assert.equal(changed.steps[0].delivery, "not_dispatched", resultSummary(changed));
  assert.equal(changed.foreground.interruption, "frameChanged", resultSummary(changed));

  stage = "app switch";
  await targetFixture.call("configure", { pressEffect: "counter" });
  const snapshot = await observe();
  const button = control(snapshot, "press");
  const later = act(snapshot, [click(button, "dispatched-before-switch"), {
    actionId: "wait-for-switch",
    operation: { kind: "waitFor", params: {
      condition: { kind: "valueEquals", params: { elementRef: control(snapshot, "first").reference, value: "Never set" } },
    } },
  }, click(button, "refused-suffix")]);
  await until(() => targetFixture.call("state"),
    (state) => primary(state).pressCount === primary(afterClick).pressCount + 1, "expected first dispatch");
  await priorFixture.call("focus", { expectedForegroundPID: target.pid });
  await until(() => priorFixture.call("state"), (state) => state.foregroundPID === peer.pid, "interfering application switch");
  const interrupted = await later;
  assert.equal(interrupted.steps[0].delivery, "dispatched", resultSummary(interrupted));
  assert.equal(interrupted.steps[1].delivery, "not_dispatched", resultSummary(interrupted));
  assert.equal(interrupted.remainingSteps, 1);
  assert.equal(interrupted.foreground.interruption, "focusChanged", resultSummary(interrupted));
  assert.equal(interrupted.foreground.restoration, "skipped");
  const final = await targetFixture.call("state");
  assert.equal(final.foregroundPID, peer.pid);
  assert.equal(primary(final).pressCount, primary(afterClick).pressCount + 1);
  const afterSwitchPeer = primary(await priorFixture.call("state"));
  assert.equal(afterSwitchPeer.pressCount, primary(peer).pressCount);
  assert.equal(afterSwitchPeer.keyDownCount, primary(peer).keyDownCount);
  assert.equal(afterSwitchPeer.mouseDownCount, primary(peer).mouseDownCount);

  stage = "exact focused key";
  await targetFixture.call("focus", { control: "first", expectedForegroundPID: peer.pid });
  const beforeKey = await until(() => targetFixture.call("state"),
    (state) => state.foregroundPID === target.pid && primary(state).keyWindow, "target key focus");
  const keyObservation = await observe();
  const key = {
    actionId: "focused-tab", operation: { kind: "key", params: { elementRef: control(keyObservation, "first").reference, key: "tab" } },
  };
  const typed = await act(keyObservation, [key]);
  assert.equal(typed.stopReason, "completed", resultSummary(typed));
  assert.equal(typed.steps[0].route, "foregroundKey");
  await until(() => targetFixture.call("state"),
    (state) => primary(state).keyDownCount === primary(beforeKey).keyDownCount + 1, "native key delivery");
  assert.equal(primary(await priorFixture.call("state")).keyDownCount, primary(peer).keyDownCount);
  return { authorityRefused: true, clickVerified: true, exactPriorFocusRestored: true,
    staleLayoutRefused: true, switchedAppStoppedSuffix: true, keyDeliveryObserved: true, wrongTargetInputs: 0 };
}

try { console.log(JSON.stringify(await run())); }
catch (error) { throw new Error(`Foreground fixture failed during ${stage}`, { cause: error }); }
finally { await Promise.all([targetFixture.close(), priorFixture.close(), session.close(), locked.close()]); }
