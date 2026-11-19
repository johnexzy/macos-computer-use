import { distribution } from "../baseline/metrics.mjs";

export function cpuMilliseconds(value) {
  const parts = value.trim().split(":").map(Number);
  if (parts.some((part) => !Number.isFinite(part)) || parts.length < 2 || parts.length > 3) return null;
  return Math.round(parts.reduce((total, part) => total * 60 + part, 0) * 1000);
}
export function laneOrder(repeat) {
  const lanes = ["full", "selected", "retained"], offset = repeat % lanes.length;
  return [...lanes.slice(offset), ...lanes.slice(0, offset)];
}
export function foregroundProof(watches, state, pid) {
  if (state?.activationCount > 0 || watches.some((w) => w?.startedForegroundPID === pid || w?.targetActivations > 0 ||
    (w?.startedForegroundPID !== pid && w?.finishedForegroundPID === pid))) return false;
  return watches.length >= 2 && watches.every((w) => w?.available === true && w.targetPID === pid && w.truncated === false) ? true : null;
}
// A read wholly inside independently journaled visibility is true, a disjoint read is false,
// and a non-atomic read straddling a boundary remains unknown.
export function toastClaims(observations, journal) {
  const shown = journal.find((entry) => entry.kind === "toast_shown")?.unixMs;
  const removed = journal.find((entry) => entry.kind === "toast_removed")?.unixMs;
  const claims = [];
  for (const observation of observations) {
    if (observation.elements.some((control) => control.identifier === "toast")) {
      claims.push({ channel: "current", collected: observation.accessibilityCollected });
    }
    for (const event of observation.events?.events || []) if (event.controls.some((control) => control.identifier === "toast")) {
      claims.push({ channel: "history", sequence: event.sequence, collected: event.collected });
    }
  }
  return claims.map((claim) => {
    const interval = claim.collected;
    const truth = !interval || shown == null || removed == null ? null :
      interval.startedUnixMs >= shown && interval.finishedUnixMs <= removed ? true :
      interval.startedUnixMs > removed || interval.finishedUnixMs < shown ? false : null;
    return { ...claim, truth };
  });
}
export function summarize(episodes) {
  return Object.fromEntries(["full", "selected", "retained"].map((lane) => {
    const rows = episodes.filter((episode) => episode.lane === lane);
    return [lane, { assigned: rows.length, strictPassed: rows.filter((r) => r.strictCompletion === true).length,
      strictFailed: rows.filter((r) => r.strictCompletion === false).length, unknown: rows.filter((r) => r.strictCompletion == null).length,
      workflowCompleted: rows.filter((r) => r.workflowCompletion === true).length,
      missedToasts: rows.filter((r) => r.missedToast === true).length,
      falseToastClaims: rows.reduce((sum, r) => sum + (r.toastClaims || []).filter((claim) => claim.truth === false).length, 0),
      unknownToastClaims: rows.reduce((sum, r) => sum + (r.toastClaims || []).filter((claim) => claim.truth == null).length, 0),
      responseBytes: rows.reduce((sum, r) => sum + (r.responseBytes || 0), 0),
      historySamples: rows.reduce((sum, r) => sum + (r.historySamples || 0), 0),
      measuredMs: distribution(rows.map((r) => r.measuredMs)),
      observeMs: distribution(rows.flatMap((r) => (r.calls || []).filter((call) => call.name === "observe" && call.phase === "case").map((call) => call.elapsedMs))),
      helperCpuMs: distribution(rows.map((r) => r.resources?.helper?.cpuMs)),
      helperMaxObservedRssKiB: distribution(rows.map((r) => r.resources?.helper?.maxObservedRssKiB)),
      providerCalls: 0, actualTokens: null, actualCostUsd: null }];
  }));
}
