import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { controls } from "./metrics.mjs";
import { isDeepStrictEqual } from "node:util";

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
export function laneTools(lane, tools) {
  const selected = tools.filter((t) => toolNames[lane === "legacy" ? "legacy" : "rebuild"].includes(t.name));
  return selected.map((tool) => {
    const copy = structuredClone(tool);
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
export function validateFixtureCommand(lane, name, args, state, issuedRefs = new Set()) {
  const names = toolNames[lane === "legacy" ? "legacy" : "rebuild"];
  if (!names.includes(name)) throw new Error("Tool is outside the fixture evaluation allowlist");
  const windows = new Set(state.windows.map((w) => w.windowId));
  if (lane === "legacy") {
    if (!windows.has(args.windowId) || args.appName !== undefined) throw new Error("Legacy calls require an exact fixture windowId and no appName");
    if (name === "wait_for_accessibility" && (args.timeoutMs ?? 5000) > 3000) throw new Error("Legacy wait exceeds matched native budget");
  } else {
    if (args.target?.pid !== state.pid || !windows.has(args.target?.windowId)) throw new Error("Target is outside the live fixture");
    if ((args.budgetMs ?? 5000) > 3000) throw new Error("Native request exceeds matched budget");
    if (name === "act") {
      if (!Array.isArray(args.steps) || !args.steps.length || args.steps.length > (lane === "rebuild-single" ? 1 : 16)) throw new Error("Action count is outside this lane's contract");
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
    if (name === "observe" && args.includeScreenshot === true) throw new Error("Image collection is outside this semantic fixture comparison");
  }
}
export function validateOriginalMutation(lane, name, args, observationId, references) {
  if (lane === "legacy" || name !== "act") return;
  const mutations = args.steps.filter((s) => s.operation.kind !== "waitFor");
  if (mutations.length && (args.observationId !== observationId || mutations.some((s) => !references.has(s.operation.params.elementRef)))) {
    throw new Error("Mutation must use the first successful case observation and its original references");
  }
}

export class LaneAdapter {
  constructor(lane, state, trace) { this.lane = lane; this.state = state; this.trace = trace; this.refs = new Map(); this.referenceOracle = new Map();
    this.originalObservationId = null; this.originalRefs = new Set(); this.origin = null; this.callCount = 0; }
  beginCase(origin) { this.refs.clear(); this.referenceOracle.clear(); this.originalObservationId = null; this.originalRefs.clear(); this.origin = origin; this.callCount = 0; }
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
    this.transport = new StdioClientTransport({ command: this.lane === "legacy" ? process.execPath : path.join(root, ".artifacts/runtime-install/cua-host"),
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
    this.originalTools = available.tools.filter((t) => toolNames[this.lane === "legacy" ? "legacy" : "rebuild"].includes(t.name));
    this.tools = laneTools(this.lane, available.tools);
    if (this.tools.length !== 3) throw new Error("Expected semantic tool contract is unavailable");
    this.capabilities = await this.client.callTool({ name: this.lane === "legacy" ? "get_capabilities" : "capabilities", arguments: {} });
  }
  async call(name, args) {
    validateFixtureCommand(this.lane, name, args, this.state, new Set(this.refs.keys()));
    validateOriginalMutation(this.lane, name, args, this.originalObservationId, this.originalRefs);
    this.correlation = randomUUID(); this.callCount++;
    const started = performance.now();
    let result;
    try {
      result = await this.client.callTool({ name, arguments: args }, undefined, { timeout: 8000 });
      const observation = nativeKind(result) === "observe" ? data(result) : nativeKind(result) === "waitFor" ? data(result)?.observation : null;
      if (observation) for (const element of observation.elements) this.refs.set(element.reference, { identifier: element.identifier, observationId: observation.observationId });
      if (nativeKind(result) === "observe" && this.originalObservationId === null && !result.isError) {
        this.originalObservationId = observation.observationId; this.originalRefs = new Set(observation.elements.map((e) => e.reference));
      }
      return result;
    } finally { this.trace({ event: "tool_call", correlation: this.correlation, name, args, result, elapsedMs: performance.now() - started }); }
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
