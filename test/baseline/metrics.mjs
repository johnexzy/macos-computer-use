// Campaign measurements stay separate from a driver's own success claims.
export const usageFields = [
  "inputTokens", "cachedInputTokens", "visualTokens", "reasoningTokens",
  "outputTokens", "costUsd",
];

export function distribution(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  const percentile = (p) => sorted.length ? sorted[Math.ceil(p * sorted.length) - 1] : null;
  return { samples: sorted.length, p50: percentile(0.5), p95: percentile(0.95) };
}

export function summarize(episodes, { repetitions = 3 } = {}) {
  const counts = Object.fromEntries(["passed", "failed", "unknown", "setup_blocked"].map(
    (outcome) => [outcome, episodes.filter((e) => e.outcome === outcome).length],
  ));
  const evaluated = episodes.filter((e) => e.outcome !== "setup_blocked");
  const claims = episodes.filter((e) => e.completionClaim === true);
  const falseClaims = claims.filter((e) => e.outcome === "failed");
  const effectClaims = episodes.filter((e) => e.verificationClaim === true);
  const falseEffects = effectClaims.filter((e) => e.effectObserved === false);
  const groups = new Map();
  for (const episode of episodes) {
    if (!groups.has(episode.caseId)) groups.set(episode.caseId, []);
    groups.get(episode.caseId).push(episode);
  }
  const completeGroups = [...groups.values()].filter((group) =>
    group.length === repetitions && new Set(group.map((e) => e.repeat)).size === repetitions &&
    group.every((e) => e.outcome !== "setup_blocked"),
  );
  const usage = Object.fromEntries(usageFields.map((field) => [field,
    episodes.length && episodes.every((e) => Number.isFinite(e.usage?.[field]))
      ? episodes.reduce((sum, e) => sum + e.usage[field], 0) : null,
  ]));
  const phaseNames = [...new Set(episodes.flatMap((e) => e.phases.map((p) => p.phase)))];
  const byKind = Object.fromEntries([...new Set(episodes.map((e) => e.kind))].map((kind) => {
    const rows = episodes.filter((e) => e.kind === kind && e.outcome !== "setup_blocked");
    return [kind, { assigned: rows.length, passed: rows.filter((e) => e.outcome === "passed").length,
      failed: rows.filter((e) => e.outcome === "failed").length,
      unknown: rows.filter((e) => e.outcome === "unknown").length }];
  }));
  return {
    assigned: episodes.length, outcomes: counts, byKind,
    scenarioSuccessRate: evaluated.length ? counts.passed / evaluated.length : null,
    // Unknown results cannot count as verified success. Missing repetitions remain visible.
    repeatedRunSuccess: {
      repetitions, groups: groups.size, completeGroups: completeGroups.length,
      incompleteGroups: groups.size - completeGroups.length,
      value: completeGroups.length === groups.size && groups.size
        ? completeGroups.filter((g) => g.every((e) => e.outcome === "passed")).length / groups.size : null,
    },
    completionClaims: {
      measured: episodes.some((e) => typeof e.completionClaim === "boolean"),
      total: claims.length, false: falseClaims.length,
      unknown: claims.filter((e) => e.outcome === "unknown" || e.outcome === "setup_blocked").length,
      falsePerClaim: claims.length ? falseClaims.length / claims.length : null,
      falsePerAssigned: episodes.some((e) => typeof e.completionClaim === "boolean") && episodes.length
        ? falseClaims.length / episodes.length : null,
    },
    effectClaims: { total: effectClaims.length, contradicted: falseEffects.length,
      unknown: effectClaims.filter((e) => e.effectObserved == null).length },
    alreadySatisfied: episodes.filter((e) => e.alreadySatisfied).length,
    unassistedScenarioSuccessRate: evaluated.length && evaluated.every((e) => typeof e.assisted === "boolean")
      ? evaluated.filter((e) => e.outcome === "passed" && !e.assisted).length / evaluated.length : null,
    humanRescueMinutes: null,
    usage,
    costPerVerifiedScenario: counts.passed && usage.costUsd !== null ? usage.costUsd / counts.passed : null,
    costRatioReason: !counts.passed ? "no_verified_successes"
      : usage.costUsd === null ? "unmeasured_cost" : null,
    latencyMs: distribution(evaluated.map((e) => e.elapsedMs)),
    responseBytes: distribution(evaluated.map((e) => e.responseBytes)),
    phases: Object.fromEntries(phaseNames.map((name) => [name,
      distribution(episodes.flatMap((e) => e.phases.filter((p) => p.phase === name).map((p) => p.elapsedMs))),
    ])),
    toolCalls: episodes.reduce((sum, e) => sum + e.toolCalls, 0),
    nativeActionRequests: episodes.reduce((sum, e) => sum + e.nativeActionRequests, 0),
    fixtureWriteAttempts: episodes.reduce((sum, e) => sum + (e.fixtureWriteAttempts || 0), 0),
    fixtureAppliedWrites: episodes.reduce((sum, e) => sum + (e.fixtureAppliedWrites || 0), 0),
    foreground: {
      method: "frontmost PID sampled before and after; transient changes are not excluded",
      changedEndpoints: episodes.filter((e) => e.foreground?.preserved === false).length,
      fixtureActivations: episodes.reduce((sum, e) => sum + (e.foreground?.fixtureActivationDelta || 0), 0),
      unknownEndpoints: episodes.filter((e) => e.foreground?.preserved == null).length,
    },
  };
}

export function compareCampaigns(left, right) {
  const key = (e) => JSON.stringify([e.caseId, e.fixtureSeed, e.repeat]);
  const rhs = new Map(right.episodes.map((e) => [key(e), e]));
  const lhs = new Set(left.episodes.map(key));
  const pairs = left.episodes.flatMap((e) => {
    const other = rhs.get(key(e));
    return other ? [{ key: key(e), left: e.outcome, right: other.outcome,
      elapsedDeltaMs: Number.isFinite(e.elapsedMs) && Number.isFinite(other.elapsedMs)
        ? other.elapsedMs - e.elapsedMs : null }] : [];
  });
  return { pairs, missingRight: left.episodes.filter((e) => !rhs.has(key(e))).map(key),
    missingLeft: right.episodes.filter((e) => !lhs.has(key(e))).map(key) };
}

// The same mutation task under clean and adverse fixture behavior, paired by reset trial.
export function compareConditions(episodes, cleanCaseId, adverseCaseIds) {
  const trialKey = (e) => JSON.stringify([e.fixtureSeed, e.repeat]);
  const clean = episodes.filter((e) => e.caseId === cleanCaseId);
  const cleanKeys = new Set(clean.map(trialKey));
  return adverseCaseIds.map((caseId) => {
    const adverse = new Map(episodes.filter((e) => e.caseId === caseId).map((e) => [trialKey(e), e]));
    return { cleanCaseId, adverseCaseId: caseId,
      pairs: clean.flatMap((e) => {
        const other = adverse.get(trialKey(e));
        return other ? [{ fixtureSeed: e.fixtureSeed, repeat: e.repeat,
          clean: e.outcome, adverse: other.outcome,
          elapsedDeltaMs: Number.isFinite(e.elapsedMs) && Number.isFinite(other.elapsedMs)
            ? other.elapsedMs - e.elapsedMs : null }] : [];
      }),
      missingAdverse: clean.filter((e) => !adverse.has(trialKey(e))).map(trialKey),
      missingClean: [...adverse.keys()].filter((key) => !cleanKeys.has(key)),
    };
  });
}
