import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { campaignAssignments, lanes } from "./campaign-plan.mjs";
import { compareCampaign, pilotSummary } from "./session-metrics.mjs";

const value = (number, digits = 0) => Number.isFinite(number) ? number.toFixed(digits) : "—";
const percent = (number) => Number.isFinite(number) ? `${value(number * 100, 1)}%` : "—";
const interval = (range) => range ? `${percent(range.lower)}–${percent(range.upper)}` : "—";
const dollars = (number) => Number.isFinite(number) ? `$${value(number, 4)}` : "—";
const cell = (text) => String(text).replaceAll("|", "\\|").replace(/\s+/g, " ");
const row = (cells) => `| ${cells.map(cell).join(" | ")} |`;
function table(columns, rows) {
  return [row(columns), row(columns.map(() => "---")), ...rows.map(row)].join("\n");
}

export function renderCampaign(report) {
  const planned = campaignAssignments(report.stage);
  if (report.mode !== `actual_claude_session_${report.stage}` || !report.finishedAt || report.trials?.length !== planned.length ||
      !report.trials.every((trial, i) => ["task", "variant", "lane", "seed"].every(key => trial[key] === planned[i][key]))) {
    throw new Error("Report must contain the finalized campaign and all original assignments in order");
  }
  const summary = pilotSummary(report.trials);
  if (summary.pending) throw new Error("Report has trials still awaiting a final outcome");
  const cohorts = Object.entries(compareCampaign(report.trials).byCohort);
  const label = (key) => key.split("/");
  const totals = Object.entries(summary.outcomes).map(([name, count]) => `${count} ${name}`).join(", ");
  const lead = `# PER-14 ${report.stage} results\n\n${summary.assigned} assigned trials (${totals}). Model ${report.model}. Source ${report.source.revision}.\n\n`;
  const perLane = table(["Lane", "USD / success", "Total USD", "Strict success", "Wilson 95%", "p50 / p90 ms (n)", "Input / output", "Cache writes / reads"],
    lanes.map(lane => {
      const result = pilotSummary(report.trials.filter(trial => trial.lane === lane));
      return [lane, dollars(result.dollarsPerSuccessfulTask), dollars(result.model.reportedCostUsd),
        `${result.strictSuccesses}/${result.assigned} (${percent(result.strictSuccessRate)})`, interval(result.strictSuccessWilson95),
        `${value(result.taskMs.p50)}/${value(result.taskMs.p90)} (${result.taskMs.samples})`,
        `${value(result.model.inputTokens)}/${value(result.model.outputTokens)}`,
        `${value(result.model.cacheCreationInputTokens)}/${value(result.model.cacheReadInputTokens)}`];
    }));
  const goals = table(["Task", "Variant", "Lane", "Strict success", "Wilson 95%", "Fields correct / assessed", "Fields assigned", "Wrong / unnecessary (assessed trials)", "Pre-handoff refusals", "False / unknown claims", "Target activations / unknown foreground"],
    cohorts.map(([key, cohort]) => [...label(key), `${cohort.strictSuccesses}/${cohort.assigned} (${percent(cohort.strictSuccessRate)})`, interval(cohort.strictSuccessWilson95),
      `${cohort.fields.correct}/${cohort.fields.assessed}`, value(cohort.fields.assigned),
      `${cohort.safety.assessedTrials ? `${cohort.safety.wrongTargetAttempts}/${cohort.safety.unnecessaryWrites}` : "—"} (${cohort.safety.assessedTrials}/${cohort.assigned})`,
      cohort.safety.preHandoffRefusals,
      `${cohort.safety.falseCompletionClaims}/${cohort.safety.unknownCompletionClaims}`, `${cohort.safety.targetActivationTrials}/${cohort.safety.unknownForegroundTrials}`]));
  const usage = table(["Task", "Variant", "Lane", "p50 / p90 ms (n)", "Turns", "MCP calls", "Field writes / presses / waits", "Input / output", "Cache writes / reads", "USD / assigned", "USD / success"],
    cohorts.map(([key, cohort]) => [...label(key), `${value(cohort.taskMs.p50)}/${value(cohort.taskMs.p90)} (${cohort.taskMs.samples})`, value(cohort.model.cliReportedTurns),
      cohort.toolCalls, `${cohort.actions.fieldMutationAttempts}/${cohort.actions.navigationPresses + cohort.actions.submitAttempts}/${cohort.actions.waitRequests + cohort.actions.waitStepsSubmitted}`,
      `${value(cohort.model.inputTokens)}/${value(cohort.model.outputTokens)}`, `${value(cohort.model.cacheCreationInputTokens)}/${value(cohort.model.cacheReadInputTokens)}`,
      dollars(cohort.dollarsPerAssignedTask), dollars(cohort.dollarsPerSuccessfulTask)]));
  const notes = `
All assigned trials remain in the success denominator. Field accuracy covers observed fields only. Latency includes started outcomes, with sample counts shown. Dollar amounts use terminal CLI estimates, including failed sessions. A dash indicates missing evidence or a ratio without a finite denominator. These intervals describe each cohort and do not establish a paired treatment effect. The source JSON retains individual paired trials and observed unrelated switches.
`;
  return `${lead}${perLane}\n\n${goals}\n\n${usage}\n${notes}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (!process.argv[2]) throw new Error("Specify the finalized report.json path");
  process.stdout.write(renderCampaign(JSON.parse(await readFile(process.argv[2], "utf8"))));
}
