import assert from "node:assert/strict";
import test from "node:test";
import { generateDataset } from "./dataset.mjs";
import { RealworldBoundary, bindDocuments, ownedTargets, filterTargetResult, selectControls, boundedHistory, targetClosureProof, reconcileFinalMonitor } from "./controller.mjs";
import { configuration, summarizeTrials, referenceCommand } from "./run.mjs";

const manifest = generateDataset({ seed: "controller-test", runId: "a9d68270-3d95-4bd4-9d05-78fdeaa6b60c" }).publicManifest;
const names = [...manifest.targets, ...manifest.protectedDocuments];
const targets = names.map((d, i) => ({ key: { pid: 42, windowId: i + 1 }, title: d.fileName, bundleId: "com.apple.TextEdit" }));
const result = (kind, data) => ({ isError: false, structuredContent: { version: 1, id: "r", epoch: "e", body: { result: kind, data } } });
const observation = (document, id = "origin") => ({ observationId: id, target: document.target, elements: [
  { reference: `${id}-text`, role: "AXTextArea", subrole: null, enabled: null, actions: ["setValue", "typeText"], value: "initial" },
  { reference: `${id}-close`, role: "AXButton", subrole: "AXCloseButton", label: null, enabled: true, actions: ["press"], value: null }
] });
const setup = (lane = "composed", now) => {
  const documents = bindDocuments(targets, manifest), boundary = new RealworldBoundary(lane, documents, now);
  boundary.register(observation(documents[0])); return { documents, boundary, document: documents[0] };
};
const set = (id = "set", ref = "origin-text") => ({ actionId: id, operation: { kind: "setValue", params: { elementRef: ref, value: "computed" } } });
const close = (id = "close", ref = "origin-close") => ({ actionId: id, operation: { kind: "press", params: { elementRef: ref } }, expect: { kind: "windowAbsent", params: {} } });
const evidence = [{ observationId: "check", condition: { kind: "valueEquals", params: { elementRef: "origin-text", value: "computed" } }, matched: true }];
const args = (document, steps = [set(), close()]) => ({ target: document.target, observationId: "origin", budgetMs: 3000, steps });

test("owned UUID discovery strips all unrelated TextEdit metadata including duplicate text content", () => {
  const foreign = { key: { pid: 9, windowId: 8 }, title: "Private personal document", bundleId: "com.apple.TextEdit" };
  const native = result("targets", { targets: [...targets, foreign], truncated: false });
  native.content = [{ type: "text", text: JSON.stringify(native.structuredContent) }];
  const filtered = filterTargetResult(native, manifest);
  assert.equal(ownedTargets(filtered, manifest).length, 7);
  assert.ok(!JSON.stringify(filtered).includes("Private personal"));
  assert.equal(bindDocuments(ownedTargets(filtered, manifest), manifest).length, 7);
  assert.throws(() => bindDocuments([...targets, targets[0]], manifest));
  assert.throws(() => bindDocuments(targets.slice(1), manifest));
});

test("capability gate uses nullable enabled and exact TextArea/CloseButton subrole rather than labels", () => {
  const { document } = setup(); const o = observation(document);
  assert.equal(selectControls(o).text.enabled, null);
  assert.equal(selectControls(o).close.label, null);
  assert.throws(() => selectControls({ ...o, elements: o.elements.map((e) => e.role === "AXButton" ? { ...e, subrole: "AXMinimizeButton" } : e) }));
  assert.throws(() => selectControls({ ...o, elements: [...o.elements, o.elements[0]] }));
  assert.throws(() => selectControls({ ...o, elements: o.elements.map((e) => ({ ...e, enabled: false })) }));
});

test("single lane, action IDs and wait guards are rejected before handoff", () => {
  const { boundary, document } = setup("single");
  assert.throws(() => boundary.validate("act", args(document)), /Action count/);
  assert.throws(() => boundary.validate("act", args(document, [set("")])), /nonblank/);
  const other = setup();
  assert.throws(() => other.boundary.validate("act", args(other.document, [set("same"), close("same")])), /unique/);
  assert.throws(() => other.boundary.validate("act", args(other.document, [{ actionId: "wait", operation: { kind: "waitFor", params: { condition: { kind: "windowAbsent", params: {} } } }, expect: { kind: "windowAbsent", params: {} } }])), /Wait steps/);
  assert.deepEqual(boundary.ledger.snapshot(), {});
});

test("only owned target originals can mutate; protected document, foreign PID and fresh reference aliases cannot", () => {
  const { boundary, document, documents } = setup();
  assert.equal(boundary.validate("act", args(document)).length, 2);
  assert.throws(() => boundary.validate("act", { ...args(document), target: { pid: 123, windowId: 1 } }));
  const decoy = documents.at(-1); boundary.register(observation(decoy, "decoy"));
  assert.throws(() => boundary.validate("act", { ...args(decoy), observationId: "decoy", steps: [set("decoy", "decoy-text")] }), /reference document/);
  boundary.register(observation(document, "fresh"));
  assert.throws(() => boundary.validate("act", { ...args(document), steps: [set("new", "fresh-text")] }), /original control/);
  assert.throws(() => boundary.validate("act", { ...args(document), observationId: "fresh", steps: [set("new", "fresh-text")] }), /original observation/);
});

test("close needs preceding verified content and an exact window absence requirement", () => {
  const { boundary, document } = setup();
  assert.throws(() => boundary.validate("act", args(document, [close()])), /Replace and verify/);
  assert.throws(() => boundary.validate("act", args(document, [set(), { ...close(), expect: null }])), /Close must require/);
  assert.throws(() => boundary.validate("act", args(document, [set(), { ...close(), operation: { kind: "press", params: { elementRef: "origin-text" } } }])), /AXCloseButton/);
  assert.throws(() => boundary.validate("act", args(document, [set(), set("again")])), /same control twice/);
});

test("unknown handoff and already-satisfied receipts block replay without confusing different controls", () => {
  const { boundary, document } = setup(); const request = args(document, [set()]);
  const mutations = boundary.validate("act", request);
  boundary.record("act", request, mutations, undefined);
  assert.throws(() => boundary.validate("act", request), /already has/);
  const { boundary: b, document: d } = setup(); const a = args(d, [set()]);
  b.record("act", a, b.validate("act", a), result("act", { observationId: "origin", steps: [{ actionId: "set", delivery: "not_dispatched", verification: "confirmed", reason: "alreadySatisfied", evidence }], remainingSteps: 0, stopReason: "completed" }));
  assert.throws(() => b.validate("act", a), /already has/);
  assert.equal(b.validate("act", args(d, [close()])).length, 1);
});

test("a proven unsent suffix remains correctable while the committed prefix cannot replay", () => {
  const { boundary, document } = setup(); const request = args(document); const m = boundary.validate("act", request);
  boundary.record("act", request, m, result("act", { observationId: "origin", steps: [{ actionId: "set", delivery: "dispatched", verification: "confirmed", reason: "deadlineExceeded", evidence }], remainingSteps: 1, stopReason: "deadlineExceeded" }));
  assert.throws(() => boundary.validate("act", args(document, [set()])), /already has/);
  assert.equal(boundary.validate("act", args(document, [close()])).length, 1);
  assert.equal(boundary.closed.size, 0);
});

test("a closed claim needs request-correlated receipt evidence and old references expire", () => {
  let time = 0; const { boundary, document } = setup("composed", () => time);
  const a = args(document), m = boundary.validate("act", a);
  boundary.record("act", a, m, result("act", { observationId: "wrong", steps: [{ actionId: "set", delivery: "dispatched", verification: "confirmed", evidence }, { actionId: "close", delivery: "dispatched", verification: "confirmed", evidence: [{ condition: { kind: "windowAbsent" }, matched: true }] }], remainingSteps: 0, stopReason: "completed" }));
  assert.equal(boundary.closed.size, 0);
  const fresh = setup("composed", () => time); time = 60000;
  assert.throws(() => fresh.boundary.validate("act", args(fresh.document)), /fresh original/);
});

test("scripted default never admits a model without explicit bounded budget, and missing trials remain assigned", () => {
  assert.equal(configuration([]).mode, "scripted");
  assert.throws(() => configuration(["--mode", "model"]), /explicit positive budget/);
  assert.throws(() => configuration(["--mode", "model", "--budget-usd", "3"]));
  assert.equal(configuration(["--mode", "model", "--budget-usd", "0.5"]).budgetUsd, 0.5);
  assert.throws(() => configuration(["--max-turns", "33"]));
  const summary = summarizeTrials([{ outcome: "passed", strictCompletion: true, elapsedMs: 100, toolCalls: 2, modelTurns: [] }, { outcome: "setup_blocked", modelTurns: [] }, { outcome: "unknown", elapsedMs: 500, toolCalls: 1, modelTurns: [] }]);
  assert.equal(summary.assigned, 3); assert.equal(summary.strictSuccessPerAssigned, 1 / 3);
  assert.equal(summary.model.reportedCostUsd, null); assert.equal(summary.safetyGate, "incomplete");
});

test("history is bounded without injecting private oracle output", () => {
  const h = boundedHistory([{ result: "a".repeat(40) }, { result: "b".repeat(40) }], 75);
  assert.equal(h.truncated, true); assert.equal(h.events.length, 1);
  assert.ok(!JSON.stringify(h).includes("expectedText"));
});


test("scripted reference performs exactly twelve meaningful operations across six documents", () => {
  const dataset = generateDataset({ seed: "controller-test", runId: "a9d68270-3d95-4bd4-9d05-78fdeaa6b60c" });
  for (const lane of ["single", "composed"]) {
    const documents = bindDocuments(targets, manifest), boundary = new RealworldBoundary(lane, documents);
    let decisions = 0, mutations = 0, finishes = 0;
    while (decisions < 32) {
      const command = referenceCommand(dataset, boundary, false); decisions++;
      if (command.kind === "finish") { assert.equal(command.claim, "complete"); finishes++; break; }
      const document = boundary.document(command.args.target);
      const input = boundary.validate(command.tool, command.args);
      if (command.tool === "observe") boundary.record("observe", command.args, input, result("observe", observation(document, document.documentId)));
      else {
        mutations += input.length;
        const steps = command.args.steps.map((step) => ({ actionId: step.actionId, delivery: "dispatched", verification: "confirmed", evidence: [{ observationId: "check", matched: true,
          condition: step.operation.kind === "press" ? { kind: "windowAbsent", params: {} } : { kind: "valueEquals", params: { elementRef: step.operation.params.elementRef, value: step.operation.params.value } }, collected: { startedUnixMs: 1, finishedUnixMs: 2 } }] }));
        boundary.record("act", command.args, input, result("act", { observationId: command.args.observationId, steps, remainingSteps: 0, stopReason: "completed" }));
      }
    }
    assert.equal(finishes, 1); assert.equal(mutations, 12); assert.equal(boundary.closed.size, 6);
    assert.equal(decisions, lane === "single" ? 19 : 13);
  }
});


test("hidden-window catalog absence cannot substitute for six exact close proofs", () => {
  const { boundary } = setup();
  assert.deepEqual(ownedTargets(result("targets", { targets: [], truncated: false }), manifest), []);
  assert.equal(targetClosureProof(boundary), null);
  assert.equal(boundary.closed.size, 0);
});

test("close capability requires positive enabled state, while textarea may remain unknown", () => {
  const { document } = setup(); const o = observation(document);
  assert.throws(() => selectControls({ ...o, elements: o.elements.map((e) => e.subrole === "AXCloseButton" ? { ...e, enabled: null } : e) }));
  assert.equal(selectControls(o).text.enabled, null);
});

test("satisfied readonly waits with hidden values do not replace original mutation identity or TTL", () => {
  let time = 0; const { boundary, document } = setup("composed", () => time);
  const privateRead = observation(document, "private-read");
  privateRead.elements[0].value = null;
  boundary.record("waitFor", { target: document.target, condition: { kind: "valueEquals", params: { elementRef: "origin-text", value: "initial" } } }, [],
    result("waitFor", { outcome: "satisfied", observation: privateRead }));
  assert.equal(boundary.original.get(document.documentId).observationId, "origin");
  assert.equal(boundary.refs.get("private-read-text").documentId, document.documentId);
  assert.equal(boundary.validate("act", args(document)).length, 2);
  time = 60000;
  assert.throws(() => boundary.validate("act", args(document)), /fresh original/);
});

test("unknown close cannot become a successful closure from positive state confirmation alone", () => {
  const { boundary, document } = setup(); const a = args(document), m = boundary.validate("act", a);
  boundary.record("act", a, m, result("act", { observationId: "origin", stopReason: "helperDied", remainingSteps: 0,
    steps: [{ actionId: "set", delivery: "dispatched", verification: "confirmed", evidence },
      { actionId: "close", delivery: "unknown", verification: "confirmed", reason: "helperDied", evidence: [{ matched: true, condition: { kind: "windowAbsent", params: {} }, collected: { startedUnixMs: 1, finishedUnixMs: 2 } }] }] }));
  assert.equal(boundary.closed.size, 0); assert.equal(targetClosureProof(boundary), null);
  assert.throws(() => boundary.validate("act", args(document, [close()])), /already has/);
});

test("late final monitor changes or unavailable stop proof cannot retain a strict pass", () => {
  const episode = () => ({ outcome: "passed", strictCompletion: true, monitorFinal: { available: true, targetActivations: 0 } });
  const late = reconcileFinalMonitor(episode(), { available: true, truncated: false, targetActivations: 1 });
  assert.equal(late.outcome, "unknown"); assert.equal(late.strictCompletion, null); assert.equal(late.lateActivationPhaseUncertain, true);
  const missing = reconcileFinalMonitor(episode(), null);
  assert.equal(missing.outcome, "unknown"); assert.equal(missing.finalMonitorUnjudgeable, true);
  assert.equal(reconcileFinalMonitor(episode(), { available: true, truncated: false, targetActivations: 0 }).strictCompletion, true);
});
