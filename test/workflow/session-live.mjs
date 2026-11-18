import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";
import { pilotTrial } from "./pilot.mjs";

const output = path.resolve(process.argv[2]);
await mkdir(output, { mode: 0o700 });
const monitor = await buildForegroundMonitor();
const config = { binary: process.execPath, prefix: [fileURLToPath(new URL("./support/fake-session.mjs", import.meta.url))],
  cwd: output, model: "claude-fake-offline", budgetUsd: 1, turns: 46, timeoutMs: 20000 };
const assignments = ["legacy", "single", "composed"].map(lane => ({ lane, scenario: "complete" }));
assignments.push({ lane: "composed", scenario: "incomplete" }, { lane: "composed", scenario: "decoy" });
const episodes = [];
for (const { lane, scenario } of assignments) {
  // This executable only speaks to the local MCP socket. The environment contains no provider key.
  const result = await pilotTrial({ lane, task: "settings", variant: "clean", seed: "offline-session" },
    { ...config, env: { PATH: process.env.PATH, FAKE_WORKFLOW_CASE: scenario } }, monitor);
  episodes.push({ scenario, ...result });
  await writeFile(path.join(output, "report.json"), JSON.stringify({ mode: "offline_fake_cli", providerCalls: 0, episodes }, null, 2), { mode: 0o600 });
  console.log(JSON.stringify({ lane, scenario, outcome: result.outcome, grade: result.grade, model: result.session?.models }));
  assert.equal(result.outcome, scenario === "complete" ? "passed" : "failed", JSON.stringify({ error: result.error, cleanup: result.cleanupErrors, stderr: result.session?.stderr }));
  assert.equal(result.falseCompletionClaim, scenario !== "complete");
  assert.equal(result.grade.wrongTargetAttempts, scenario === "decoy" ? 1 : 0);
  assert.equal(result.session.inventoryOk, true);
  assert.equal(result.session.sameSession, true);
  assert.equal(result.session.costUsd, 0.07);
  assert.equal(result.session.usage.inputTokens, 30);
  assert.ok(result.calls.some(call => payloadCode(call) === "fixture_boundary"));
}

function payloadCode(call) {
  try { return JSON.parse(call.result.content[0].text).code; } catch { return null; }
}
