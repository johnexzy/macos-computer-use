import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { generateDataset, renderSummary, replaceSummary, summarizeFacts } from "./dataset.mjs";
import { createWorkspace, loadWorkspace, resetWorkspace, cleanupWorkspace, textEditOpenArguments } from "./workspace.mjs";
import { judgeFiles, gradeTrial } from "./oracle.mjs";

const runId = "b75b05b4-17ac-4f8c-a16f-f6b00ea45c30";
async function workspace(t, seed = "seed-1") {
  const parent = await fs.mkdtemp(path.join(os.tmpdir(), "cua-realworld-test-"));
  t.after(() => fs.rm(parent, { recursive: true, force: true }));
  return createWorkspace({ parentDirectory: parent, seed });
}
async function finishFiles(w) {
  for (const f of w.privateManifest.files) await fs.writeFile(path.join(w.documentsDirectory, f.fileName), f.expectedText);
}

test("six seeded real documents require arithmetic and status priority; expected bodies stay private", () => {
  const a = generateDataset({ seed: "alpha", runId }), b = generateDataset({ seed: "alpha", runId });
  assert.deepEqual(a, b);
  assert.notDeepEqual(a.privateManifest.files, generateDataset({ seed: "beta", runId }).privateManifest.files);
  assert.equal(a.publicManifest.targets.length, 6);
  assert.equal(a.privateManifest.files.length, 7);
  assert.equal(new Set(a.privateManifest.files.map((f) => f.fileName)).size, 7);
  assert.ok(a.publicManifest.protectedDocuments[0].fileName.startsWith(a.publicManifest.targets[0].fileName.slice(0, -4)));
  assert.deepEqual(a.privateManifest.files.filter((f) => f.role === "target").map((f) => summarizeFacts(f.facts).status), ["READY", "PACKING", "ON HOLD", "READY", "PACKING", "ON HOLD"]);
  const publicJSON = JSON.stringify(a.publicManifest);
  assert.ok(!publicJSON.includes("expectedText") && !publicJSON.includes("expectedSha256") && !publicJSON.includes("initialText") && !publicJSON.includes("unitPriceCents"));
  for (const f of a.privateManifest.files) assert.ok(Buffer.byteLength(f.expectedText) < 65_536);
});

test("summary arithmetic uses cents and a hold outranks a fully packed order", () => {
  const facts = { order: "DN-test", holdReason: "review", items: [
    { quantity: 3, unitPriceCents: 101, packed: 3 }, { quantity: 2, unitPriceCents: 999, packed: 2 }, { quantity: 1, unitPriceCents: 10000, packed: 1 }
  ] };
  assert.deepEqual(summarizeFacts(facts), { units: 6, packed: 6, subtotalCents: 12301, status: "ON HOLD" });
  assert.match(renderSummary(facts), /Subtotal: NGN 123\.01\nDispatch status: ON HOLD\n$/);
  assert.throws(() => replaceSummary("no markers", "summary"));
});

test("the exact file oracle grades all six targets and the protected decoy without app claims", async (t) => {
  const w = await workspace(t);
  let oracle = await judgeFiles(w.directory);
  assert.equal(oracle.expectedTargets, 6); assert.equal(oracle.targetMatches, 0); assert.equal(oracle.decoyMatches, 1);
  await finishFiles(w);
  oracle = await judgeFiles(w.directory);
  assert.equal(oracle.fileGoalSatisfied, true);
  assert.equal(oracle.targetMatches, 6); assert.equal(oracle.decoyMatches, 1);
  assert.equal(gradeTrial(oracle).outcome, "unknown");
  const complete = { targetWindowsClosed: true, decoyWindowPreserved: true, foregroundPreserved: true, withinBudget: true, controllerCompleted: true };
  assert.equal(gradeTrial(oracle, complete).strictCompletion, true);
  assert.equal(gradeTrial(oracle, { ...complete, foregroundPreserved: false }).strictCompletion, false);
});

test("changing a protected body byte fails even when the computed summary is right", async (t) => {
  const w = await workspace(t); await finishFiles(w);
  const f = w.privateManifest.files[0];
  await fs.writeFile(path.join(w.documentsDirectory, f.fileName), f.expectedText.replace("café", "cafe"));
  const result = await judgeFiles(w.directory);
  assert.equal(result.targetMatches, 5); assert.equal(result.fileGoalSatisfied, false);
  assert.equal(result.files[0].state, "content_mismatch");
  assert.ok(!JSON.stringify(result).includes(f.expectedText));
});

test("decoy writes and unexpected files remain failures with the full denominator", async (t) => {
  const w = await workspace(t); await finishFiles(w);
  const decoy = w.privateManifest.files.find((f) => f.role === "decoy");
  await fs.writeFile(path.join(w.documentsDirectory, decoy.fileName), "changed");
  await fs.writeFile(path.join(w.documentsDirectory, "unexpected.txt"), "unrelated");
  const r = await judgeFiles(w.directory);
  assert.equal(r.expectedTargets, 6); assert.equal(r.targetMatches, 6); assert.equal(r.decoyMatches, 0);
  assert.deepEqual(r.extraFiles, ["unexpected.txt"]); assert.equal(r.fileGoalSatisfied, false);
});

test("missing and linked targets are not silently excluded or read outside the owned root", async (t) => {
  const w = await workspace(t); await finishFiles(w);
  const [a, b] = w.privateManifest.files;
  await fs.unlink(path.join(w.documentsDirectory, a.fileName));
  await fs.unlink(path.join(w.documentsDirectory, b.fileName));
  const external = path.join(path.dirname(w.directory), "outside.txt");
  await fs.writeFile(external, "outside sentinel");
  await fs.symlink(external, path.join(w.documentsDirectory, b.fileName));
  const r = await judgeFiles(w.directory);
  assert.equal(r.expectedTargets, 6); assert.equal(r.targetMatches, 4);
  assert.equal(r.files[0].state, "missing"); assert.equal(r.files[1].state, "unsafe_file_type_or_owner");
  assert.equal(r.files[1].actualSha256, null);
  await assert.rejects(() => cleanupWorkspace(w.directory, { documentsClosed: true }));
  assert.equal(await fs.readFile(external, "utf8"), "outside sentinel");
});

test("reset restores the seeded input only after owned documents are confirmed closed", async (t) => {
  const w = await workspace(t); await finishFiles(w);
  await assert.rejects(() => resetWorkspace(w.directory));
  await resetWorkspace(w.directory, { documentsClosed: true });
  const r = await judgeFiles(w.directory);
  assert.equal(r.targetMatches, 0); assert.equal(r.decoyMatches, 1);
  assert.deepEqual((await loadWorkspace(w.directory)).publicManifest, w.publicManifest);
  await fs.writeFile(path.join(w.documentsDirectory, "unexpected.txt"), "keep");
  await assert.rejects(() => resetWorkspace(w.directory, { documentsClosed: true }));
});

test("cleanup keeps unrecognized files and can resume without recursively deleting them", async (t) => {
  const w = await workspace(t);
  assert.equal((await cleanupWorkspace(w.directory)).reason, "documents_not_confirmed_closed");
  const extra = path.join(w.documentsDirectory, "unrecognized.txt");
  await fs.writeFile(extra, "keep");
  const first = await cleanupWorkspace(w.directory, { documentsClosed: true });
  assert.equal(first.complete, false); assert.equal(first.removed.length, 7);
  assert.equal(await fs.readFile(extra, "utf8"), "keep");
  await fs.unlink(extra);
  assert.equal((await cleanupWorkspace(w.directory, { documentsClosed: true })).complete, true);
  assert.equal((await cleanupWorkspace(w.directory, { documentsClosed: true })).complete, true);
});

test("interrupted setup metadata is sufficient for scoped cleanup", async (t) => {
  const w = await workspace(t);
  await fs.unlink(path.join(w.directory, "manifest.public.json"));
  await fs.unlink(path.join(w.directory, "manifest.private.json"));
  assert.equal((await cleanupWorkspace(w.directory, { documentsClosed: true })).complete, true);
});

test("setup uses public background open with exact owned filenames; it is never run by pure tests", async (t) => {
  const w = await workspace(t);
  const args = textEditOpenArguments(w);
  assert.deepEqual(args.slice(0, 4), ["-g", "-n", "-a", "/System/Applications/TextEdit.app"]);
  assert.equal(args.length, 11);
  assert.deepEqual(args.slice(4), w.privateManifest.files.map((f) => path.join(w.documentsDirectory, f.fileName)));
});
