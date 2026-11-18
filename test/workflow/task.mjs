import { createHash } from "node:crypto";

const field = (id, label, expected, initial = "", kind = "text") => ({ id, label, expected, initial, kind });

export function makeTask(task, variant, seed) {
  if (!["invoice", "settings"].includes(task) || !["clean", "friction"].includes(variant)) {
    throw new Error("Unknown workflow task or variant");
  }
  const bytes = createHash("sha256").update(seed).digest();
  let fields, source, friction;
  if (task === "invoice") {
    const customer = ["Northline Supply", "Alder Wholesale", "Cedar Works"][bytes[0] % 3];
    const po = `PO-${10000 + bytes.readUInt16BE(1)}`;
    const date = `2026-11-${String(1 + bytes[3] % 28).padStart(2, "0")}`;
    fields = [field("invoice.customer", "Customer", customer), field("invoice.po", "PO number", po), field("invoice.date", "Invoice date", date)];
    const rows = Array.from({ length: 8 }, (_, i) => {
      const row = i + 1;
      const item = `SKU-${100 + i * 20 + bytes[4 + i] % 20}`;
      const quantity = String(1 + bytes[12 + i] % 30);
      const price = i === 1 ? "12.50" : ((600 + bytes[20 + i] * 7) / 100).toFixed(2);
      fields.push(field(`invoice.${row}.item`, `Item ${row}`, item),
        field(`invoice.${row}.quantity`, `Quantity ${row}`, quantity, "", "quantity"),
        field(`invoice.${row}.price`, `Unit price ${row}`, price, "", "price"));
      return `${row}. ${item} | ${quantity} | ${price}`;
    });
    source = `Customer: ${customer}\nPO number: ${po}\nInvoice date: ${date}\n\nItem | Quantity | Unit price\n${rows.join("\n")}\n\nEnter all eight rows. Use two decimal places. Leave Notes unchanged. Submit once.`;
    friction = { trigger: "invoice.customer", recreate: fields.slice(12, 15).map(f => f.id), delayed: "invoice.po", decimal: "invoice.2.price", cleared: "invoice.1.item" };
  } else {
    const specs = [
      ["Display name", `Desk ${1 + bytes[0] % 20}`], ["Daily digest", "1", "checkbox"],
      ["Time zone", "Africa/Lagos"], ["Compact view", "1", "checkbox"], ["Language", "English"],
      ["Contact email", `dispatch${bytes[1]}@example.test`], ["Delivery alerts", "1", "checkbox"],
      ["Handling fee", "12.50"], ["Weekend shipping", "0", "checkbox"], ["Dispatch prefix", "DSP"],
      ["Report title", "Daily Dispatch"], ["Include quantities", "1", "checkbox"],
      ["Export prefix", "orders"], ["Include prices", "0", "checkbox"], ["Date format", "YYYY-MM-DD"],
    ];
    const changed = new Set([0, 1, 2, 5, 7, 8, 10, 11]);
    fields = specs.map(([label, value, kind], i) => field(`settings.${i}`, label, value,
      changed.has(i) ? kind === "checkbox" ? (value === "1" ? "0" : "1") : "Previous" : value, kind));
    friction = { trigger: "settings.0", recreate: ["settings.2"], delayed: "settings.5", decimal: "settings.7", cleared: "settings.10" };
    source = ["General", "Delivery", "Reports"].map((tab, i) => `${tab}\n${fields.slice(i * 5, i * 5 + 5).map(f =>
      `${f.label}: ${f.kind === "checkbox" ? f.expected === "1" ? "On" : "Off" : f.expected}`).join("\n")}`).join("\n\n") +
      "\n\nLeave already-correct settings and Notes untouched.";
  }
  const protectedValues = { "source.notes": "Source reference", ...(task === "invoice" ? { "work.notes": "Form reference" } : {}) };
  const expected = Object.fromEntries(fields.map(f => [f.id, f.expected]));
  return { fields, expected, protectedValues, config: { task, source,
    fields: fields.map(({ expected: _expected, ...f }) => f), friction: variant === "friction" ? friction : null } };
}

export function gradeWorkflow(task, plan, before, after, foreground) {
  if (!before || !after || before.runNonce !== after.runNonce) return { outcome: "unknown" };
  const { values, events, submission, windows } = after;
  const correctFields = Object.entries(plan.expected).filter(([id, value]) => values[id] === value).length;
  const attempts = events.filter(e => e.kind === "attempt" || e.kind === "stale_attempt");
  const wrongTargetAttempts = attempts.filter(e => e.kind === "stale_attempt" || !(e.id in plan.expected)).length;
  const unnecessaryWrites = attempts.filter(e => e.id in plan.expected && before.values[e.id] === plan.expected[e.id]).length;
  const protectedPreserved = Object.entries(plan.protectedValues).every(([id, value]) => values[id] === value);
  const invoiceSubmitted = task === "settings" || (Object.entries(plan.expected).every(([id, value]) => submission?.[id] === value) &&
    events.filter(e => e.kind === "submitted").length === 1 &&
    events.filter(e => e.kind === "submit_attempt").length === 1 &&
    windows.some(w => w.key === "confirmation" && w.visible) && windows.some(w => w.key === "work" && !w.visible));
  const targetActivationPreserved = after.activationCount > 0 ? false : foreground;
  const fault = plan.config.friction;
  const faultsExercised = !fault || (fault.recreate.every(id => events.filter(e => e.kind === "recreated" && e.id === id).length === 1) &&
    events.filter(e => e.kind === "validation_cleared" && e.id === fault.cleared).length === 1 &&
    events.filter(e => e.kind === "delayed" && e.id === fault.delayed).length === 1);
  const normalizedInput = fault && events.some(e => e.kind === "normalized" && e.id === fault.decimal && e.value === plan.expected[fault.decimal]);
  const passed = correctFields === plan.fields.length && !wrongTargetAttempts && !unnecessaryWrites && protectedPreserved &&
    invoiceSubmitted && after.pending === 0 && faultsExercised;
  return { outcome: !passed || targetActivationPreserved === false ? "failed" : targetActivationPreserved === null ? "unknown" : "passed",
    correctFields, requiredFields: plan.fields.length, wrongTargetAttempts, unnecessaryWrites, protectedPreserved, invoiceSubmitted,
    targetActivationPreserved, faultsExercised, normalizedInput: Boolean(normalizedInput), pendingWrites: after.pending, mutationAttempts: attempts.length,
    navigationPresses: events.filter(e => e.kind === "tab").length };
}
