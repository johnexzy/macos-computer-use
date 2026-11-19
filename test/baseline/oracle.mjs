export function controlValues(state) {
  return state.windows.flatMap((window) => window.controls.map((control) => [
    window.key, control.key, control.modelValue, control.controlValue,
  ])).sort((a, b) => `${a[0]}.${a[1]}`.localeCompare(`${b[0]}.${b[1]}`));
}

export function assessRefusal(result, before, after, expectedCodes) {
  const body = JSON.parse(result.content.find((part) => part.type === "text").text);
  const unchanged = JSON.stringify(controlValues(before)) === JSON.stringify(controlValues(after));
  const intendedError = result.isError === true && expectedCodes.includes(body.code);
  return { passed: intendedError && unchanged, code: body.code ?? null,
    unexpectedError: result.isError === true && !intendedError, unchanged };
}

export function fixtureWrites(state) {
  return state.windows.flatMap((window) => window.controls).reduce((sum, control) => ({
    attempts: sum.attempts + control.attempts,
    applied: sum.applied + control.appliedWrites,
  }), { attempts: 0, applied: 0 });
}
