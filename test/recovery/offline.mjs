import { gradeState } from "./oracle.mjs";
import { createHash } from "node:crypto";
import { RouteEvidence, recover } from "./recovery.mjs";

export const offlineCases = ["already-complete", "known-unsent", "unknown-delivery", "recreated-control", "route-version-mismatch", "stale-visual", "visual-conflict", "budget-exhausted"];
const clone = (value) => structuredClone(value);
const envelope = (result, data) => ({ structuredContent: { body: { result, data } } });
export const condition = (ref, value) => ({ kind: "valueEquals", params: { elementRef: ref, value } });
export const confirmed = (step) => ({ actionId: step.actionId, delivery: "dispatched", verification: "confirmed", reason: null,
  route: "axSetValue", evidence: [{ observationId: "checked", condition: condition(step.operation.params.elementRef, step.operation.params.value), matched: true }] });
export const bounds = { x: -400, y: 100, width: 440, height: 230 };

export function offlineTrial(caseId, seed) {
  let clock = 100, observations = 0;
  const target = { pid: 42, windowId: 7 };
  const scope = { bundleId: "cua.fixture", appVersion: "fixture-binary-v1", runtimeVersion: "native-v1", osVersion: "offline",
    instanceId: seed, pid: target.pid, windowId: target.windowId };
  const state = { controls: [{ identifier: "primary.first", generation: 1, value: "old-first", attempts: 0, writes: 0 },
    { identifier: "primary.second", generation: 1, value: "old-second", attempts: 0, writes: 0 }], protectedValue: "protected", pending: 0 };
  const observation = () => ({ observationId: `obs-${++observations}`, target, collected: { startedUnixMs: clock, finishedUnixMs: clock + 1 },
    windowBounds: bounds, elements: state.controls.map(control => ({ identifier: control.identifier, role: "AXTextField", subrole: null,
      reference: `${control.identifier}/g${control.generation}/o${observations}`, value: control.value, enabled: true,
      bounds: { x: -380, y: 160 + (control.identifier.endsWith("second") ? 50 : 0), width: 200, height: 30 } })) });
  const origin = observation(), original = clone(state);
  const goals = origin.elements.map((element, index) => ({ identifier: element.identifier, value: `${seed}-goal-${index}`, actionId: `set-${index}` }));
  const request = { target, observationId: origin.observationId, steps: origin.elements.map((element, index) => ({ actionId: goals[index].actionId,
    operation: { kind: "setValue", params: { elementRef: element.reference, value: goals[index].value } } })) };
  const routes = new RouteEvidence();
  routes.record({ scope, control: origin.elements[1], observationId: origin.observationId, now: clock,
    receipt: confirmed(request.steps[1]) });
  state.controls[0].value = goals[0].value; state.controls[0].attempts++; state.controls[0].writes++;
  if (caseId === "already-complete") state.controls[1].value = goals[1].value;
  const refused = { actionId: "set-1", delivery: "not_dispatched", verification: "unverified", reason: "preconditionFailed",
    route: null, evidence: [{ observationId: "guard", condition: condition(origin.elements[1].reference, "not-ready"), matched: false }] };
  let response = envelope("act", { observationId: origin.observationId, steps: [confirmed(request.steps[0]), refused], remainingSteps: 0, stopReason: "preconditionFailed" });
  if (caseId === "unknown-delivery") response = { structuredContent: { version: 1, route: "rust_host", error: { code: "helper_died" },
    uncertainty: { observation_id: origin.observationId, settled_steps: [confirmed(request.steps[0])], unacknowledged_action_ids: ["set-1"] } } };
  if (caseId === "recreated-control") state.controls[1].generation++;
  if (caseId === "route-version-mismatch") scope.appVersion = "fixture-binary-v2";
  const beforeRepair = clone(state);
  const port = {
    async observe() { clock += caseId === "budget-exhausted" ? 1501 : 10; return observation(); },
    async observeVisual(identifier) {
      clock += 15; const current = observation(), control = current.elements.find(item => item.identifier === identifier);
      current.visual = { captureStatus: "captured", geometryMatchesAX: true, collected: current.collected,
        frame: { captureWindowBounds: bounds, imageToScreen: { scaleX: 1, scaleY: 1, offsetX: bounds.x, offsetY: bounds.y } },
        ocr: { status: "complete", matches: [{ text: caseId === "visual-conflict" ? "different" : control.value,
          imageBounds: { x: control.bounds.x - bounds.x, y: control.bounds.y - bounds.y, width: 200, height: 30 } }] } };
      return current;
    },
    async validate(record, value) {
      clock += 5;
      const control = state.controls.find(item => item.identifier === record.control.identifier);
      if (!record.control.reference.includes(`/g${control.generation}/`)) return { outcome: "unavailable", errorCode: "staleElement" };
      return { outcome: "satisfied", evidence: { matched: true, condition: condition(record.control.reference, value) } };
    },
    async act(repair) {
      clock += 10;
      const step = repair.steps[0], control = state.controls.find(item => step.operation.params.elementRef.startsWith(item.identifier + "/"));
      if (step.precondition && step.precondition.params.value !== control.value) throw new Error("precondition_changed");
      control.attempts++; control.writes++; control.value = step.operation.params.value;
      return envelope("act", { observationId: repair.observationId, steps: [confirmed(step)], remainingSteps: 0, stopReason: "completed" });
    },
  };
  const artifact = ["stale-visual", "visual-conflict"].includes(caseId) ? { ...origin, visual: { captureStatus: "captured", geometryMatchesAX: true,
    collected: { startedUnixMs: 50, finishedUnixMs: 51 }, frame: { captureWindowBounds: bounds } } } : null;
  return { request, response, goals, scope, routes, port, artifact, now: () => clock, original, beforeRepair, state };
}


export async function runOffline(caseId, seed, policy) {
  const setup = offlineTrial(caseId, seed), started = performance.now();
  const unassisted = gradeState({ ...setup, beforeRepair: setup.original, after: setup.beforeRepair });
  const recovery = await recover({ ...setup, policy, enabled: policy !== "none" });
  const final = gradeState({ ...setup, after: setup.state });
  return { caseId, seed, policy, mode: "offline_controlled_simulation", outcome: recovery.budgetStopped ? "budget_stopped" : final.strictCompletion ? "passed" : "failed",
    erroneousStateSha256: createHash("sha256").update(JSON.stringify(setup.beforeRepair)).digest("hex"), unassisted, final,
    recovery, wallMs: performance.now() - started, initialRequest: setup.request, initialResponse: setup.response,
    routeRecords: setup.routes.records, invalidatedRouteRecords: setup.routes.invalidated, model: { runs: false, tokens: null, costUsd: null } };
}
