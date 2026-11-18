import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv";
import Ajv2020 from "ajv/dist/2020.js";
import path from "node:path";
import { root, payload, data, nativeKind, correlatedPrefix, validateActionSteps, validateFeedbackRefs } from "../evaluation/adapters.mjs";

export const laneName = "workflow";
const budgetMs = 3000;
const legacyRoutes = new Set(["get_capabilities", "get_active_app", "list_windows", "inspect_accessibility", "wait_for_accessibility",
  "screenshot", "find_text", "wait_for_text", "set_accessibility_value", "perform_accessibility_action"]);
const legacyDiscovery = new Set(["get_capabilities", "get_active_app", "list_windows"]);
const rebuiltRoutes = new Set(["capabilities", "targets", "observe", "waitFor", "act"]);
const jsonText = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
const refuse = (message) => ({ ...jsonText({ code: "fixture_boundary", delivery: "not_dispatched", message }), isError: true });

export async function connectLane(lane) {
  const transport = new StdioClientTransport({
    command: lane === "legacy" ? process.execPath : path.join(root, ".artifacts/runtime-install/cua-host"),
    args: lane === "legacy" ? [path.join(root, "server.mjs")] : [], cwd: root, stderr: "pipe", env: { MACOS_COMPUTER_USE_UNSAFE: "0" },
  });
  transport.stderr?.resume();
  const client = new Client({ name: "workflow-session", version: "1" });
  try {
    await client.connect(transport);
    const { tools } = await client.listTools();
    return { client, tools };
  } catch (error) {
    await client.close();
    throw error;
  }
}

export function exposedToolSchemas(tools, lane) {
  return tools.map((original) => {
    const tool = structuredClone(original);
    if (lane === "legacy" && !legacyRoutes.has(tool.name)) {
      tool.description = `Outside the disposable workflow's background authority. This product tool is listed for inventory and will be refused.`;
    } else if (lane === "legacy" && !legacyDiscovery.has(tool.name)) {
      tool.description = `${tool.description} This workflow requires an exact owned windowId. Use an exact selector identifier for input.`;
      tool.inputSchema.required = [...new Set([...(tool.inputSchema.required ?? []), "windowId"])];
    } else if (lane !== "legacy") {
      tool.inputSchema.properties.budgetMs = { ...tool.inputSchema.properties.budgetMs, minimum: 1, maximum: budgetMs, default: budgetMs };
      if (lane === "single" && tool.name === "act") {
        tool.description = "Execute one typed step using the retained observation and target.";
        tool.inputSchema.properties.steps.maxItems = 1;
      }
    }
    return tool;
  });
}

// The campaign owns the backend connection and this ledger for the whole trial.
// The agent-facing stdio process has no authority to restart the connection.
export class WorkflowLane {
  constructor({ lane, client, tools, readFixture, before, plan }) {
    this.lane = lane;
    this.client = client;
    this.tools = exposedToolSchemas(tools, lane);
    this.readFixture = readFixture;
    this.before = before;
    this.fields = new Map(plan.fields.map(f => [f.id, { kind: f.kind, label: f.label }]));
    this.fault = plan.config.friction;
    this.calls = [];
    this.observations = new Map();
    this.legacyObservations = new Map();
    this.ledger = new Map();
    this.stopped = false;
    const ajv = new AjvJsonSchemaValidator(new Ajv2020({ strict: false, validateFormats: false }));
    this.validators = new Map(this.tools.map(tool => [tool.name, ajv.getValidator(tool.inputSchema)]));
  }

  async backend(name, args) {
    return this.client.callTool({ name, arguments: args }, undefined, { timeout: 9000 });
  }

  async call(name, input = {}) {
    const entry = { name, args: input, sequence: this.calls.length + 1 };
    this.calls.push(entry);
    const started = performance.now();
    try {
      if (this.stopped) throw new Error("Trial tool admission has ended");
      // Do not interleave a fresh observation with a mutation whose effect has not settled.
      if (this.active) throw new Error("Another tool call is in flight. Wait for its result before trying again.");
      const validate = this.validators.get(name);
      if (!validate || !validate(input).valid) throw new Error("Invalid lane tool arguments");
      this.active = this.dispatch(entry, name, input);
      try { entry.result = await this.active; }
      finally { this.active = null; }
    } catch (error) {
      entry.result = entry.handedOff
        ? { ...jsonText({ code: "lane_transport_error", delivery: "unknown", message: "Tool result unavailable. Re-observe before deciding." }), isError: true }
        : refuse(error.message);
      entry.infrastructureError = entry.handedOff ? error.message : undefined;
    } finally { entry.elapsedMs = performance.now() - started; }
    return entry.result;
  }

  ownedWindow(state, windowId) {
    if (state.pid !== this.before.pid || state.runNonce !== this.before.runNonce) throw new Error("Owned fixture process changed");
    return state.windows.find(w => w.windowId === windowId && w.visible);
  }

  async dispatch(entry, name, input) {
    const state = await this.readFixture();
    if (state.pid !== this.before.pid || state.runNonce !== this.before.runNonce) throw new Error("Owned fixture process changed");
    const legacy = this.lane === "legacy";
    const args = { ...input };
    let mutations = [];
    let windowId;
    if (legacy) {
      if (!legacyRoutes.has(name)) throw new Error("Tool is outside the fixture background authority");
      if (args.appName != null || args.targetApp != null) throw new Error("Use an exact owned windowId, without app aliases");
      windowId = args.windowId;
      if (!legacyDiscovery.has(name)) {
        const window = this.ownedWindow(state, windowId);
        if (!window) throw new Error("Window is outside the live fixture");
        const listing = payload(await this.backend("list_windows", { includeAll: true }));
        if (!Array.isArray(listing) || !listing.some(w => w.pid === state.pid && w.windowId === windowId && w.title === window.title)) {
          throw new Error("Current legacy window ownership could not be verified");
        }
      }
      if (name === "list_windows") args.includeAll = true;
      if (name === "wait_for_accessibility") args.timeoutMs = Math.min(args.timeoutMs ?? budgetMs, budgetMs);
      if (name === "wait_for_text") args.timeoutSeconds = Math.max(0.1, Math.min(args.timeoutSeconds ?? 3, 3));
      if (name === "screenshot") args.maxWidth = Math.max(1, Math.min(args.maxWidth ?? 960, 960));
      if (["set_accessibility_value", "perform_accessibility_action"].includes(name)) {
        const id = args.selector?.identifier;
        if (!id || Object.keys(args.selector).some(key => key !== "identifier" && key !== "role")) throw new Error("Use an exact control identifier");
        const observed = this.legacyObservations.get(windowId);
        const control = observed?.elements.find(element => element.identifier === id);
        if (!control) throw new Error("Inspect the owned window and control before input");
        const press = name === "perform_accessibility_action";
        if (press && args.action !== "press") throw new Error("Only semantic press is allowed for this workflow");
        if (!press && Buffer.byteLength(args.value) > 65536) throw new Error("Text must fit the workflow AX value limit");
        mutations = [{ index: 0, id, kind: press ? "press" : "setValue", control, observed }];
      }
    } else {
      if (!rebuiltRoutes.has(name)) throw new Error("Tool is outside the fixture background authority");
      windowId = args.target?.windowId;
      if (!["targets", "capabilities"].includes(name)) {
        const closedWait = name === "waitFor" && args.condition?.kind === "windowAbsent" &&
          this.before.windows.some(w => w.key === "work" && w.windowId === windowId);
        if (args.target?.pid !== state.pid || (!this.ownedWindow(state, windowId) && !closedWait)) throw new Error("Target is outside the owned fixture");
      }
      if (name === "act" || name === "waitFor") {
        const observed = this.observations.get(args.observationId);
        if (observed?.windowId !== windowId || !observed) throw new Error("Observe this exact target before acting or waiting");
        if (name === "act") {
          validateActionSteps(args.steps, this.lane === "single" ? 1 : 16);
          validateFeedbackRefs(args.feedback, new Set(observed.elements.map(e => e.reference)));
          mutations = args.steps.flatMap((step, index) => {
            const { kind, params } = step.operation;
            if (kind === "waitFor") return [];
            const control = observed.elements.find(e => e.reference === params.elementRef);
            if (!control || !["setValue", "typeText", "press"].includes(kind)) throw new Error("Use a supported action on a control from this observation");
            if (kind === "typeText" && Buffer.byteLength(params.text) > 65536) throw new Error("Text must fit the workflow AX value limit");
            return [{ index, id: control.identifier, kind, control, observed }];
          });
        }
      }
    }

    this.admit(mutations, state, windowId);
    if (this.stopped) throw new Error("Trial tool admission has ended");
    entry.handedOff = true;
    entry.mutations = mutations.map(({ index, id, kind }) => ({ index, id, kind }));
    let result;
    try { result = await this.backend(name, args); }
    finally { this.record(mutations, state, entry.sequence, args, result); }
    if (legacy && name === "list_windows") {
      const listed = payload(result);
      if (!Array.isArray(listed)) throw new Error("Legacy window discovery unavailable");
      return jsonText(listed.filter(w => w.pid === state.pid && w.isOnScreen !== false && this.ownedWindow(state, w.windowId)));
    }
    if (legacy && name === "get_active_app") return jsonText({ fixtureForeground: payload(result)?.pid === state.pid });
    if (legacy && mutations.length && !result.isError) {
      const reply = payload(result);
      return jsonText({ ...reply, foreground: { preserved: reply.foreground?.preserved } });
    }
    if (!legacy && name === "targets") {
      const body = payload(result);
      if (nativeKind(result) !== "targets") return result;
      const targets = data(result).targets.filter(t => t.key.pid === state.pid && this.ownedWindow(state, t.key.windowId));
      // Both MCP content representations must be scoped, including the legacy text fallback.
      const scoped = { ...body, body: { ...body.body, data: { ...data(result), targets } } };
      return { ...jsonText(scoped), structuredContent: scoped };
    }
    if (!result.isError) {
      if (legacy && name === "inspect_accessibility") {
        const elements = payload(result)?.elements;
        if (Array.isArray(elements)) this.legacyObservations.set(windowId, { elements, sequence: entry.sequence });
      } else if (!legacy) {
        const observation = nativeKind(result) === "observe" ? data(result) : nativeKind(result) === "waitFor" ? data(result)?.observation : null;
        if (observation) this.observations.set(observation.observationId, { elements: observation.elements, windowId, sequence: entry.sequence });
      }
    }
    return result;
  }

  admit(mutations, state, windowId) {
    if (new Set(mutations.map(m => m.id)).size !== mutations.length) throw new Error("Use each control at most once in a request");
    const work = state.windows.find(w => w.key === "work" && w.visible);
    for (const mutation of mutations) {
      const { id, kind, control, observed } = mutation;
      const navigation = /^settings\.tab\.[012]$/.test(id);
      const action = this.fields.get(id);
      if (work?.windowId !== windowId || (!action && !(navigation || id === "invoice.submit")) ||
          ((kind === "press") !== (action?.kind === "checkbox" || navigation || id === "invoice.submit"))) {
        throw new Error("Input must match an owned workflow field, page button or Submit");
      }
      const previous = this.ledger.get(id);
      if (!previous || previous.delivery === "not_dispatched") continue;
      if (navigation && previous.delivery === "dispatched") continue;
      const clearedAfterKnownDispatch = id === this.fault?.cleared && previous.delivery === "dispatched" &&
        previous.attempts === 1 && observed.sequence > previous.sequence && control.value === "" && state.values[id] === "" &&
        observed.elements.some(element => typeof element.value === "string" && element.value.startsWith(`Validation cleared ${action?.label}.`)) &&
        state.events.slice(previous.eventCount).some(event => event.kind === "validation_cleared" && event.id === id && event.generation === state.generations[id]);
      if (!clearedAfterKnownDispatch) throw new Error("Input is already dispatched or uncertain for this control. Reconcile by reading; do not replay.");
    }
  }

  record(mutations, state, sequence, args, result) {
    if (!mutations.length) return;
    const receipt = nativeKind(result) === "act" ? data(result) : null;
    const correlated = this.lane !== "legacy" && correlatedPrefix(args, receipt);
    const host = result?.structuredContent;
    const hostRefusedBeforeDispatch = this.lane !== "legacy" && result?.isError && host?.version === 1 &&
      host.route === "rust_host" && host.delivery === "not_dispatched" && host.verification === "unverified" &&
      ["resourceLimit", "deadlineExceeded"].includes(host.error?.code) && host.uncertainty === undefined;
    for (const { index, id } of mutations) {
      const legacyReply = this.lane === "legacy" ? payload(result) : null;
      const legacyDispatch = (!result?.isError && legacyReply?.result?.status === "ok") ||
        legacyReply?.code === "ACCESSIBILITY_VALUE_UNCONFIRMED";
      const delivery = correlated ? receipt.steps[index]?.delivery ?? "not_dispatched" : hostRefusedBeforeDispatch ? "not_dispatched" :
        legacyDispatch ? "dispatched" : "unknown";
      const previous = this.ledger.get(id);
      if (delivery === "not_dispatched" && previous?.delivery === "dispatched") continue;
      this.ledger.set(id, { delivery, sequence, eventCount: state.events.length,
        attempts: (previous?.attempts ?? 0) + Number(delivery !== "not_dispatched") });
    }
  }

  async stop() {
    this.stopped = true;
    await this.active?.catch(() => {});
    await this.client.close();
  }
}
