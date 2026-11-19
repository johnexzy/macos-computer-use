import assert from "node:assert/strict";
import test from "node:test";
import { assessRefusal, controlValues, fixtureWrites } from "./oracle.mjs";

const state = (value = "original") => ({ windows: [{ key: "primary", controls: [
  { key: "second", modelValue: "sibling", controlValue: "sibling", attempts: 0, appliedWrites: 0 },
  { key: "first", modelValue: value, controlValue: value, attempts: 1, appliedWrites: 0 },
] }] });
const failure = (code) => ({ isError: true, content: [{ type: "text", text: JSON.stringify({ code }) }] });

test("an unrelated infrastructure error is not a correct target refusal", () => {
  const result = assessRefusal(failure("NATIVE_EXEC_FAILED"), state(), state(), ["TARGET_NOT_FOUND"]);
  assert.equal(result.passed, false);
  assert.equal(result.unexpectedError, true);
  assert.equal(assessRefusal(failure("TARGET_NOT_FOUND"), state(), state(), ["TARGET_NOT_FOUND"]).passed, true);
});

test("a target refusal after an unintended write still fails", () => {
  assert.equal(assessRefusal(failure("TARGET_NOT_FOUND"), state(), state("changed"), ["TARGET_NOT_FOUND"]).passed, false);
});

test("row order does not change independent values or field-write counts", () => {
  const before = state();
  const after = structuredClone(before);
  after.windows[0].controls.reverse();
  assert.deepEqual(controlValues(before), controlValues(after));
  assert.deepEqual(fixtureWrites(after), { attempts: 1, applied: 0 });
});
