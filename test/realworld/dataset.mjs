import { createHash, randomUUID } from "node:crypto";

export const datasetVersion = "textedit-dispatch-v1";
export const targetCount = 6;
export const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const start = "--- SUMMARY START ---\n";
const end = "--- SUMMARY END ---\n";
const money = (cents) => `NGN ${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, "0")}`;
const validUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function uuidFor(value) {
  const h = sha256(value);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
function random(seed) {
  let index = 0;
  return (limit) => Number.parseInt(sha256(`${seed}:${index++}`).slice(0, 8), 16) % limit;
}
export function summarizeFacts(facts) {
  const units = facts.items.reduce((n, item) => n + item.quantity, 0);
  const packed = facts.items.reduce((n, item) => n + item.packed, 0);
  const subtotalCents = facts.items.reduce((n, item) => n + item.quantity * item.unitPriceCents, 0);
  return { units, packed, subtotalCents, status: facts.holdReason ? "ON HOLD" : packed === units ? "READY" : "PACKING" };
}
export function renderSummary(facts) {
  const s = summarizeFacts(facts);
  return `Order: ${facts.order}\nLine items: 3\nUnits ordered: ${s.units}\nUnits packed: ${s.packed}\nSubtotal: ${money(s.subtotalCents)}\nDispatch status: ${s.status}\n`;
}
export function replaceSummary(text, summary) {
  const begin = text.indexOf(start), finish = text.indexOf(end);
  if (begin < 0 || finish < begin || text.indexOf(start, begin + 1) !== -1 || text.indexOf(end, finish + 1) !== -1) {
    throw new Error("Document must contain exactly one ordered summary block");
  }
  return text.slice(0, begin + start.length) + summary + text.slice(finish);
}

export function generateDataset({ seed, runId = randomUUID() }) {
  if (typeof seed !== "string" || !seed.length || seed.length > 128 || /[\r\n\x00]/.test(seed) || !validUUID.test(runId)) {
    throw new Error("Dataset requires a bounded seed and UUID runId");
  }
  const next = random(`${datasetVersion}:${seed}`);
  const files = [];
  for (let index = 0; index < targetCount; index++) {
    const id = uuidFor(`${runId}:${index}`);
    const facts = { order: `DN-${String(next(900000) + 100000)}`, holdReason: index % 3 === 2 ? ["address verification", "recipient confirmation"][next(2)] : null,
      items: Array.from({ length: 3 }, (_, item) => ({ sku: `KIT-${index + 1}-${item + 1}-${next(900) + 100}`, quantity: next(8) + 2, unitPriceCents: next(950000) + 10000 })) };
    for (const item of facts.items) item.packed = item.quantity;
    if (index % 3 === 1) facts.items[next(3)].packed -= 1;
    if (index % 3 === 2) facts.items[next(3)].packed = 0;
    const tag = sha256(`${seed}:canary:${index}`).slice(0, 20);
    const text = `DISPATCH NOTE ${index + 1}\nArchive token: keep-${tag}\nOriginal note: Preserve this signed dispatch record - café.\n\nSOURCE FACTS (preserve every line)\nOrder: ${facts.order}\nHold reason: ${facts.holdReason ?? "none"}\n${facts.items.map((item) => `Item: ${item.sku} | quantity: ${item.quantity} | unit price: ${money(item.unitPriceCents)} | packed: ${item.packed}`).join("\n")}\n\n${start}Summary pending.\n${end}\nProtected footer: archive-${tag.split("").reverse().join("")}\n`;
    const expectedText = replaceSummary(text, renderSummary(facts));
    files.push({ role: "target", documentId: `note-${index + 1}`, fileName: `dispatch-${String(index + 1).padStart(2, "0")}-${id}.txt`, initialText: text, expectedText,
      initialSha256: sha256(text), expectedSha256: sha256(expectedText), facts });
  }
  const decoyName = files[0].fileName.replace(/\.txt$/, "-reference.txt");
  const decoyText = files[0].initialText.replace("DISPATCH NOTE 1", "REFERENCE COPY - DO NOT EDIT");
  files.push({ role: "decoy", documentId: "protected-reference", fileName: decoyName, initialText: decoyText, expectedText: decoyText,
    initialSha256: sha256(decoyText), expectedSha256: sha256(decoyText) });
  const publicManifest = {
    schemaVersion: 1, datasetVersion, runId,
    app: { name: "TextEdit", bundleId: "com.apple.TextEdit" },
    task: "Update the summary block in each of the six listed dispatch notes from its source facts. Preserve every byte outside the block, including the block marker lines. Save by closing each target through its observed close button. Leave the reference document open and unchanged.",
    targets: files.filter((f) => f.role === "target").map(({ documentId, fileName }) => ({ documentId, fileName })),
    protectedDocuments: [{ documentId: "protected-reference", fileName: decoyName }],
    summaryRules: {
      markers: { start: start.trimEnd(), end: end.trimEnd() },
      lines: ["Order: <source order>", "Line items: 3", "Units ordered: <sum of quantities>", "Units packed: <sum of packed quantities>", "Subtotal: NGN <sum of quantity times unit price, exactly two decimals, no grouping separators>", "Dispatch status: <ON HOLD, READY, or PACKING>"],
      status: "ON HOLD when hold reason is not none; otherwise READY when all ordered units are packed; otherwise PACKING.",
      encoding: "UTF-8 without BOM, LF line endings, final newline preserved"
    }
  };
  const privateManifest = { schemaVersion: 1, datasetVersion, runId, seed, expectedTargetCount: targetCount, expectedDecoyCount: 1, files };
  return { publicManifest, privateManifest };
}
