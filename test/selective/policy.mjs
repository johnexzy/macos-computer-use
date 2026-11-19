// Requery policy is a caller choice. The native collector only reports bounded evidence.
export function widerReadReason(observation) {
  if (!observation?.axSelection) return null;
  if (observation.axSelection.ambiguous) return "ambiguous_query";
  if (observation.axSelection.coverage !== "complete") return "incomplete_query";
  if (observation.events?.stale) return "history_stale";
  if (observation.events?.overrun) return "history_overrun";
  return null;
}
export function selectedArgs(target, selectors, { includeValues = false, retain = false, cursor } = {}) {
  return { target, includeValues, axSelectors: selectors, ...(retain ? { eventHistory: { cursor: cursor ?? null } } : {}) };
}
