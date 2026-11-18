import { distribution } from "../baseline/metrics.mjs";

export function recoverySummary(episodes, repetitions) {
  const assessed = episodes.filter(episode => episode.final);
  const strict = episode => episode.outcome === "passed" && episode.final?.strictCompletion === true && !episode.recovery?.budgetStopped && !episode.cleanupErrors?.length;
  const groups = new Map();
  for (const episode of episodes) {
    const key = `${episode.caseId}/${episode.policy}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(episode);
  }
  return { assigned: episodes.length, assessed: assessed.length, setupBlocked: episodes.filter(episode => episode.outcome === "setup_blocked").length,
    strictUnassisted: assessed.filter(episode => episode.unassisted?.strictCompletion === true).length,
    strictOracleState: assessed.filter(episode => episode.final.strictCompletion === true).length,
    strictEventual: assessed.filter(strict).length,
    strictEventualPerAssigned: episodes.length ? assessed.filter(strict).length / episodes.length : null,
    duplicateActions: assessed.reduce((sum, episode) => sum + episode.final.duplicateActions, 0),
    additionalDamage: assessed.reduce((sum, episode) => sum + episode.final.additionalDamage, 0),
    repairSteps: episodes.reduce((sum, episode) => sum + (episode.recovery?.calls.length ?? 0), 0),
    repairCalls: episodes.reduce((sum, episode) => sum + (episode.recovery?.calls.filter(call => call.handedOff).length ?? 0), 0),
    repairMutations: episodes.reduce((sum, episode) => sum + (episode.recovery?.mutations ?? 0), 0),
    budgetStopped: episodes.filter(episode => episode.recovery?.budgetStopped).length,
    repairTimeMs: distribution(episodes.flatMap(episode => episode.recovery ? [episode.recovery.elapsedMs] : [])),
    repeatedConsistency: { repetitions, groups: groups.size,
      fullyAssessedGroups: [...groups.values()].filter(rows => rows.length === repetitions && rows.every(row => row.final)).length,
      allStrictSuccessGroups: [...groups.values()].filter(rows => rows.length === repetitions && rows.every(strict)).length },
    model: { runs: false, tokens: null, costUsd: null } };
}

export function comparePolicies(episodes) {
  const paired = new Map();
  for (const episode of episodes) {
    const key = `${episode.caseId}/${episode.repeat}`;
    if (!paired.has(key)) paired.set(key, []);
    paired.get(key).push(episode);
  }
  return [...paired].map(([pairId, rows]) => ({ pairId,
    completePolicySet: rows.length === 3 && new Set(rows.map(row => row.policy)).size === 3,
    sameErroneousState: rows.every(row => row.erroneousStateSha256) ? new Set(rows.map(row => row.erroneousStateSha256)).size === 1 : null,
    outcomes: Object.fromEntries(rows.map(row => [row.policy, { strictCompletion: row.final ? row.outcome === "passed" && row.final.strictCompletion === true : null,
      oracleStateStrictCompletion: row.final?.strictCompletion ?? null,
      additionalDamage: row.final?.additionalDamage ?? null, duplicateActions: row.final?.duplicateActions ?? null,
      repairSteps: row.recovery?.calls.length ?? null,
      repairCalls: row.recovery?.calls.filter(call => call.handedOff).length ?? null, repairMs: row.recovery?.elapsedMs ?? null }])) }));
}
