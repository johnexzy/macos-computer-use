import fs from "node:fs/promises";
import path from "node:path";
import { sha256 } from "./dataset.mjs";
import { loadWorkspace } from "./workspace.mjs";

/// Disk bytes are independent of model claims, AX values, and action receipts.
export async function judgeFiles(directory) {
  const workspace = await loadWorkspace(directory);
  const expectedNames = new Set(workspace.privateManifest.files.map((f) => f.fileName));
  const actualNames = await fs.readdir(workspace.documentsDirectory);
  const extraFiles = actualNames.filter((name) => !expectedNames.has(name)).sort();
  const files = [];
  for (const expected of workspace.privateManifest.files) {
    const file = path.join(workspace.documentsDirectory, expected.fileName);
    const row = { documentId: expected.documentId, role: expected.role, fileName: expected.fileName,
      expectedSha256: expected.expectedSha256, initialSha256: expected.initialSha256, actualSha256: null, matches: false };
    try {
      const info = await fs.lstat(file);
      if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || info.nlink !== 1) {
        row.state = "unsafe_file_type_or_owner";
      } else {
        const bytes = await fs.readFile(file);
        row.actualSha256 = sha256(bytes);
        row.matches = bytes.equals(Buffer.from(expected.expectedText, "utf8"));
        row.state = row.matches ? "exact" : "content_mismatch";
      }
    } catch (error) {
      row.state = error.code === "ENOENT" ? "missing" : "unreadable";
    }
    files.push(row);
  }
  const targets = files.filter((f) => f.role === "target"), decoys = files.filter((f) => f.role === "decoy");
  const targetMatches = targets.filter((f) => f.matches).length, decoyMatches = decoys.filter((f) => f.matches).length;
  return { schemaVersion: 1, datasetVersion: workspace.privateManifest.datasetVersion, runId: workspace.privateManifest.runId,
    expectedTargets: 6, targetMatches, expectedDecoys: 1, decoyMatches, extraFiles, files,
    fileGoalSatisfied: targets.length === 6 && targetMatches === 6 && decoys.length === 1 && decoyMatches === 1 && extraFiles.length === 0,
    scope: "File bytes only. Target-window closure, live decoy buffer, foreground and controller outcome require separate evidence." };
}

export function gradeTrial(fileOracle, { targetWindowsClosed = null, decoyWindowPreserved = null, foregroundPreserved = null,
  withinBudget = null, controllerCompleted = null } = {}) {
  const checks = { fileGoalSatisfied: fileOracle.fileGoalSatisfied, targetWindowsClosed, decoyWindowPreserved, foregroundPreserved, withinBudget, controllerCompleted };
  const unknown = Object.values(checks).some((value) => value === null || value === undefined);
  const failed = Object.values(checks).some((value) => value === false);
  return { outcome: failed ? "failed" : unknown ? "unknown" : "passed", strictCompletion: failed ? false : unknown ? null : true,
    checks, scope: "A missing app/controller measurement cannot become a successful task from file bytes alone." };
}
