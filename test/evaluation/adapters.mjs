import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { controls } from "./metrics.mjs";
import { isDeepStrictEqual } from "node:util";
import Ajv2020 from "ajv/dist/2020.js";
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const payload = (result) => result?.structuredContent ?? (() => {
  try { return JSON.parse(result?.content?.find((p) => p.type === "text")?.text); } catch { return result; }
})();
export const data = (result) => payload(result)?.body?.data;
export const nativeKind = (result) => payload(result)?.body?.result;
const toolNames = { legacy: ["inspect_accessibility", "set_accessibility_value", "wait_for_accessibility"],
  rebuild: ["observe", "act", "waitFor"] };
const rejectedCodes = new Set(["staleObservation", "staleElement", "targetNotFound", "ambiguousTarget", "targetStale",
  "STALE_ELEMENT", "STALE_OBSERVATION", "TARGET_STALE", "ACCESSIBILITY_ELEMENT_NOT_FOUND", "TARGET_NOT_FOUND",
  "AMBIGUOUS_TARGET", "ACCESSIBILITY_AMBIGUOUS", "AMBIGUOUS_MATCH", "AMBIGUOUS_WINDOW"]);
export const nativeBudgetMs = 3000;
const maxValueBytes = 65_536;
export function laneTools(lane, tools) {
  const selected = tools.filter((t) => toolNames[lane === "legacy" ? "legacy" : "rebuild"].includes(t.name));
  return selected.map((tool) => {
    const copy = structuredClone(tool);
    const schema = copy.inputSchema;
    if (lane !== "legacy") {
      schema.properties.budgetMs = { ...schema.properties.budgetMs, minimum: 1, maximum: nativeBudgetMs, default: nativeBudgetMs };
      schema.required = [...new Set([...(schema.required ?? []), "budgetMs"])];
      copy.description = `${copy.description ?? ""} Evaluation calls require explicit budgetMs between 1 and 3000.`;
    } else if (copy.name === "wait_for_accessibility") {
      schema.properties.timeoutMs = { ...schema.properties.timeoutMs, maximum: nativeBudgetMs, default: nativeBudgetMs };
      schema.required = [...new Set([...(schema.required ?? []), "timeoutMs"])];
    }
    if (lane === "rebuild-single" && copy.name === "act") {
      copy.inputSchema.properties.steps.maxItems = 1;
      copy.description = "Execute at most one typed step within the remaining request budget. This evaluation lane enforces a one-step cap on the native act API.";
    }
    return copy;
  });
}
export function intendedRefusal(result, caseId) {
  const accepted = caseId === "ambiguous" ? new Set(["ambiguousTarget", "AMBIGUOUS_TARGET", "ACCESSIBILITY_AMBIGUOUS", "AMBIGUOUS_MATCH", "AMBIGUOUS_WINDOW"]) : rejectedCodes;
  const p = payload(result);
  if (p?.body?.result === "act") return p.body.data.steps.every((s) => s.delivery === "not_dispatched") && accepted.has(p.body.data.stopReason);
  const code = p?.body?.result === "error" ? p.body.data.code : p?.code;
  return result?.isError === true && accepted.has(code);
}
export function validateActionSteps(steps, maxItems = 16) {
  if (!Array.isArray(steps) || !steps.length || steps.length > maxItems) throw new Error("Action count is outside this lane's contract");
  const ids = steps.map((step) => step.actionId);
  if (ids.some((id) => typeof id !== "string" || !id.trim() || Buffer.byteLength(id, "utf8") > 128)) throw new Error("Action IDs must be nonblank and at most 128 UTF-8 bytes");
  if (new Set(ids).size !== ids.length) throw new Error("Action IDs must be unique within a request");
  if (steps.some((step) => step.operation?.kind === "waitFor" && (step.precondition != null || step.expect != null))) {
    throw new Error("Wait steps cannot have external precondition or expect guards");
  }
  for (const step of steps) {
    if (step.operation?.kind === "setValue") validateTextValue(step.operation.params?.value);
    if (step.operation?.kind === "waitFor") validateConditionValue(step.operation.params?.condition);
    for (const condition of [step.precondition, step.expect]) validateConditionValue(condition);
  }
}
function validateTextValue(value) {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > maxValueBytes) throw new Error("Text values must be strings of at most 65536 UTF-8 bytes");
}
function validateConditionValue(condition) {
  if (condition?.kind === "valueEquals") validateTextValue(condition.params?.value);
  if (condition?.kind === "enabled" && typeof condition.params?.enabled !== "boolean") throw new Error("Enabled conditions require a boolean");
}
export function validateFeedbackRefs(feedback, issuedRefs) {
  if (feedback == null) return;
  const refs = feedback.elementRefs;
  if (!Array.isArray(refs) || refs.length > 256 || new Set(refs).size !== refs.length || refs.some((ref) => !issuedRefs.has(ref))) {
    throw new Error("Feedback requires at most 256 unique issued references");
  }
}
export function validateFixtureCommand(lane, name, args, state, issuedRefs = new Set()) {
  const names = toolNames[lane === "legacy" ? "legacy" : "rebuild"];
  if (!names.includes(name)) throw new Error("Tool is outside the fixture evaluation allowlist");
  const windows = new Set(state.windows.map((w) => w.windowId));
  if (lane === "legacy") {
    if (!windows.has(args.windowId) || args.appName !== undefined) throw new Error("Legacy calls require an exact fixture windowId and no appName");
    if (name === "set_accessibility_value") validateTextValue(args.value);
    if (name === "wait_for_accessibility" && (!Number.isInteger(args.timeoutMs) || args.timeoutMs < 100 || args.timeoutMs > nativeBudgetMs)) throw new Error("Legacy wait requires timeoutMs between 100 and 3000");
  } else {
    if (args.target?.pid !== state.pid || !windows.has(args.target?.windowId)) throw new Error("Target is outside the live fixture");
    if (!Number.isInteger(args.budgetMs) || args.budgetMs < 1 || args.budgetMs > nativeBudgetMs) throw new Error("Native request requires budgetMs between 1 and 3000");
    if (name === "act") {
      validateActionSteps(args.steps, lane === "rebuild-single" ? 1 : 16);
      validateFeedbackRefs(args.feedback, issuedRefs);
      for (const step of args.steps) {
        const operation = step.operation;
        if (operation?.kind === "waitFor") {
          if (operation.params?.condition?.kind !== "valueEquals" || !issuedRefs.has(operation.params.condition.params?.elementRef)) throw new Error("Only exact-value wait steps on issued fixture references are allowed");
        } else if (operation?.kind !== "setValue" || !issuedRefs.has(operation.params?.elementRef)) throw new Error("Only setValue on issued fixture references is allowed");
        for (const condition of [step.precondition, step.expect].filter(Boolean)) {
          if (!["valueEquals", "enabled"].includes(condition.kind) || !issuedRefs.has(condition.params?.elementRef)) throw new Error("Condition is outside issued fixture controls");
        }
      }
    }
    if (name === "waitFor" && (args.condition?.kind !== "valueEquals" || !issuedRefs.has(args.condition.params?.elementRef))) throw new Error("Only exact value waits on issued fixture controls are allowed");
    if (name === "waitFor") validateConditionValue(args.condition);
    if (name === "observe" && args.includeScreenshot === true) throw new Error("Image collection is outside this semantic fixture comparison");
  }
}

export class ProposalRejected extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.feedback = { kind: "controller_rejection", code, message, proposalDelivery: "not_dispatched", ...details };
  }
}

const failedReasons = { preconditionFailed: "preconditionFailed", verificationFailed: "verificationFailed", cancelled: "cancelled",
  deadlineExceeded: "deadlineExceeded", helperDied: "helperDied", targetStale: "targetStale", ambiguousTarget: "ambiguousTarget", unsupported: "unsupported", nativeFailed: "failed" };
export function correlatedPrefix(args, result) {
  if (!result || result.observationId !== args.observationId || !Array.isArray(result.steps) || !result.steps.length ||
      !Number.isInteger(result.remainingSteps) || result.remainingSteps < 0 || result.steps.length + result.remainingSteps !== args.steps.length ||
      !["completed", ...Object.values(failedReasons)].includes(result.stopReason)) return false;
  const valid = result.steps.every((step, i) => {
    if (!step || step.actionId !== args.steps[i].actionId || !["not_dispatched", "dispatched", "unknown"].includes(step.delivery) ||
        !["confirmed", "mismatch", "unverified"].includes(step.verification) || !Array.isArray(step.evidence)) return false;
    if (step.verification === "confirmed" && (!step.evidence.length || !step.evidence.every((e) => e?.matched === true))) return false;
    if (step.verification === "mismatch" && !step.evidence.some((e) => e?.matched === false)) return false;
    const successfulWait = ["alreadySatisfied", "conditionSatisfied"].includes(step.reason);
    if (successfulWait && (step.delivery !== "not_dispatched" || step.verification !== "confirmed")) return false;
    const terminal = i === result.steps.length - 1;
    if (step.reason != null && !successfulWait && (!terminal || failedReasons[step.reason] !== result.stopReason)) return false;
    if (step.delivery === "not_dispatched" && !successfulWait && (!terminal || step.reason == null || result.stopReason === "completed")) return false;
    return ![step.delivery === "unknown", step.verification === "mismatch"].some(Boolean) || (terminal && result.stopReason !== "completed");
  });
  return valid && (result.stopReason !== "completed" || (result.remainingSteps === 0 && result.steps.every((s) =>
    s.delivery === "dispatched" || ["alreadySatisfied", "conditionSatisfied"].includes(s.reason))));
}

// State belongs to original observed controls. Readback can establish a goal, never erase sent-input history.
export class MutationLedger {
  constructor() { this.controls = new Map(); }
  validate(mutations) {
    const keys = mutations.map((m) => m.key);
    if (new Set(keys).size !== keys.length) throw new ProposalRejected("duplicate_mutation", "One proposal cannot mutate the same control twice");
    for (const { key } of mutations) {
      const prior = this.controls.get(key) ?? this.controls.get("legacy-unresolved-selector");
      if ((key === "legacy-unresolved-selector" && this.controls.size) || (prior && (prior.delivery !== "not_dispatched" || prior.verification === "confirmed"))) {
        throw new ProposalRejected("mutation_replay_refused", "This control already has sent, uncertain, or settled input; observe/wait or finish", { control: key, priorMutation: prior ?? null });
      }
    }
  }
  record(lane, args, mutations, result) {
    if (!mutations.length) return;
    const receipt = nativeKind(result) === "act" ? data(result) : null;
    const correlated = lane !== "legacy" && correlatedPrefix(args, receipt);
    for (const mutation of mutations) {
      const step = correlated ? receipt.steps[mutation.index] : null;
      const provenUnsent = correlated && mutation.index >= receipt.steps.length;
      const legacyDeclaredDelivery = lane === "legacy" && !result?.isError && ["delivered_verified", "delivered_unverified"].includes(payload(result)?.status);
      this.controls.set(mutation.key, step ? { delivery: step.delivery, verification: step.verification, proof: "correlated_receipt" }
        : provenUnsent ? { delivery: "not_dispatched", verification: "unverified", proof: "correlated_unsent_suffix" }
        : { delivery: legacyDeclaredDelivery ? "dispatched" : "unknown", verification: "unverified", proof: "no_reusable_dispatch_proof" });
    }
  }
  blocked() { return new Set([...this.controls].filter(([, s]) => s.delivery !== "not_dispatched" || s.verification === "confirmed").map(([key]) => key)); }
  snapshot() { return Object.fromEntries(this.controls); }
}
export function validateOriginalMutation(lane, name, args, observationId, references, originalTarget = null) {
  if (lane === "legacy" || name !== "act") return;
  const mutations = args.steps.filter((s) => s.operation.kind !== "waitFor");
  if (mutations.length && (args.observationId !== observationId || (originalTarget && !isDeepStrictEqual(args.target, originalTarget)) ||
      mutations.some((s) => !references.has(s.operation.params.elementRef)))) {
    throw new Error("Mutation must use the first successful case observation and its original references");
  }
}

export class LaneAdapter {
  constructor(lane, state, trace) { this.lane = lane; this.state = state; this.trace = trace; this.refs = new Map(); this.referenceOracle = new Map();
    this.originalObservationId = null; this.originalRefs = new Set(); this.originalTarget = null; this.origin = null; this.callCount = 0; this.caseObserved = false; this.ledger = new MutationLedger(); this.validators = new Map(); }
  beginCase(origin) { this.refs.clear(); this.referenceOracle.clear(); this.originalObservationId = null; this.originalRefs.clear(); this.originalTarget = null; this.origin = origin; this.callCount = 0; this.caseObserved = false; this.ledger = new MutationLedger(); }
  setTools(tools) {
    this.originalTools = tools.filter((t) => toolNames[this.lane === "legacy" ? "legacy" : "rebuild"].includes(t.name));
    this.tools = laneTools(this.lane, tools);
    const schemas = new AjvJsonSchemaValidator(new Ajv2020({ strict: false, validateFormats: false, allErrors: true }));
    this.validators = new Map(this.tools.map((tool) => [tool.name, schemas.getValidator(tool.inputSchema)]));
  }
  mutations(name, args) {
    if (name === "set_accessibility_value") return [{ index: 0, key: controls(this.state).some((c) => c.identifier === args.selector?.identifier)
      ? args.selector.identifier : "legacy-unresolved-selector" }];
    return name === "act" ? args.steps.flatMap((step, index) => step.operation.kind === "waitFor" ? []
      : [{ index, key: this.refs.get(step.operation.params.elementRef)?.identifier ?? `ref:${step.operation.params.elementRef}` }]) : [];
  }
  captureOracle(result, state) {
    const observation = nativeKind(result) === "observe" ? data(result) : nativeKind(result) === "waitFor" ? data(result)?.observation : null;
    if (observation) for (const element of observation.elements) {
      const control = controls(state).find((c) => c.identifier === element.identifier);
      if (control) this.referenceOracle.set(element.reference, { generation: control.generation, windowGeneration: control.windowGeneration });
    }
  }
  async connect() {
    const [{ Client }, { StdioClientTransport }] = await Promise.all([
      import("@modelcontextprotocol/sdk/client/index.js"), import("@modelcontextprotocol/sdk/client/stdio.js")]);
    this.transport = new StdioClientTransport({ command: this.lane === "legacy" ? process.execPath : path.join(root, ".artifacts/runtime-install/useui"),
      args: this.lane === "legacy" ? [path.join(root, "server.mjs")] : [], cwd: root, stderr: "pipe",
      env: { ...process.env, MACOS_COMPUTER_USE_UNSAFE: "0" } });
    const send = this.transport.send.bind(this.transport);
    this.transport.send = async (message) => { this.trace({ event: "mcp_request", correlation: this.correlation, message }); return send(message); };
    this.client = new Client({ name: "cua-matched-evaluation", version: "1" });
    await this.client.connect(this.transport);
    const receive = this.transport.onmessage;
    this.transport.onmessage = (message) => { this.trace({ event: "mcp_response", correlation: this.correlation, message }); receive?.(message); };
    this.diagnostics = "";
    this.transport.stderr?.on("data", (bytes) => { this.diagnostics += bytes.toString(); });
    const available = await this.client.listTools();
    this.setTools(available.tools);
    if (this.tools.length !== 3) throw new Error("Expected semantic tool contract is unavailable");
    this.capabilities = await this.client.callTool({ name: this.lane === "legacy" ? "get_capabilities" : "capabilities", arguments: {} });
  }
  async call(name, args) {
    let mutations;
    try {
      const validate = this.validators.get(name);
      if (!validate) throw new Error("Tool schema is unavailable");
      const validated = validate(args);
      if (!validated.valid) throw new Error(validated.errorMessage);
      validateFixtureCommand(this.lane, name, args, this.state, new Set(this.refs.keys()));
      validateOriginalMutation(this.lane, name, args, this.originalObservationId, this.originalRefs, this.originalTarget);
      mutations = this.mutations(name, args);
      if (mutations.length && !this.caseObserved) throw new Error("Mutation requires a successful case observation");
      this.ledger.validate(mutations);
    } catch (error) {
      throw error instanceof ProposalRejected ? error : new ProposalRejected("invalid_arguments", error.message);
    }
    this.correlation = randomUUID(); this.callCount++;
    const started = performance.now();
    let result;
    try {
      result = await this.client.callTool({ name, arguments: args }, undefined, { timeout: 8000 });
      if (!result.isError && ((name === "inspect_accessibility" && payload(result)?.elements?.length) || nativeKind(result) === "observe")) this.caseObserved = true;
      const observation = nativeKind(result) === "observe" ? data(result) : nativeKind(result) === "waitFor" ? data(result)?.observation : null;
      if (observation) for (const element of observation.elements) this.refs.set(element.reference, { identifier: element.identifier, observationId: observation.observationId });
      if (nativeKind(result) === "observe" && this.originalObservationId === null && !result.isError) {
        this.originalObservationId = observation.observationId; this.originalRefs = new Set(observation.elements.map((e) => e.reference));
        this.originalTarget = { ...(observation.target ?? args.target) };
      }
      return result;
    } finally {
      this.ledger.record(this.lane, args, mutations, result);
      this.trace({ event: "tool_call", correlation: this.correlation, name, args, result, elapsedMs: performance.now() - started });
    }
  }
  async propose(command) {
    try {
      const result = await this.call(command.tool, command.args);
      return { kind: "tool_result", result, mutating: this.mutations(command.tool, command.args).length > 0 };
    } catch (error) {
      if (error instanceof ProposalRejected) return { kind: "controller_rejection", feedback: error.feedback };
      return { kind: "tool_failure", error: error.message, mutating: this.mutations(command.tool, command.args).length > 0,
        mutationState: this.ledger.snapshot() };
    }
  }
  async observe(windowId) {
    return this.lane === "legacy" ? this.call("inspect_accessibility", { windowId, roles: ["AXTextField"], includeValues: true, maxResults: 50 })
      : this.call("observe", { target: { pid: this.state.pid, windowId }, includeValues: true, budgetMs: 3000 });
  }
  confirmations(name, args, result, after) {
    const truth = (identifier, value, enabled, reference) => {
      const control = controls(after).find((c) => c.identifier === identifier), identity = this.referenceOracle.get(reference);
      if (!control || (reference && !identity)) return null;
      return (!identity || (control.generation === identity.generation && control.windowGeneration === identity.windowGeneration)) &&
        (enabled !== undefined ? control.enabled === enabled : control.modelValue === value && control.controlValue === value);
    };
    if (this.lane === "legacy") {
      const p = payload(result);
      if (name !== "set_accessibility_value" || result.isError || !(p?.status === "delivered_verified" || p?.execution?.verification === "value_readback")) return [];
      return [{ kind: "runtime_confirmation", truth: truth(args.selector?.identifier, args.value), condition: args.selector, value: args.value }];
    }
    if (nativeKind(result) === "waitFor" && data(result)?.outcome === "satisfied") {
      const evidence = data(result).evidence;
      const condition = evidence?.condition ?? args.condition, reference = condition?.params?.elementRef;
      const actual = condition?.kind === "valueEquals" ? truth(this.refs.get(reference)?.identifier, condition.params.value, undefined, reference) : null;
      return [{ kind: "runtime_confirmation", observationId: evidence?.observationId ?? null, condition,
        truth: !evidence || !evidence.collected ? null : !evidence.matched || !isDeepStrictEqual(condition, args.condition) ? false : actual }];
    }
    if (nativeKind(result) !== "act") return [];
    const receipts = data(result).steps;
    return receipts.flatMap((step, index) => step.verification !== "confirmed" ? [] : step.evidence.length ? step.evidence.map((e) => {
      const identifier = this.refs.get(e.condition.params?.elementRef)?.identifier;
      const changedLater = args.steps?.some((later, laterIndex) => laterIndex > index && receipts[laterIndex]?.delivery !== "not_dispatched" &&
        ["dispatched", "unknown"].includes(receipts[laterIndex]?.delivery) && later.operation?.kind === "setValue" &&
        this.refs.get(later.operation.params?.elementRef)?.identifier === identifier);
      const actual = changedLater ? null : e.condition.kind === "valueEquals" ? truth(identifier, e.condition.params.value, undefined, e.condition.params.elementRef)
        : e.condition.kind === "enabled" ? truth(identifier, undefined, e.condition.params.enabled, e.condition.params.elementRef) : null;
      return { kind: "runtime_confirmation", actionId: step.actionId, observationId: e.observationId, condition: e.condition,
        truth: e.matched === true ? actual : false, oracleLimit: changedLater ? "later_step_may_change_witness" : null };
    }) : [{ kind: "runtime_confirmation", actionId: step.actionId, truth: null }]);
  }
  async close() { await this.client?.close(); }
}
