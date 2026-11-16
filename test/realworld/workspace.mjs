import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { generateDataset, datasetVersion } from "./dataset.mjs";

const exec = promisify(execFile);
const ownerName = ".realworld-owner.json";
const publicName = "manifest.public.json", privateName = "manifest.private.json";
const filePattern = /^dispatch-\d{2}-[0-9a-f-]{36}(?:-reference)?\.txt$/;
const appPath = "/System/Applications/TextEdit.app";
const uid = () => process.getuid();
const writeJSON = (file, value, flag = "wx") => fs.writeFile(file, JSON.stringify(value, null, 2) + "\n", { mode: 0o600, flag });

async function ownedDirectory(directory) {
  const info = await fs.lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== uid() || (info.mode & 0o077)) throw new Error("Workspace must be a private owned directory");
}
async function ownedFile(file, optional = false) {
  let info;
  try { info = await fs.lstat(file); } catch (error) { if (optional && error.code === "ENOENT") return false; throw error; }
  if (!info.isFile() || info.isSymbolicLink() || info.uid !== uid() || info.nlink !== 1) throw new Error("Workspace file must be an owned regular file without links");
  return true;
}
export async function createWorkspace({ parentDirectory, seed, runId = randomUUID() }) {
  const dataset = generateDataset({ seed, runId });
  await fs.mkdir(parentDirectory, { recursive: true, mode: 0o700 });
  const directory = path.resolve(parentDirectory, `textedit-${runId}`);
  await fs.mkdir(directory, { mode: 0o700 });
  const documentsDirectory = path.join(directory, "documents");
  await fs.mkdir(documentsDirectory, { mode: 0o700 });
  // Write the ownership record first so an interrupted setup remains discoverable and scoped.
  await writeJSON(path.join(directory, ownerName), { schemaVersion: 1, datasetVersion, runId, ownerUid: uid(), fileNames: dataset.privateManifest.files.map((f) => f.fileName) });
  await writeJSON(path.join(directory, publicName), dataset.publicManifest);
  await writeJSON(path.join(directory, privateName), dataset.privateManifest);
  for (const file of dataset.privateManifest.files) await fs.writeFile(path.join(documentsDirectory, file.fileName), file.initialText, { mode: 0o600, flag: "wx" });
  return { directory, documentsDirectory, ...dataset };
}
async function readOwnership(directory) {
  directory = path.resolve(directory);
  await ownedDirectory(directory);
  await ownedFile(path.join(directory, ownerName));
  const owner = JSON.parse(await fs.readFile(path.join(directory, ownerName), "utf8"));
  if (owner.schemaVersion !== 1 || owner.datasetVersion !== datasetVersion || owner.ownerUid !== uid() || path.basename(directory) !== `textedit-${owner.runId}` || !Array.isArray(owner.fileNames) || owner.fileNames.length !== 7 || new Set(owner.fileNames).size !== 7 || owner.fileNames.some((name) => !filePattern.test(name))) {
    throw new Error("Workspace ownership record does not match this dataset");
  }
  return { directory, owner, documentsDirectory: path.join(directory, "documents") };
}
export async function loadWorkspace(directory) {
  const { directory: resolved, owner, documentsDirectory } = await readOwnership(directory);
  directory = resolved;
  await ownedDirectory(documentsDirectory);
  await ownedFile(path.join(directory, publicName)); await ownedFile(path.join(directory, privateName));
  const publicManifest = JSON.parse(await fs.readFile(path.join(directory, publicName), "utf8"));
  const privateManifest = JSON.parse(await fs.readFile(path.join(directory, privateName), "utf8"));
  if (publicManifest.runId !== owner.runId || privateManifest.runId !== owner.runId || privateManifest.datasetVersion !== datasetVersion || privateManifest.files.length !== 7 || privateManifest.files.some((f) => !owner.fileNames.includes(f.fileName)) || new Set(privateManifest.files.map((f) => f.fileName)).size !== 7) throw new Error("Workspace manifests do not match ownership");
  return { directory, documentsDirectory, publicManifest, privateManifest };
}
export async function resetWorkspace(directory, { documentsClosed = false } = {}) {
  if (!documentsClosed) throw new Error("Close all owned TextEdit documents before reset");
  const workspace = await loadWorkspace(directory);
  const known = new Set(workspace.privateManifest.files.map((f) => f.fileName));
  const extras = (await fs.readdir(workspace.documentsDirectory)).filter((name) => !known.has(name));
  if (extras.length) throw new Error("Unrecognized files prevent a scoped reset");
  for (const f of workspace.privateManifest.files) {
    const file = path.join(workspace.documentsDirectory, f.fileName);
    await ownedFile(file, true);
    await fs.writeFile(file, f.initialText, { mode: 0o600 });
  }
  return workspace;
}
export async function cleanupWorkspace(directory, { documentsClosed = false } = {}) {
  if (!documentsClosed) return { complete: false, reason: "documents_not_confirmed_closed", removed: [] };
  try { await fs.lstat(directory); } catch (error) { if (error.code === "ENOENT") return { complete: true, removed: [] }; throw error; }
  const workspace = await readOwnership(directory), removed = [];
  let documentsExist = true;
  try { await ownedDirectory(workspace.documentsDirectory); }
  catch (error) { if (error.code === "ENOENT") documentsExist = false; else throw error; }
  if (documentsExist) for (const name of workspace.owner.fileNames) {
    const file = path.join(workspace.documentsDirectory, name);
    if (await ownedFile(file, true)) { await fs.unlink(file); removed.push(name); }
  }
  const remaining = documentsExist ? await fs.readdir(workspace.documentsDirectory) : [];
  const extraRoot = (await fs.readdir(workspace.directory)).filter((name) => ![ownerName, publicName, privateName, "documents"].includes(name));
  if (remaining.length || extraRoot.length) return { complete: false, reason: "unrecognized_files_retained", removed, remaining: [...remaining.map((x) => `documents/${x}`), ...extraRoot] };
  if (documentsExist) await fs.rmdir(workspace.documentsDirectory);
  for (const name of [publicName, privateName, ownerName]) {
    const file = path.join(workspace.directory, name);
    if (await ownedFile(file, true)) await fs.unlink(file);
  }
  await fs.rmdir(workspace.directory);
  return { complete: true, removed };
}
export async function textEditAvailability() {
  if (process.platform !== "darwin") return { available: false, reason: "macos_required" };
  try {
    const { stdout } = await exec("/usr/bin/plutil", ["-convert", "json", "-o", "-", path.join(appPath, "Contents/Info.plist")]);
    const info = JSON.parse(stdout);
    return { available: info.CFBundleIdentifier === "com.apple.TextEdit", appPath, bundleId: info.CFBundleIdentifier, version: info.CFBundleShortVersionString,
      liveCapabilitiesProven: false, note: "Read-only bundle metadata only; AX editing and close/save behavior require a separate serialized probe." };
  } catch { return { available: false, reason: "textedit_metadata_unavailable" }; }
}
export function textEditOpenArguments(workspace) {
  return ["-g", "-n", "-a", appPath, ...workspace.privateManifest.files.map((f) => path.join(workspace.documentsDirectory, f.fileName))];
}
export async function openTextEditSetup(directory) {
  const workspace = await loadWorkspace(directory);
  const availability = await textEditAvailability();
  if (!availability.available) throw new Error("TextEdit is unavailable");
  for (const file of workspace.privateManifest.files) await ownedFile(path.join(workspace.documentsDirectory, file.fileName));
  await exec("/usr/bin/open", textEditOpenArguments(workspace));
  return { setupCommand: "open -g -n -a TextEdit <seven owned files>", launched: true, capabilitiesProven: false,
    note: "The controller must independently bind the owned documents and exact PID/window identities. This setup command is not a model actuator." };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { seed: { type: "string", default: "dispatch-1" }, parent: { type: "string", default: ".artifacts/realworld" }, directory: { type: "string" }, open: { type: "boolean", default: false }, "documents-closed": { type: "boolean", default: false } } });
  let result;
  if (positionals[0] === "preflight") result = await textEditAvailability();
  else if (positionals[0] === "prepare") {
    const workspace = await createWorkspace({ parentDirectory: values.parent, seed: values.seed });
    result = { directory: workspace.directory, publicManifest: workspace.publicManifest, liveCapabilitiesProven: false };
    if (values.open) result.setup = await openTextEditSetup(workspace.directory);
  } else if (positionals[0] === "reset" && values.directory) { await resetWorkspace(values.directory, { documentsClosed: values["documents-closed"] }); result = { reset: true }; }
  else if (positionals[0] === "cleanup" && values.directory) result = await cleanupWorkspace(values.directory, { documentsClosed: values["documents-closed"] });
  else throw new Error("Use preflight, prepare [--open], reset --directory, or cleanup --directory");
  console.log(JSON.stringify(result, null, 2));
}
