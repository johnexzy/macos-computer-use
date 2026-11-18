import { usageSummary } from "../evaluation/metrics.mjs";

const terminal = new Set(["passed", "failed", "unknown", "setup_blocked", "budget_stopped", "interrupted"]);
const sum = (rows, value) => rows.reduce((total, row) => total + value(row), 0);
const finite = Number.isFinite;

function wilson95(passed, assigned) {
  if (!assigned) return null;
  const z = 1.959963984540054;
  const p = passed / assigned;
  const scale = 1 + z * z / assigned;
  const center = (p + z * z / (2 * assigned)) / scale;
  const radius = z * Math.sqrt((p * (1 - p) + z * z / (4 * assigned)) / assigned) / scale;
  return { lower: Math.max(0, center - radius), upper: Math.min(1, center + radius) };
}

function distribution(values) {
  const sorted = values.filter(finite).sort((a, b) => a - b);
  const quantile = (q) => sorted.length ? sorted[Math.ceil(q * sorted.length) - 1] : null;
  return { samples: sorted.length, p50: quantile(0.5), p90: quantile(0.9) };
}

export function pilotSummary(trials) {
  const sessions = trials.flatMap(trial => trial.session ? [trial.session] : []);
  const pending = trials.filter(trial => !terminal.has(trial.outcome)).length;
  const successes = trials.filter(trial => trial.outcome === "passed").length;
  const model = usageSummary(sessions);
  const missingCost = trials.filter(trial => trial.session ? !finite(trial.session.costUsd) : trial.outcome === "admitted" || trial.modelStarted).length;
  const reportedCostUsd = missingCost ? null : model.reportedCostUsd;
  const fieldsRequired = (trial) => trial.fieldsRequired ?? trial.grade?.requiredFields;
  const fieldEvidence = trials.filter(trial => finite(trial.grade?.correctFields) && finite(fieldsRequired(trial)));
  const fieldDenominator = trials.every(trial => finite(fieldsRequired(trial))) ? sum(trials, fieldsRequired) : null;
  const assessableFields = sum(fieldEvidence, fieldsRequired);
  const safetyEvidence = trials.filter(trial => finite(trial.grade?.wrongTargetAttempts));
  const calls = trials.flatMap(trial => trial.calls ?? []);
  const handedOff = calls.filter(call => call.handedOff);
  return {
    assigned: trials.length,
    pending,
    outcomes: Object.fromEntries([...new Set(trials.map(trial => trial.outcome))].map(outcome =>
      [outcome, trials.filter(trial => trial.outcome === outcome).length])),
    strictSuccesses: successes,
    strictSuccessRate: trials.length ? successes / trials.length : null,
    strictSuccessWilson95: pending ? null : wilson95(successes, trials.length),
    fields: {
      assigned: fieldDenominator,
      assessed: assessableFields,
      correct: sum(fieldEvidence, trial => trial.grade.correctFields),
      unassessed: fieldDenominator === null ? null : fieldDenominator - assessableFields,
    },
    safety: {
      assessedTrials: safetyEvidence.length,
      wrongTargetAttempts: sum(safetyEvidence, trial => trial.grade.wrongTargetAttempts),
      unnecessaryWrites: sum(safetyEvidence, trial => trial.grade.unnecessaryWrites),
      falseCompletionClaims: trials.filter(trial => trial.falseCompletionClaim).length,
      unknownCompletionClaims: trials.filter(trial => trial.unknownCompletionClaim).length,
      targetActivationTrials: trials.filter(trial => trial.grade?.targetActivationPreserved === false).length,
      unknownForegroundTrials: trials.filter(trial => trial.grade?.targetActivationPreserved !== true && trial.grade?.targetActivationPreserved !== false).length,
      observedUnrelatedSwitches: sum(trials, trial => trial.foreground?.events.filter(event => event.pid !== trial.foreground.targetPID).length ?? 0),
    },
    taskMs: distribution(trials.map(trial => trial.taskMs)),
    completedTaskMs: distribution(trials.filter(trial => trial.outcome === "passed").map(trial => trial.taskMs)),
    toolCalls: calls.length,
    handedOffToolCalls: handedOff.length,
    actions: {
      fieldMutationAttempts: sum(trials, trial => trial.grade?.mutationAttempts ?? 0),
      navigationPresses: sum(trials, trial => trial.grade?.navigationPresses ?? 0),
      submitAttempts: sum(trials, trial => trial.after?.events.filter(event => event.kind === "submit_attempt").length ?? 0),
      waitRequests: handedOff.filter(call => ["waitFor", "wait_for_accessibility", "wait_for_text"].includes(call.name)).length,
      waitStepsSubmitted: sum(handedOff.filter(call => call.name === "act"), call => call.args.steps.filter(step => step.operation.kind === "waitFor").length),
    },
    model: { ...model, reportedCostUsd, missingCost, knownSessionCostUsd: sum(sessions, session => finite(session.costUsd) ? session.costUsd : 0) },
    dollarsPerAssignedTask: !pending && trials.length && reportedCostUsd !== null ? reportedCostUsd / trials.length : null,
    dollarsPerSuccessfulTask: !pending && successes && reportedCostUsd !== null ? reportedCostUsd / successes : null,
  };
}

export function compareCampaign(trials) {
  const byCohort = {}, pairs = {};
  for (const trial of trials) {
    const cohort = `${trial.task}/${trial.variant}/${trial.lane}`;
    (byCohort[cohort] ??= []).push(trial);
    const pair = `${trial.task}/${trial.variant}/${trial.seed}`;
    (pairs[pair] ??= {})[trial.lane] = {
      outcome: trial.outcome, taskMs: trial.taskMs ?? null, costUsd: trial.session?.costUsd ?? null,
      turns: trial.session?.numTurns ?? null, toolCalls: trial.calls?.length ?? null,
    };
  }
  return { byCohort: Object.fromEntries(Object.entries(byCohort).map(([key, cohort]) => [key, pilotSummary(cohort)])), pairs };
}
