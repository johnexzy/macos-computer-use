import { performance } from "node:perf_hooks";
import { MutationLedger, ProposalRejected, validateActionSteps, validateFeedbackRefs, laneTools, payload, data, nativeKind } from "../evaluation/adapters.mjs";
export { ProposalRejected, payload, data, nativeKind };
export const nativeBudgetMs = 3000;
const keyOf = (target) => `${target.pid}:${target.windowId}`;
const rejects = (code, message) => { throw new ProposalRejected(code, message); };
const titleMatches = (title, fileName) => title === fileName || title === fileName.replace(/\.txt$/, "");

export function ownedTargets(result, manifest) {
  const names = [...manifest.targets, ...manifest.protectedDocuments].map((d) => d.fileName);
  return (data(result)?.targets ?? []).filter((target) => target.bundleId === manifest.app.bundleId && names.some((name) => titleMatches(target.title, name)));
}
export function bindDocuments(targets, manifest) {
  const records = [...manifest.targets.map((d) => ({ ...d, role: "target" })), ...manifest.protectedDocuments.map((d) => ({ ...d, role: "decoy" }))];
  const bound = records.map((document) => {
    const candidates = targets.filter((target) => titleMatches(target.title, document.fileName));
    if (candidates.length !== 1) throw new Error("Owned document discovery is missing or ambiguous");
    return { ...document, target: candidates[0].key };
  });
  if (new Set(bound.map((d) => d.target.pid)).size !== 1 || new Set(bound.map((d) => keyOf(d.target))).size !== 7) throw new Error("Seven owned windows must bind uniquely to one TextEdit process");
  return bound;
}
export function filterTargetResult(result, manifest) {
  const p = payload(result);
  if (p?.body?.result !== "targets") return result;
  const clean = { ...p, body: { ...p.body, data: { ...p.body.data, targets: ownedTargets(result, manifest) } } };
  return { isError: result.isError === true, structuredContent: clean, content: [{ type: "text", text: JSON.stringify(clean) }] };
}
export function selectControls(observation) {
  const texts = observation?.elements?.filter((e) => e.role === "AXTextArea") ?? [];
  const closes = observation?.elements?.filter((e) => e.role === "AXButton" && e.subrole === "AXCloseButton") ?? [];
  if (texts.length !== 1 || closes.length !== 1 || typeof texts[0].value !== "string" || texts[0].enabled === false || closes[0].enabled !== true ||
      !texts[0].actions?.includes("setValue") || !closes[0].actions?.includes("press")) throw new Error("TextEdit AXTextArea or AXCloseButton capability is unavailable or ambiguous");
  return { text: texts[0], close: closes[0] };
}
export function realworldTools(lane, tools) {
  const selected = laneTools(lane === "single" ? "rebuild-single" : "rebuild-composed", tools);
  const target = structuredClone(tools.find((t) => t.name === "targets"));
  if (!target || selected.length !== 3) throw new Error("Expected typed MCP tool schemas are unavailable");
  target.inputSchema.properties.bundleId = { type: "string", const: "com.apple.TextEdit" };
  target.inputSchema.properties.budgetMs = { type: "integer", minimum: 1, maximum: nativeBudgetMs };
  target.inputSchema.required = [...new Set([...(target.inputSchema.required ?? []), "bundleId", "budgetMs"])];
  return [target, ...selected];
}
export function boundedHistory(history, maxBytes = 128 * 1024) {
  const events = [...history]; let truncated = false;
  while (events.length && Buffer.byteLength(JSON.stringify(events)) > maxBytes) { events.shift(); truncated = true; }
  return { events, truncated };
}

export class RealworldBoundary {
  constructor(lane, documents, now = () => performance.now()) {
    this.lane = lane; this.documents = documents; this.now = now; this.original = new Map(); this.refs = new Map(); this.closed = new Set(); this.ledger = new MutationLedger();
  }
  document(target) {
    const document = this.documents.find((d) => keyOf(d.target) === keyOf(target ?? {}));
    if (!document) rejects("outside_owned_documents", "Target must be an exact originally bound owned window");
    return document;
  }
  register(observation, { captureOriginal = true } = {}) {
    const document = this.document(observation.target);
    for (const element of observation.elements) this.refs.set(element.reference, { documentId: document.documentId, observationId: observation.observationId, element });
    if (captureOriginal && !this.original.has(document.documentId)) {
      try {
        const controls = selectControls(observation);
        this.original.set(document.documentId, { observationId: observation.observationId, refs: new Set([controls.text.reference, controls.close.reference]), controls, at: this.now() });
      } catch { return false; }
    }
    return this.original.has(document.documentId);
  }

  condition(condition, document, { close = false } = {}) {
    if (condition?.kind === "windowAbsent" && Object.keys(condition.params ?? {}).length === 0) return;
    if (close || condition?.kind !== "valueEquals") rejects("unsupported_predicate", "Only exact value or exact window absence predicates are allowed");
    const ref = this.refs.get(condition.params?.elementRef);
    if (!ref || ref.documentId !== document.documentId || ref.element.role !== "AXTextArea") rejects("foreign_reference", "Predicate reference must belong to this owned document");
  }
  validate(name, args, { cleanup = false } = {}) {
    if (!["targets", "observe", "act", "waitFor"].includes(name)) rejects("unsupported_tool", "Only the actual typed MCP tools are allowed");
    if (!Number.isInteger(args.budgetMs) || args.budgetMs < 1 || args.budgetMs > nativeBudgetMs) rejects("invalid_budget", "Every request needs budgetMs between1 and3000");
    if (name === "targets") {
      if (args.bundleId !== "com.apple.TextEdit") rejects("outside_owned_documents", "Discovery is limited to TextEdit");
      return [];
    }
    const document = this.document(args.target);
    if (name === "observe") { if (args.includeScreenshot) rejects("unsupported_image", "This task uses semantic observation only"); return []; }
    if (name === "waitFor") { this.condition(args.condition, document); return []; }
    if (document.role === "decoy" && !cleanup) rejects("protected_reference", "The reference document cannot receive model input");
    const origin = this.original.get(document.documentId);
    if (!origin || args.observationId !== origin.observationId || this.now() - origin.at >= 60000) rejects("original_observation_required", "Mutation requires fresh original observation/references for this document");
    try { validateActionSteps(args.steps, this.lane === "single" ? 1 : 16); }
    catch (error) { rejects("invalid_steps", error.message); }
    try { validateFeedbackRefs(args.feedback, origin.refs); }
    catch (error) { rejects("invalid_feedback", error.message); }
    const mutations = []; let contentReady = this.ledger.controls.get(`${document.documentId}:content`)?.verification === "confirmed";
    for (let index = 0; index < args.steps.length; index++) {
      const step = args.steps[index], operation = step.operation;
      if (operation?.kind === "waitFor") { this.condition(operation.params?.condition, document); continue; }
      const ref = this.refs.get(operation?.params?.elementRef);
      if (!ref || ref.documentId !== document.documentId || !origin.refs.has(operation.params.elementRef)) rejects("foreign_reference", "Mutation must use this document's original control reference");
      if (step.precondition) this.condition(step.precondition, document);
      if (operation.kind === "setValue") {
        if (cleanup || ref.element.role !== "AXTextArea" || !ref.element.actions.includes("setValue") || typeof operation.params.value !== "string" || Buffer.byteLength(operation.params.value) > 65536) rejects("unsupported_mutation", "Only bounded AXTextArea value replacement is allowed");
        if (step.expect) this.condition(step.expect, document);
        mutations.push({ index, key: `${document.documentId}:content` }); contentReady = true;
      } else if (operation.kind === "press") {
        if (ref.element.role !== "AXButton" || ref.element.subrole !== "AXCloseButton" || !ref.element.actions.includes("press")) rejects("unsupported_mutation", "Only the original AXCloseButton may be pressed");
        if (!cleanup && !contentReady) rejects("content_before_close", "Replace and verify the document before closing it");
        if (step.expect?.kind !== "windowAbsent") rejects("close_requirement", "Close must require exact window absence");
        this.condition(step.expect, document, { close: true });
        mutations.push({ index, key: `${document.documentId}:close` });
      } else rejects("unsupported_mutation", "Keyboard, pointer, scripts and other operations are unavailable");
    }
    this.ledger.validate(mutations);
    return mutations;
  }
  record(name, args, mutations, result) {
    this.ledger.record("rebuild-composed", args, mutations, result);
    const observation = nativeKind(result) === "observe" ? data(result) : nativeKind(result) === "waitFor" ? data(result)?.observation : null;
    if (observation && !result.isError) this.register(observation, { captureOriginal: name === "observe" && args.includeValues === true });
    if (nativeKind(result) === "act") {
      const receipt = data(result);
      for (const mutation of mutations) {
        if (!mutation.key.endsWith(":close")) continue;
        const step = receipt.steps?.[mutation.index];
        if (receipt.observationId === args.observationId && step?.actionId === args.steps[mutation.index].actionId && this.ledger.controls.get(mutation.key)?.proof === "correlated_receipt" && receipt.stopReason === "completed" && ["dispatched", "not_dispatched"].includes(step?.delivery) && step?.verification === "confirmed" && step.evidence?.some((e) => e.condition?.kind === "windowAbsent" && e.matched === true && e.collected != null)) this.closed.add(mutation.key.slice(0, -6));
      }
    }

  }
}

// A visible catalog can guide readonly discovery, never prove exact window disappearance.
export function targetClosureProof(boundary) {
  return boundary.documents.filter((d) => d.role === "target").every((d) => boundary.closed.has(d.documentId)) ? true : null;
}
export function reconcileFinalMonitor(episode, state) {
  const prior = episode.monitorFinal;
  episode.monitorStop = state ?? null;
  const known = state?.available === true && state.truncated === false && Number.isInteger(state.targetActivations) &&
    state.targetActivations >= 0 && (!prior || state.targetActivations >= prior.targetActivations);
  const late = known && prior && state.targetActivations > prior.targetActivations;
  if (late) episode.lateActivationPhaseUncertain = true;
  if (episode.outcome === "passed" && (!known || state.targetActivations !== 0)) {
    episode.outcome = "unknown"; episode.strictCompletion = null;
    episode.finalMonitorUnjudgeable = !known;
    episode.finalMonitorDisposition = late ? "Target activation arrived after grading; phase attribution is unknown" : "Final continuous no-target-activation proof is unavailable or contradicted";
  }
  return episode;
}
