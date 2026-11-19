// Mutations target only the disposable accessory fixture.
import assert from "node:assert/strict";
import { setTimeout as pause } from "node:timers/promises";
import { Fixture } from "../fixtures/macos/client.mjs";
import { Session } from "./mcp-session.mjs";

const session = new Session();
const fixture = new Fixture(undefined, ["--scroll"]);

async function tool(name, args = {}) {
  const response = await session.tool(name, args);
  const body = response.result?.structuredContent?.body;
  assert.ok(body, JSON.stringify(response.error ?? response.result));
  return body;
}

try {
  await session.initialize();
  const initial = await fixture.ready;
  const target = { pid: initial.pid, windowId: initial.windowId };
  assert.ok(initial.foregroundPID > 0);
  assert.equal(initial.foregroundPID, initial.startedForegroundPID);
  assert.notEqual(initial.foregroundPID, initial.pid);
  assert.equal(initial.activationCount, 0);

  const capabilities = await tool("capabilities");
  assert.equal(capabilities.result, "capabilities");
  assert.equal(capabilities.data.permissions.accessibility, true);
  assert.ok(capabilities.data.actions.includes("scroll"), JSON.stringify(capabilities.data));

  async function observe(area) {
    let last;
    for (let attempt = 0; attempt < 30; attempt++) {
      const { result, data } = await tool("observe", { target, budgetMs: 1000 });
      const element = data.elements?.find(({ identifier }) => identifier === `scroll.${area}`);
      if (result === "observe" && element?.actions.includes("scroll")) {
        assert.equal(element.role, "AXScrollArea");
        return { observationId: data.observationId, elementRef: element.reference };
      }
      last = { result, data };
      await pause(50);
    }
    assert.fail(`Fixture scroll area did not become actionable: ${JSON.stringify(last)}`);
  }

  async function scroll(area, axis, amount, stopReason = "completed") {
    const before = await fixture.call("state");
    const { observationId, elementRef } = await observe(area);
    const { result, data } = await tool("act", {
      target, observationId, budgetMs: 2000,
      steps: [{ actionId: "scroll", operation: { kind: "scroll", params: { elementRef, axis, amount } } }],
    });
    assert.equal(result, "act", JSON.stringify(data));
    assert.equal(data.stopReason, stopReason, JSON.stringify(data));
    assert.equal(data.steps[0].delivery, stopReason === "completed" ? "dispatched" : "not_dispatched", JSON.stringify(data));
    const after = await fixture.call("state");
    assert.equal(after.foregroundPID, initial.foregroundPID);
    assert.equal(after.activationCount, initial.activationCount);
    const other = area === "primary" ? "secondary" : "primary";
    assert.deepEqual(after[other], before[other], "Sibling viewport changed");
    if (stopReason !== "completed") {
      assert.deepEqual(after[area], before[area], "Rejected scroll moved the viewport");
      return;
    }
    assert.equal(data.steps[0].route, "axScroll");
    const [moving, still] = axis === "vertical" ? ["y", "x"] : ["x", "y"];
    assert.equal(after[area][still], before[area][still], "Wrong scroll axis changed");
    assert.ok(Math.sign(amount) * (after[area][moving] - before[area][moving]) > 0,
      `Viewport should move ${axis} with ${amount}: ${JSON.stringify({ before: before[area], after: after[area] })}`);
  }

  await scroll("primary", "vertical", 250);
  await scroll("primary", "horizontal", 250);
  await scroll("primary", "horizontal", -250);
  await scroll("primary", "vertical", -1000);
  await scroll("primary", "vertical", -250, "verificationFailed");
  await scroll("secondary", "horizontal", 250, "unsupported");
  console.log("Native background scroll verified in both axes, with sibling isolation and foreground preserved");
} finally {
  await Promise.all([fixture.close(), session.close()]);
}
