import { isDeepStrictEqual } from "node:util";

export const repairLimits = Object.freeze({ maxCalls: 4, maxMutations: 1, timeoutMs: 1500 });
export const policies = Object.freeze(["none", "simple", "guarded"]);
const copy = (value) => structuredClone(value);
const terminal = { preconditionFailed: "preconditionFailed", verificationFailed: "verificationFailed", cancelled: "cancelled",
  deadlineExceeded: "deadlineExceeded", helperDied: "helperDied", targetStale: "targetStale", ambiguousTarget: "ambiguousTarget",
  unsupported: "unsupported", nativeFailed: "failed" };
const statusFor = (step) => step.delivery === "unknown" ? "uncertain" : step.verification === "confirmed" ? "completed"
  : step.delivery === "not_dispatched" ? "unmet" : "uncertain";

export function toolPayload(response) {
  const result = response?.result ?? response;
  if (result?.structuredContent) return result.structuredContent;
  try { return JSON.parse(result?.content?.find(item => item.type === "text")?.text); } catch { return null; }
}

function validStep(step, requested, index, count, stop) {
  if (!step || step.actionId !== requested.actionId || !["not_dispatched", "dispatched", "unknown"].includes(step.delivery) ||
      !["confirmed", "mismatch", "unverified"].includes(step.verification) || !Array.isArray(step.evidence)) return false;
  if (step.verification === "confirmed" && (!step.evidence.length || !step.evidence.every(item => item?.matched === true))) return false;
  if (step.verification === "mismatch" && !step.evidence.some(item => item?.matched === false)) return false;
  const satisfied = ["alreadySatisfied", "conditionSatisfied"].includes(step.reason);
  if (satisfied && (step.delivery !== "not_dispatched" || step.verification !== "confirmed")) return false;
  if (step.reason != null && !satisfied && (index !== count - 1 || terminal[step.reason] !== stop)) return false;
  if (step.delivery === "not_dispatched" && !satisfied && (index !== count - 1 || !step.reason || stop === "completed")) return false;
  return !(step.delivery === "unknown" || step.verification === "mismatch") || (index === count - 1 && stop !== "completed");
}

// The native host already validates its protocol. This additional binding prevents the harness
// from treating a malformed/unrelated final or an absent tail as proof of unsent input.
export function reconcile(request, response) {
  const all = request.steps.map(step => ({ actionId: step.actionId, status: "uncertain", delivery: "unknown", verification: "unverified" }));
  const p = toolPayload(response);
  let rows, knownUnsent = false;
  if (p?.body?.result === "act") {
    const value = p.body.data;
    if (value?.observationId !== request.observationId || !Array.isArray(value.steps) || !value.steps.length ||
        !Number.isInteger(value.remainingSteps) || value.remainingSteps < 0 || value.steps.length + value.remainingSteps !== request.steps.length ||
        !["completed", ...Object.values(terminal)].includes(value.stopReason) ||
        !value.steps.every((step, i) => validStep(step, request.steps[i], i, value.steps.length, value.stopReason)) ||
        (value.stopReason === "completed" && (value.remainingSteps || value.steps.some(step => statusFor(step) !== "completed")))) return partition(all);
    rows = value.steps; knownUnsent = true;
  } else if (p?.version === 1 && p.route === "rust_host" && p.uncertainty?.observation_id === request.observationId) {
    const value = p.uncertainty;
    if (!Array.isArray(value.settled_steps) || value.settled_steps.length > request.steps.length || !Array.isArray(value.unacknowledged_action_ids) ||
        !isDeepStrictEqual(value.unacknowledged_action_ids, request.steps.slice(value.settled_steps.length).map(step => step.actionId)) ||
        !value.settled_steps.every((step, i) => validStep(step, request.steps[i], i, value.settled_steps.length, "completed") && statusFor(step) === "completed")) return partition(all);
    rows = value.settled_steps;
  } else return partition(all);
  return partition(all.map((item, index) => rows[index] ? { ...copy(rows[index]), status: statusFor(rows[index]) }
    : knownUnsent ? { ...item, status: "unmet", delivery: "not_dispatched", proof: "correlated_unsent_suffix" } : item));
}
function partition(steps) {
  return { steps, completed: steps.filter(step => step.status === "completed").map(step => step.actionId),
    unmet: steps.filter(step => step.status === "unmet").map(step => step.actionId),
    uncertain: steps.filter(step => step.status === "uncertain").map(step => step.actionId) };
}

const scopeKeys = ["bundleId", "appVersion", "runtimeVersion", "osVersion", "instanceId", "pid", "windowId"];
const controlKeys = ["identifier", "role", "subrole"];
const sameKeys = (left, right, keys) => keys.every(key => left?.[key] === right?.[key]);

export class RouteEvidence {
  constructor({ ttlMs = 60000 } = {}) {
    if (!Number.isFinite(ttlMs) || ttlMs <= 0 || ttlMs > 60000) throw new Error("Route evidence freshness horizon must be at most 60 seconds");
    this.ttlMs = ttlMs; this.records = []; this.invalidated = [];
  }
  record({ scope, control, observationId, receipt, now }) {
    if (!scopeKeys.every(key => scope[key] != null) || !control.identifier || !control.role || !control.reference ||
        !observationId || receipt?.delivery !== "dispatched" || receipt.verification !== "confirmed" || receipt.route !== "axSetValue" ||
        !receipt.evidence?.length || !receipt.evidence.every(item => item.matched === true) ||
        !receipt.evidence.some(item => item.condition?.kind === "valueEquals" && item.condition.params?.elementRef === control.reference) ||
        !Number.isFinite(now)) return false;
    this.records.push(copy({ scope, control, action: "setValue", observationId, receipt, recordedAt: now, expiresAt: now + this.ttlMs }));
    return true;
  }
  find(scope, control, now) {
    const sameControl = this.records.filter(record => record.control.identifier === control.identifier);
    const scoped = sameControl.findLast(record => sameKeys(record.scope, scope, scopeKeys) && sameKeys(record.control, control, controlKeys));
    if (!scoped) return { record: null, reason: sameControl.length ? "route_scope_changed" : "route_unproven" };
    if (now >= scoped.expiresAt) return { record: null, reason: "route_expired" };
    return { record: copy(scoped), reason: null };
  }
  invalidate(record, now) {
    this.invalidated.push({ ...copy(record), invalidatedAt: now, invalidatedReason: "retained_identity_unavailable" });
    this.records = this.records.filter(item => item.observationId !== record.observationId || item.control.reference !== record.control.reference);
  }
}

function evidenceState(observation, artifact) {
  const source = artifact ?? observation;
  const visual = source.visual;
  if (!visual) return artifact ? "visual_unavailable" : null;
  const interval = visual.collected;
  if (!isDeepStrictEqual(source.target, observation.target) || !interval || !source.collected || !observation.collected ||
      interval.startedUnixMs < source.collected.startedUnixMs || interval.finishedUnixMs < interval.startedUnixMs ||
      interval.finishedUnixMs > source.collected.finishedUnixMs || interval.finishedUnixMs < observation.collected.startedUnixMs ||
      visual.captureStatus !== "captured" || visual.geometryMatchesAX !== true ||
      !isDeepStrictEqual(visual.frame?.captureWindowBounds, observation.windowBounds)) return "visual_disagreement";
  return null;
}

function visualTextAgrees(observation, identifier) {
  const control = observation.elements?.find(item => item.identifier === identifier);
  const visual = observation.visual, map = visual?.frame?.imageToScreen;
  if (!control?.bounds || typeof control.value !== "string" || !map || !["complete", "partial"].includes(visual.ocr?.status)) return false;
  return visual.ocr.matches.some(match => {
    const box = match.imageBounds;
    if (match.text !== control.value || !box) return false;
    const x = (box.x + box.width / 2) * map.scaleX + map.offsetX;
    const y = (box.y + box.height / 2) * map.scaleY + map.offsetY;
    return x >= control.bounds.x && x < control.bounds.x + control.bounds.width &&
      y >= control.bounds.y && y < control.bounds.y + control.bounds.height;
  });
}

// Policy input is only typed receipts/public observations. The independent oracle is not a port.
// Recovery remains off by default, and neither baseline ever retries unknown or sent input.
export async function recover({ policy = "none", enabled = false, request, response, goals, scope, routes,
  port, artifact = null, limits = repairLimits, now = () => performance.now() }) {
  if (!policies.includes(policy)) throw new Error("Unknown recovery policy");
  if (!Number.isInteger(limits.maxCalls) || limits.maxCalls < 0 || !Number.isInteger(limits.maxMutations) || limits.maxMutations < 0 ||
      !Number.isFinite(limits.timeoutMs) || limits.timeoutMs <= 0) throw new Error("Invalid repair budget");
  const initial = reconcile(request, response), result = { policy, enabled, initial, final: copy(initial), calls: [], repairs: [], mutations: 0, reasons: [], elapsedMs: 0, budgetStopped: false };
  const started = now(), deadline = started + limits.timeoutMs;
  const finish = () => { result.elapsedMs = Math.max(0, now() - started); return result; };
  if (!enabled || policy === "none") { result.reasons.push("repair_disabled"); return finish(); }
  if (initial.uncertain.length) result.reasons.push("uncertain_delivery");
  const pending = goals.filter(goal => initial.unmet.includes(goal.actionId));
  if (!pending.length && !initial.uncertain.length) { result.reasons.push("no_unmet_input"); return finish(); }
  const call = async (kind, operation) => {
    const remaining = Math.floor(deadline - now());
    if (remaining <= 0 || result.calls.length >= limits.maxCalls) throw new Error("repair_budget");
    const entry = { kind, budgetMs: remaining }; result.calls.push(entry);
    let timer;
    try {
      const reply = await Promise.race([operation(remaining, entry), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("repair_budget")), remaining); })]);
      if (now() >= deadline) throw new Error("repair_budget");
      entry.completed = true; return reply;
    } catch (error) { entry.error = error.message; throw error; }
    finally { clearTimeout(timer); }
  };
  try {
    let observation = await call("observe", (remaining, entry) => { entry.handedOff = true; return port.observe(remaining); });
    if (!observation?.observationId || !isDeepStrictEqual(observation.target, request.target)) throw new Error("observation_scope_changed");
    result.observationId = observation.observationId;
    result.observedGoals = goals.map(goal => {
      const matches = observation.elements?.filter(element => element.identifier === goal.identifier) ?? [];
      return { actionId: goal.actionId, matchesGoal: matches.length === 1 && typeof matches[0].value === "string" ? matches[0].value === goal.value : null };
    });
    // Fresh state can reconcile the goal, but it never erases uncertain input history.
    if (initial.uncertain.length) return finish();
    if (policy === "guarded") {
      const disagreement = evidenceState(observation, artifact);
      if (disagreement) {
        if (!port.observeVisual) throw new Error(disagreement);
        observation = await call("reobserve_visual", (remaining, entry) => { entry.handedOff = true; return port.observeVisual(pending[0].identifier, observation, remaining); });
        if (!isDeepStrictEqual(observation?.target, request.target) || evidenceState(observation, observation)) throw new Error("visual_disagreement");
        if (!visualTextAgrees(observation, pending[0].identifier)) throw new Error("visual_text_unverified");
        result.visualReconciled = true;
      }
    }
    result.observationId = observation.observationId;
    for (const goal of pending) {
      const matches = observation.elements?.filter(element => element.identifier === goal.identifier) ?? [];
      if (matches.length !== 1 || typeof matches[0].value !== "string") throw new Error("ambiguous_or_unreadable_control");
      const control = matches[0];
      let record;
      if (policy === "guarded") {
        const evidence = routes.find(scope, control, now());
        if (!evidence.record) throw new Error(evidence.reason);
        record = evidence.record;
        const proof = await call("validate_retained_route", (remaining, entry) => { entry.handedOff = true; return port.validate(record, control.value, remaining); });
        const condition = { kind: "valueEquals", params: { elementRef: record.control.reference, value: control.value } };
        if (proof?.outcome !== "satisfied" || proof.evidence?.matched !== true || !isDeepStrictEqual(proof.evidence.condition, condition)) {
          if (["staleElement", "staleObservation", "targetNotFound", "targetStale"].includes(proof?.errorCode)) {
            routes.invalidate(record, now()); result.routeInvalidated = true;
          }
          throw new Error("retained_route_unverified");
        }
      }
      if (control.value === goal.value) {
        Object.assign(result.final.steps.find(step => step.actionId === goal.actionId),
          { status: "completed", stateEvidenceObservationId: observation.observationId });
        continue;
      }
      if (result.mutations >= limits.maxMutations) throw new Error("repair_budget");
      const step = { actionId: `repair-${goal.actionId}`, operation: { kind: "setValue", params: { elementRef: control.reference, value: goal.value } },
        ...(policy === "guarded" ? { precondition: { kind: "valueEquals", params: { elementRef: control.reference, value: control.value } } } : {}) };
      const repair = { target: request.target, observationId: observation.observationId, steps: [step] };
      const current = result.final.steps.find(item => item.actionId === goal.actionId);
      const reply = await call("act", (remaining, entry) => {
        if (record && now() >= record.expiresAt) throw new Error("route_expired");
        result.mutations++;
        // Admission happened; a thrown/lost result can never become unsent proof.
        Object.assign(current, { status: "uncertain", delivery: "unknown", verification: "unverified" });
        entry.handedOff = true;
        return port.act({ ...repair, budgetMs: remaining });
      });
      const settled = reconcile(repair, reply).steps[0];
      result.repairs.push({ goalActionId: goal.actionId, request: repair, response: toolPayload(reply) });
      Object.assign(current, settled, { actionId: goal.actionId, repairActionId: settled.actionId });
      result.routeUsed = record?.receipt.route ?? null;
    }
  } catch (error) {
    result.reasons.push(error.message);
    result.budgetStopped = error.message === "repair_budget";
  }
  result.final = partition(result.final.steps);
  return finish();
}
