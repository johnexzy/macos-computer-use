import { makeTask } from "./task.mjs";

export const lanes = ["legacy", "single", "composed"];
const tasks = ["invoice", "settings"];

export function campaignAssignments(stage) {
  if (!["pilot", "main"].includes(stage)) throw new Error("Campaign stage must be pilot or main");
  const variants = stage === "pilot" ? ["clean", "friction"] : ["clean", "friction", "user-active"];
  return Array.from({ length: stage === "pilot" ? 1 : 10 }, (_, repeat) => tasks.flatMap((task, i) => variants.flatMap((variant, j) => {
    const seed = stage === "pilot" ? `workflow-${task}-1` : `workflow-${task}-main-${repeat + 1}`;
    const fieldsRequired = makeTask(task, variant, seed).fields.length;
    return lanes.map((_, k) => ({ task, variant, lane: lanes[(repeat + i + j + k) % lanes.length], seed, fieldsRequired }));
  }))).flat();
}

export function validateReviewedPilot(report, model) {
  const expected = campaignAssignments("pilot");
  const trials = report?.trials;
  const outcomes = new Set(["passed", "failed", "unknown", "setup_blocked", "budget_stopped"]);
  if (report?.mode !== "actual_claude_session_pilot" || report.model !== model || !report.finishedAt || report.interruption || !Array.isArray(trials) ||
      trials.length !== expected.length || !Number.isFinite(report.summary?.model?.reportedCostUsd) ||
      !trials.every((trial, i) => outcomes.has(trial.outcome) && trial.task === expected[i].task && trial.variant === expected[i].variant &&
        trial.lane === expected[i].lane && trial.seed === expected[i].seed &&
        (!trial.modelStarted || Number.isFinite(trial.session?.costUsd))) ||
      !lanes.every(lane => trials.some(trial => trial.lane === lane && Number.isFinite(trial.session?.costUsd)))) {
    throw new Error("Supply a finalized reviewed pilot report for the requested model with all assignments and known model cost for every lane");
  }
}
