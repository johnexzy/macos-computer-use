import { makeTask } from "./task.mjs";

export const lanes = ["legacy", "single", "composed"];
const tasks = ["invoice", "settings"];
const laneOrders = [
  ["legacy", "single", "composed"],
  ["single", "composed", "legacy"],
  ["composed", "legacy", "single"],
  ["composed", "single", "legacy"],
  ["single", "legacy", "composed"],
  ["legacy", "composed", "single"],
];

export function campaignAssignments(stage) {
  if (!["pilot", "main"].includes(stage)) throw new Error("Campaign stage must be pilot or main");
  const variants = stage === "pilot" ? ["clean", "friction"] : ["clean", "friction", "user-active"];
  return Array.from({ length: stage === "pilot" ? 1 : 10 }, (_, repeat) => tasks.flatMap((task, i) => variants.flatMap((variant, j) => {
    const seed = stage === "pilot" ? `workflow-${task}-1` : `workflow-${task}-main-${repeat + 1}`;
    const fieldsRequired = makeTask(task, variant, seed).fields.length;
    const order = laneOrders[(repeat + i * variants.length + j) % laneOrders.length];
    return order.map(lane => ({ task, variant, lane, seed, fieldsRequired }));
  }))).flat();
}

export function validateReviewedPilot(report, model) {
  const expected = campaignAssignments("pilot");
  const trials = report?.trials;
  const outcomes = new Set(["passed", "failed", "unknown", "budget_stopped"]);
  if (report?.mode !== "actual_claude_session_pilot" || report.model !== model || !report.finishedAt || report.interruption || !Array.isArray(trials) ||
      trials.length !== expected.length || !Number.isFinite(report.summary?.model?.reportedCostUsd) ||
      !trials.every((trial, i) => {
        const session = trial.session;
        return outcomes.has(trial.outcome) && trial.task === expected[i].task && trial.variant === expected[i].variant &&
          trial.lane === expected[i].lane && trial.seed === expected[i].seed && trial.modelStarted === true &&
          session?.sameSession === true && session.inventoryOk === true && session.modelOk === true &&
          Number.isFinite(session.costUsd) && session.costUsd >= 0 &&
          typeof session.sessionId === "string" && session.sessionId.length > 0;
      }) || new Set(trials.map(trial => trial.session.sessionId)).size !== expected.length) {
    throw new Error("Supply a finalized reviewed pilot report for the requested model with a distinct verified session and known model cost for every assignment");
  }
}
