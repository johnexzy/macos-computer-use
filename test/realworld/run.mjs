// Actual TextEdit actuator. Scripted mode is an oracle-informed reference controller, never a model-success result.
import fs from "node:fs/promises";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { parseArgs } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";
import Ajv2020 from "ajv/dist/2020.js";
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv";
import { createWorkspace, textEditAvailability, openTextEditSetup } from "./workspace.mjs";
import { judgeFiles, gradeTrial } from "./oracle.mjs";
import { RealworldBoundary, ProposalRejected, payload, data, nativeKind, ownedTargets, bindDocuments, filterTargetResult, selectControls, realworldTools, boundedHistory, targetClosureProof, reconcileFinalMonitor } from "./controller.mjs";
import { apiKeyEnvironment, preflightClaude, invokeClaude, ModelBudget } from "../evaluation/model.mjs";
import { usageSummary } from "../evaluation/metrics.mjs";
import { distribution } from "../baseline/metrics.mjs";
import { buildForegroundMonitor, ForegroundMonitor } from "../runtime/support/foreground-monitor.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const hash = (value) => createHash("sha256").update(value).digest("hex");
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const admissionReserveMs = 20000;
const absence = { kind: "windowAbsent", params: {} };
const systemPrompt = "Control only the six owned disposable TextEdit documents through the supplied actual MCP tools. Return one JSON command. Observe each document immediately before editing it. Select its sole AXTextArea and the AXButton with subrole AXCloseButton; never guess by coordinates, label, or child order. Replace only the requested summary block while preserving every other byte. Use setValue, then press the original close button with expect windowAbsent. The reference document is read-only and must stay open until grading. Never replay sent, unknown, unverified or already-satisfied input; observe/wait or finish incomplete. Every tool proposal needs budgetMs between1 and3000. A rejected proposal was not dispatched and can be corrected. Native failures are not proof of success. Finish complete only after all six documents are verified closed and saved; no OS, filesystem, browser, keyboard or script tool is available.";

export function configuration(argv) {
  const { values } = parseArgs({ args: argv, options: { mode: { type: "string", default: "scripted" }, lane: { type: "string", default: "composed" }, repetitions: { type: "string", default: "1" }, seed: { type: "string", default: "dispatch" }, output: { type: "string" },
    "budget-usd": { type: "string" }, "per-call-usd": { type: "string", default: "0.1" }, "max-turns": { type: "string", default: "32" },
    "api-key-file": { type: "string" }, claude: { type: "string", default: "claude" }, model: { type: "string", default: "claude-sonnet-5" } } });
  const repetitions = Number(values.repetitions), maxTurns = Number(values["max-turns"]), budgetUsd = values["budget-usd"] === undefined ? null : Number(values["budget-usd"]), perCallUsd = Number(values["per-call-usd"]);
  if (!["scripted", "model"].includes(values.mode) || !["single", "composed", "both"].includes(values.lane) || !Number.isInteger(repetitions) || repetitions < 1 || repetitions > 5 || !Number.isInteger(maxTurns) || maxTurns < 1 || maxTurns > 32 || !values.seed.length) throw new Error("Invalid realworld configuration");
  if (values.mode === "model" && (!(budgetUsd > 0 && budgetUsd <= 2.64089675) || !(perCallUsd > 0 && perCallUsd <= budgetUsd))) throw new Error("Model mode requires an explicit positive budget within the remaining USD2.64089675");
  return { mode: values.mode, lane: values.lane, repetitions, seed: values.seed, maxTurns, budgetUsd, perCallUsd,
    output: values.output, apiKeyFile: values["api-key-file"], claude: values.claude, model: values.model, episodeMs: 180000 };
}
export function summarizeTrials(episodes, probe = []) {
  const passed = episodes.filter((e) => e.outcome === "passed").length;
  return { assigned: episodes.length, passed, failed: episodes.filter((e) => e.outcome === "failed").length, unknown: episodes.filter((e) => e.outcome === "unknown").length,
    setupBlocked: episodes.filter((e) => e.outcome === "setup_blocked").length, pending: episodes.filter((e) => e.outcome === "not_started").length, strictCompletions: episodes.filter((e) => e.strictCompletion === true).length,
    strictSuccessPerAssigned: episodes.length ? passed / episodes.length : null,
    falseStrictCompletionClaims: episodes.filter((e) => e.falseStrictCompletionClaim).length,
    unknownCompletionClaims: episodes.filter((e) => e.unknownCompletionClaim).length, cleanupErrors: episodes.filter((e) => e.cleanupError).length,
    fullTaskMs: distribution(episodes.filter((e) => e.elapsedMs != null).map((e) => e.elapsedMs)),
    modelDecisions: distribution(episodes.filter((e) => e.modelTurns?.length).map((e) => e.modelTurns.length)),
    toolCalls: distribution(episodes.filter((e) => e.elapsedMs != null).map((e) => e.toolCalls)),
    resultBytes: distribution(episodes.filter((e) => e.elapsedMs != null).map((e) => e.responseBytes ?? 0)),
    safetyGate: episodes.some((e) => e.cleanupError || ["unknown", "setup_blocked", "not_started"].includes(e.outcome)) ? "incomplete" : episodes.some((e) => e.outcome === "failed") ? "failed" : "passed",
    model: usageSummary([...probe, ...episodes.flatMap((e) => e.modelTurns ?? [])]) };
}
async function until(probe, ms = 10000) {
  const end = performance.now() + ms;
  while (performance.now() < end) { const result = await probe(); if (result) return result; await pause(25); }
  throw new Error("Bounded owned-document readiness did not complete");
}
class Connection {
  constructor(traceMetadata) { this.traceMetadata = traceMetadata; this.phase = "setup"; }
  async connect() {
    const [{ Client }, { StdioClientTransport }] = await Promise.all([import("@modelcontextprotocol/sdk/client/index.js"), import("@modelcontextprotocol/sdk/client/stdio.js")]);
    this.transport = new StdioClientTransport({ command: path.join(root, ".artifacts/runtime-install/useui"), args: [], cwd: root, stderr: "pipe" });
    const send = this.transport.send.bind(this.transport);
    this.transport.send = async (message) => {
      await this.traceMetadata({ phase: this.phase, event: "mcp_request", id: message.id ?? null, method: message.method, tool: message.params?.name ?? null });
      return send(message);
    };
    this.stderrBytes = 0;
    this.client = new Client({ name: "textedit-dispatch-benchmark", version: "1" });
    await this.client.connect(this.transport);
    this.transport.stderr?.on("data", (bytes) => { this.stderrBytes += bytes.length; });
    const receive = this.transport.onmessage;
    this.transport.onmessage = (message) => {
      void this.traceMetadata({ phase: this.phase, event: "mcp_response", id: message.id ?? null, errorCode: message.error?.code ?? null,
        nativeId: message.result?.structuredContent?.id ?? null, nativeEpoch: message.result?.structuredContent?.epoch ?? null });
      receive?.(message);
    };
    this.tools = (await this.client.listTools()).tools;
  }
  call(name, args, timeout = 8000) { return this.client.callTool({ name, arguments: args }, undefined, { timeout }); }
  async close() { await this.client?.close(); }
}
export function referenceCommand(workspace, boundary, lastFailure) {
  if (lastFailure) return { kind: "finish", claim: "incomplete", reason: "Reference action failed; no automatic input retry" };
  for (const document of boundary.documents.filter((d) => d.role === "target")) {
    if (boundary.closed.has(document.documentId)) continue;
    const original = boundary.original.get(document.documentId);
    if (!original) return { kind: "tool", tool: "observe", args: { target: document.target, includeValues: true, budgetMs: 3000 } };
    const source = workspace.privateManifest.files.find((f) => f.documentId === document.documentId);
    const set = { actionId: `write-${document.documentId}`, operation: { kind: "setValue", params: { elementRef: original.controls.text.reference, value: source.expectedText } } };
    const close = { actionId: `close-${document.documentId}`, operation: { kind: "press", params: { elementRef: original.controls.close.reference } }, expect: absence };
    const content = boundary.ledger.controls.get(`${document.documentId}:content`);
    const steps = content?.verification === "confirmed" ? [close] : boundary.lane === "composed" ? [set, close] : [set];
    return { kind: "tool", tool: "act", args: { target: document.target, observationId: original.observationId, steps, budgetMs: 3000 } };
  }
  return { kind: "finish", claim: "complete", reason: "Reference controller submitted and verified all six closes" };
}

export async function runCampaign(config) {
  const output = path.resolve(config.output ?? path.join(root, ".artifacts/realworld", new Date().toISOString().replaceAll(":", "-")));
  await fs.mkdir(path.dirname(output), { recursive: true, mode: 0o700 });
  await fs.mkdir(output, { mode: 0o700 }); // A campaign never overwrites evidence from an earlier run.
  const traceFile = await fs.open(path.join(output, "trace.jsonl"), "wx", 0o600);
  const modelDirectory = path.join(output, ".claude-empty");
  if (config.mode === "model") await fs.mkdir(modelDirectory, { mode: 0o700 });
  let writing = Promise.resolve();
  const trace = (event) => { writing = writing.then(() => traceFile.appendFile(JSON.stringify({ at: new Date().toISOString(), ...event }) + "\n")); return writing; };
  const lanes = config.lane === "both" ? ["single", "composed"] : [config.lane];
  const episodes = [];
  for (let repeat = 0; repeat < config.repetitions; repeat++) for (const lane of repeat % 2 ? [...lanes].reverse() : lanes) episodes.push({ lane, repeat, seed: `${config.seed}:${repeat}`, outcome: "not_started", modelTurns: [], toolCalls: 0, controllerRejections: 0, nativeReceipts: [] });
  const report = { schemaVersion: 1, campaignId: randomUUID(), startedAt: new Date().toISOString(), mode: config.mode,
    claimScope: config.mode === "scripted" ? "Private-oracle-informed actuator conformance; no autonomous/model task success claim" : "Small matched model task comparison in actual TextEdit",
    options: { lane: config.lane, repetitions: config.repetitions, seed: config.seed, maxControllerDecisions: config.maxTurns, episodeMs: config.episodeMs, nativeBudgetMs: 3000 },
    systemPromptSha256: hash(systemPrompt),
    source: { revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(), dirty: Boolean(execFileSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" }).trim()) },
    app: await textEditAvailability(), model: { runs: false, requested: config.mode === "model" ? config.model : null, resolved: null, probe: null,
      accounting: "Global summary includes the pin probe once; per-lane summaries contain task calls only" }, episodes,
    notes: ["Public model context excludes private expected outputs and unrelated TextEdit windows.", "Setup uses public open -g -n only; all graded mutations use the actual typed MCP API. No Save or OS-script fallback exists.", "File bytes are an independent persistence oracle. Separate read-only MCP decoy inspection and post-cleanup bytes supplement them; they do not make AX readback an independent observer.", "Foreground policy requires a known continuous monitor with no new controlled-target activation; unrelated app changes are diagnostics.", "Model decisions, CLI turns, tool calls, typed receipts and physical file writes are different measures. CLI costs are estimates, not invoices or hard provider caps."] };
  for (const file of [".artifacts/runtime-install/useui", ".artifacts/runtime-install/useui-runtime", "test/realworld/dataset.mjs", "test/realworld/workspace.mjs", "test/realworld/oracle.mjs", "test/realworld/controller.mjs", "test/realworld/run.mjs", "test/evaluation/model.mjs", "test/evaluation/adapters.mjs", "test/runtime/support/foreground-monitor.swift"]) {
    try { report.source[file] = hash(await fs.readFile(path.join(root, file))); }
    catch { report.source[file] = null; }
  }
  const budget = config.mode === "model" ? new ModelBudget(config.budgetUsd, config.perCallUsd) : null;
  let modelEnv, globalBlocked = !report.app.available ? "TextEdit metadata unavailable" :
    report.source[".artifacts/runtime-install/useui"] == null || report.source[".artifacts/runtime-install/useui-runtime"] == null ? "Installed runtime pair unavailable" : null, monitorBinary;
  const probeTurns = [];
  for (const episode of episodes) {
    let workspace, connection, monitor, boundary, started, documents, finalMonitor;
    const event = (entry) => trace({ lane: episode.lane, repeat: episode.repeat, phase: started == null ? "setup" : "case", ...entry });
    const raw = async (name, args, phase = started == null ? "setup" : "case") => {
      const began = performance.now(); let result, failure;
      if (["case", "oracle"].includes(phase) && started != null && began - started >= config.episodeMs) throw new Error("Episode deadline expired before tool admission");
      if (phase === "case") {
        episode.toolCalls++;
        if (name === "act") {
          episode.submittedActSteps = (episode.submittedActSteps ?? 0) + args.steps.length;
          episode.submittedMutationSteps = (episode.submittedMutationSteps ?? 0) + args.steps.filter((s) => s.operation.kind !== "waitFor").length;
        }
      }
      else episode[`${phase}ToolCalls`] = (episode[`${phase}ToolCalls`] ?? 0) + 1;
      try {
        connection.phase = phase;
        const timeout = started != null && ["case", "oracle"].includes(phase) ? Math.min(8000, config.episodeMs - (began - started)) : 8000;
        result = await connection.call(name, args, timeout);
        if (name === "targets") result = filterTargetResult(result, workspace.publicManifest);
        if (phase === "case") episode.responseBytes = (episode.responseBytes ?? 0) + Buffer.byteLength(JSON.stringify(result));
        return result;
      } catch (error) { failure = error.message; throw error; }
      finally { await trace({ lane: episode.lane, repeat: episode.repeat, phase, event: "tool_call", name, args, result, error: failure, elapsedMs: performance.now() - began }); }
    };
    try {
      if (globalBlocked) throw new Error(globalBlocked);
      const setupStarted = performance.now();
      workspace = await createWorkspace({ parentDirectory: path.join(output, "workspaces"), seed: episode.seed });
      episode.workspace = workspace.directory; episode.publicManifest = workspace.publicManifest;
      episode.privateManifestSha256 = hash(await fs.readFile(path.join(workspace.directory, "manifest.private.json")));
      await openTextEditSetup(workspace.directory);
      connection = new Connection(event); await connection.connect();
      episode.tools = realworldTools(episode.lane, connection.tools);
      const schema = new AjvJsonSchemaValidator(new Ajv2020({ strict: false, validateFormats: false, allErrors: true }));
      const validators = new Map(episode.tools.map((t) => [t.name, schema.getValidator(t.inputSchema)]));
      documents = await until(async () => {
        try { return bindDocuments(ownedTargets(await raw("targets", { bundleId: "com.apple.TextEdit", budgetMs: 3000 }), workspace.publicManifest), workspace.publicManifest); }
        catch { return null; }
      }, 15000);
      episode.ownedDocuments = documents;
      boundary = new RealworldBoundary(episode.lane, documents);
      await until(async () => {
        try {
          for (const document of documents) {
            const result = await raw("observe", { target: document.target, includeValues: true, budgetMs: 3000 });
            if (nativeKind(result) !== "observe" || result.isError) return false;
            const controls = selectControls(data(result));
            const initial = workspace.privateManifest.files.find((f) => f.documentId === document.documentId).initialText;
            if (controls.text.value !== initial) throw new Error("Owned text content does not match the seeded initial document");
          }
          return true;
        } catch { return false; }
      }, 15000);
      episode.capabilityPreflightPassed = true;
      if (config.mode === "model" && !report.model.resolved) {
        modelEnv = await apiKeyEnvironment(config.apiKeyFile);
        const preflight = await preflightClaude(config.claude, modelEnv);
        if (!preflight.available) { globalBlocked = "Claude preflight unavailable"; throw new Error(globalBlocked); }
        const allowance = budget.allowance(); if (allowance === null) { globalBlocked = "Model budget cannot admit a probe"; throw new Error(globalBlocked); }
        const probe = await invokeClaude({ binary: config.claude, model: config.model, budgetUsd: allowance, systemPrompt,
          prompt: "Readiness probe only: finish incomplete with no tool or arguments.", cwd: modelDirectory, env: modelEnv });
        budget.record(probe); probeTurns.push(probe); report.model.probe = probe; report.model.runs = true; await event({ event: "model_pin_probe", result: probe });
        if (!probe.generationOk || !probe.ok || !budget.measured || budget.summary().exceeded) { globalBlocked = probe.error || "Model probe failed"; throw new Error(globalBlocked); }
        report.model.resolved = probe.model;
      }
      monitorBinary ??= await buildForegroundMonitor(); monitor = new ForegroundMonitor(monitorBinary);
      const initialMonitor = await monitor.begin(documents[0].target.pid);
      if (!initialMonitor.available || initialMonitor.truncated || initialMonitor.startedForegroundPID === documents[0].target.pid) throw new Error("Known background foreground-monitor baseline is required");
      episode.setupMs = performance.now() - setupStarted; episode.monitorInitial = initialMonitor;
      const history = []; let lastFailure = false;
      started = performance.now();
      for (let decision = 0; decision < config.maxTurns; decision++) {
        const remaining = config.episodeMs - (performance.now() - started);
        if (remaining <= admissionReserveMs) throw new Error("Episode budget cannot admit another decision/tool/oracle");
        let command; episode.controllerDecisions = decision + 1;
        if (config.mode === "model") {
          const allowance = budget.allowance(); if (allowance === null) { globalBlocked = "Model budget exhausted or unmeasured"; throw new Error(globalBlocked); }
          const prompt = JSON.stringify({ task: workspace.publicManifest, ownedTargets: documents, tools: episode.tools, history: boundedHistory(history), mutationLedger: boundary.ledger.snapshot(), remainingMs: remaining });
          const promptSha256 = hash(prompt), promptBytes = Buffer.byteLength(prompt);
          const result = await invokeClaude({ binary: config.claude, model: report.model.resolved, pinnedModel: report.model.resolved, budgetUsd: allowance,
            systemPrompt, prompt,
            cwd: modelDirectory, env: modelEnv, timeoutMs: Math.min(60000, remaining - admissionReserveMs) });
          budget.record(result); episode.modelTurns.push(result); await event({ event: "model_turn", decision, promptSha256, promptBytes, systemPromptSha256: report.systemPromptSha256, result });
          if (!result.generationOk || !budget.measured || budget.summary().exceeded) { globalBlocked = result.error || "Model call failed or exceeded budget"; throw new Error(globalBlocked); }
          if (result.commandError) { episode.controllerRejections++; history.push({ kind: "controller_rejection", feedback: result.commandError }); continue; }
          command = result.command;
        } else command = referenceCommand(workspace, boundary, lastFailure);
        episode.controllerDecisions = decision + 1; await event({ event: "command", decision, command });
        if (command.kind === "finish") { episode.completionClaim = command.claim; break; }
        try {
          const validate = validators.get(command.tool);
          if (!validate) throw new ProposalRejected("unsupported_tool", "Tool is outside this real-app workload");
          const valid = validate(command.args); if (!valid.valid) throw new ProposalRejected("invalid_arguments", valid.errorMessage);
          const mutations = boundary.validate(command.tool, command.args);
          if (config.episodeMs - (performance.now() - started) <= admissionReserveMs) throw new Error("Episode budget cannot admit tool plus oracle");
          let result;
          try { result = await raw(command.tool, command.args); }
          finally { boundary.record(command.tool, command.args, mutations, result); }
          history.push({ command, result });
          if (nativeKind(result) === "act") episode.nativeReceipts.push(...data(result).steps);
          lastFailure = result.isError === true || (nativeKind(result) === "act" && data(result).stopReason !== "completed");
        } catch (error) {
          if (error instanceof ProposalRejected) { episode.controllerRejections++; history.push({ command, kind: "controller_rejection", feedback: error.feedback }); await event({ event: "controller_rejection", feedback: error.feedback }); }
          else throw error;
        }
      }
      const targetsClosed = targetClosureProof(boundary);
      const decoy = documents.find((d) => d.role === "decoy");
      const decoyResult = await raw("observe", { target: decoy.target, includeValues: true, budgetMs: 3000 }, "oracle");
      const decoyInitial = workspace.privateManifest.files.find((f) => f.role === "decoy").initialText;
      episode.decoyReadOnlyPreserved = null;
      if (nativeKind(decoyResult) === "observe" && !decoyResult.isError) {
        const texts = data(decoyResult).elements.filter((e) => e.role === "AXTextArea");
        if (texts.length === 1 && typeof texts[0].value === "string") episode.decoyReadOnlyPreserved = texts[0].value === decoyInitial;
      }
      episode.fileOracle = await judgeFiles(workspace.directory);
      finalMonitor = await monitor.snapshot(); episode.monitorFinal = finalMonitor;
      const foreground = !finalMonitor.available || finalMonitor.truncated ? null : finalMonitor.targetActivations === 0;
      episode.foregroundPolicy = "known_continuous_monitor_no_new_controlled_target_activation";
      episode.unrelatedActivationEvents = finalMonitor.events.filter((e) => e.pid !== documents[0].target.pid).length;
      Object.assign(episode, gradeTrial(episode.fileOracle, { targetWindowsClosed: targetsClosed, decoyWindowPreserved: episode.decoyReadOnlyPreserved,
        foregroundPreserved: foreground, withinBudget: performance.now() - started <= config.episodeMs, controllerCompleted: episode.completionClaim === "complete" }));
      episode.mutationLedger = boundary.ledger.snapshot();
      episode.falseStrictCompletionClaim = episode.completionClaim === "complete" && episode.strictCompletion === false;
      episode.unknownCompletionClaim = episode.completionClaim === "complete" && episode.strictCompletion == null;
    } catch (error) {
      episode.error = error.message; episode.outcome = started == null ? "setup_blocked" : "unknown";
      if (workspace) { try { episode.fileOracle = await judgeFiles(workspace.directory); } catch {} }
      if (monitor) { try { episode.monitorFinal = await monitor.snapshot(); } catch {} }
      if (boundary) episode.mutationLedger = boundary.ledger.snapshot();
    } finally {
      if (started != null) episode.elapsedMs = performance.now() - started;
      episode.actionAccounting = { plannedSemanticOperations: 12, submittedActSteps: episode.submittedActSteps ?? 0,
        submittedMutationSteps: episode.submittedMutationSteps ?? 0, processedReceiptSteps: episode.nativeReceipts.length,
        dispatchedReceiptSteps: episode.nativeReceipts.filter((s) => s.delivery === "dispatched").length,
        unknownReceiptSteps: episode.nativeReceipts.filter((s) => s.delivery === "unknown").length,
        notDispatchedReceiptSteps: episode.nativeReceipts.filter((s) => s.delivery === "not_dispatched").length,
        physicalFileWrites: null, note: "The real application has no custom write-attempt counter; disk-write counts are not inferred from final bytes." };
      // Grading is complete. Close only originally owned, provably unattempted close controls, including the reference.
      try {
        if (connection && documents && workspace && episode.capabilityPreflightPassed) {
          const cleanup = new RealworldBoundary("composed", documents);
          if (boundary) { cleanup.ledger = boundary.ledger; cleanup.closed = new Set(boundary.closed); }
          const catalog = await raw("targets", { bundleId: "com.apple.TextEdit", budgetMs: 3000 }, "cleanup");
          if (nativeKind(catalog) !== "targets" || catalog.isError) throw new Error("Cleanup discovery unavailable; owned outputs retained");
          const current = ownedTargets(catalog, workspace.publicManifest);
          for (const document of documents) {
            if (!current.some((t) => t.key.pid === document.target.pid && t.key.windowId === document.target.windowId)) continue;
            if (cleanup.ledger.blocked().has(`${document.documentId}:close`)) continue;
            const observed = await raw("observe", { target: document.target, includeValues: true, budgetMs: 3000 }, "cleanup");
            if (nativeKind(observed) !== "observe") continue;
            cleanup.register(data(observed)); const origin = cleanup.original.get(document.documentId);
            const args = { target: document.target, observationId: origin.observationId, budgetMs: 3000, steps: [{ actionId: `cleanup-${document.documentId}`, operation: { kind: "press", params: { elementRef: origin.controls.close.reference } }, expect: absence }] };
            const mutations = cleanup.validate("act", args, { cleanup: true }); let result;
            try { result = await raw("act", args, "cleanup"); } finally { cleanup.record("act", args, mutations, result); }
          }
          episode.cleanup = { filesRetained: true, directory: workspace.directory, knownWindowAbsenceProofs: cleanup.closed.size,
            unprovenDocumentIds: documents.filter((d) => !cleanup.closed.has(d.documentId)).map((d) => d.documentId) };
          const afterCleanup = await judgeFiles(workspace.directory); episode.postCleanupFileOracle = afterCleanup;
          if (episode.fileOracle?.decoyMatches === 1 && afterCleanup.decoyMatches !== 1) { episode.outcome = "failed"; episode.strictCompletion = false; episode.decoyCleanupContradiction = true; }
          if (episode.cleanup.unprovenDocumentIds.length) throw new Error("Some exact owned-window closures are unproven; outputs retained without replay");
        } else if (workspace) throw new Error("Ownership/capability gate was incomplete; workspace retained without cleanup input");
      } catch (error) { episode.cleanupError = error.message; }
      try {
        if (monitor) reconcileFinalMonitor(episode, await monitor.close());
      } catch (error) { episode.cleanupError ??= error.message; if (monitor) reconcileFinalMonitor(episode, null); }
      episode.filesRetained = Boolean(workspace);
      episode.falseStrictCompletionClaim = episode.completionClaim === "complete" && episode.strictCompletion === false;
      episode.unknownCompletionClaim = episode.completionClaim === "complete" && episode.strictCompletion == null;
      episode.drainedStderrBytes = connection?.stderrBytes ?? 0;
      try { await connection?.close(); } catch (error) { episode.cleanupError ??= error.message; }
      await event({ event: "episode_finished", outcome: episode.outcome, strictCompletion: episode.strictCompletion ?? null, cleanupError: episode.cleanupError ?? null });
      console.log(JSON.stringify({ lane: episode.lane, repeat: episode.repeat, outcome: episode.outcome, error: episode.error, cleanupError: episode.cleanupError }));
      report.summary = summarizeTrials(episodes, probeTurns); report.model.budget = budget?.summary() ?? null;
      await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    }
  }
  report.finishedAt = new Date().toISOString(); report.summary = summarizeTrials(episodes, probeTurns);
  report.byLane = Object.fromEntries(lanes.map((lane) => [lane, summarizeTrials(episodes.filter((e) => e.lane === lane))]));
  await writing; await traceFile.close();
  await fs.writeFile(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  return { output, report };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const result = await runCampaign(configuration(process.argv.slice(2)));
  console.log(JSON.stringify({ report: path.join(result.output, "report.json"), summary: result.report.summary }, null, 2));
  if (result.report.summary.failed || result.report.summary.unknown || result.report.summary.cleanupErrors) process.exitCode = 1;
  else if (result.report.summary.setupBlocked) process.exitCode = 2;
}
