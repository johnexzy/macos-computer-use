import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { policies, repairLimits } from "./recovery.mjs";
import { offlineCases, runOffline } from "./offline.mjs";
import { recoverySummary, comparePolicies } from "./metrics.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const hash = text => createHash("sha256").update(text).digest("hex");
const { values } = parseArgs({ options: { mode: { type: "string", default: "offline" }, output: { type: "string" },
  repetitions: { type: "string", default: "3" }, execute: { type: "boolean" } } });
if (!["offline", "native"].includes(values.mode)) throw new Error("Mode must be offline or native");
const repetitions = Number(values.repetitions);
if (!Number.isInteger(repetitions) || repetitions < 1 || repetitions > 5) throw new Error("Repetitions must be between1 and5");
let driver, monitorBinary;
if (values.mode === "native") driver = await import("./native.mjs");
const cases = values.mode === "native" ? driver.nativeCases : offlineCases;
const assignments = Array.from({ length: repetitions }, (_, repeat) => cases.flatMap(caseId => policies.map((_, index) =>
  ({ caseId, repeat, seed: `per13-${caseId}-${repeat}`, policy: policies[(index + repeat) % policies.length], outcome: "not_started" })))).flat();
if (values.mode === "native" && !values.execute) {
  console.log(JSON.stringify({ mode: "native_plan_only", guiActions: 0, modelCalls: 0, repairLimits, assignments }, null, 2));
  process.exit(0);
}
const output = path.resolve(values.output ?? path.join(root, ".artifacts", `per13-${values.mode}-${new Date().toISOString().replaceAll(":", "-")}`));
await fs.mkdir(path.dirname(output), { recursive: true, mode: 0o700 });
await fs.mkdir(output, { recursive: false, mode: 0o700 });
const files = ["recovery.mjs", "oracle.mjs", "offline.mjs", "native.mjs", "metrics.mjs", "run.mjs", "recovery.test.mjs"];
const source = { revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
  dirty: Boolean(execFileSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" }).trim()),
  sha256: Object.fromEntries(await Promise.all(files.map(async file => [`test/recovery/${file}`, hash(await fs.readFile(path.join(root, "test/recovery", file)))]))) };
const report = { schemaVersion: 1, milestone: "PER-13", mode: values.mode, startedAt: new Date().toISOString(), source,
  repetitions, repairLimits, oracleBudgetMs: 500, model: { runs: false, tokens: null, costUsd: null },
  timing: values.mode === "offline" ? "Deterministic logical policy clock; wallMs is harness execution only, not native performance" : "Measured native policy wall time; setup/initial actions are separately tagged",
  notes: ["Harness-only opt-in recovery. No production API or automatic recovery behavior changed.",
    "Both baselines refuse unknown or sent-unverified input. Simple repairs fresh uniquely identified known-unsent work; guarded adds bounded retained-route and visual reconciliation.",
    "Route evidence is only for axSetValue in this controlled app/control/runtime version and lifetime; it does not justify another input route.",
    "Private oracle state is consumed only by final grading and paired-state fingerprints, never by the repair policy.",
    "Native response-loss is an explicitly injected omission of a valid suffix; it is not an actual helper-death experiment.",
    "Failures, setup blocks and mismatched pairs remain assigned. These unpaid controlled checks do not measure model recovery or establish universal benefit."],
  episodes: assignments };
const save = async () => {
  report.summary = recoverySummary(report.episodes, repetitions);
  report.byPolicy = Object.fromEntries(policies.map(policy => [policy, recoverySummary(report.episodes.filter(row => row.policy === policy), repetitions)]));
  report.pairs = comparePolicies(report.episodes);
  await fs.writeFile(path.join(output, "report.tmp"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  await fs.rename(path.join(output, "report.tmp"), path.join(output, "report.json"));
};
await save();
let unavailable;
if (values.mode === "native") {
  try {
    report.nativeSource = await driver.nativeProvenance();
    const monitor = await import("../runtime/support/foreground-monitor.mjs");
    monitorBinary = await monitor.buildForegroundMonitor();
    report.foregroundMonitorSha256 = hash(await fs.readFile(monitorBinary));
  } catch (error) { unavailable = error.message; }
}
for (const [index, assigned] of assignments.entries()) {
  try {
    report.episodes[index] = unavailable ? { ...assigned, outcome: "setup_blocked", error: unavailable }
      : { ...assigned, ...await (values.mode === "offline" ? runOffline(assigned.caseId, assigned.seed, assigned.policy)
        : driver.runNative(assigned.caseId, assigned.seed, assigned.policy, report.nativeSource, monitorBinary)) };
  } catch (error) { report.episodes[index] = { ...assigned, outcome: "setup_blocked", error: error.message }; }
  await save();
}
report.finishedAt = new Date().toISOString();
await save();
console.log(JSON.stringify({ output, mode: report.mode, summary: report.summary, byPolicy: report.byPolicy,
  pairedStateMismatches: report.pairs.filter(pair => pair.sameErroneousState === false).length }, null, 2));
