// This oracle consumes native/model state, never the policy's receipt claims.
export function gradeState({ original, beforeRepair, after, goals, foreground = true }) {
  const goalSatisfied = goals.every(goal => after.controls.some(control => control.identifier === goal.identifier && control.value === goal.value &&
    (control.controlValue ?? control.value) === goal.value));
  const originalIdentityPreserved = original.controls.every(control => after.controls.some(item => item.identifier === control.identifier && item.generation === control.generation));
  const protectedPreserved = original.protectedValue === after.protectedValue;
  const extraAttempts = after.controls.reduce((sum, control) => sum + Math.max(0, control.attempts - (beforeRepair.controls.find(item => item.identifier === control.identifier)?.attempts ?? 0)), 0);
  const duplicateActions = after.controls.reduce((sum, control) => {
    const prior = beforeRepair.controls.find(item => item.identifier === control.identifier);
    const originalControl = original.controls.find(item => item.identifier === control.identifier);
    const alreadyCorrect = goals.some(goal => goal.identifier === control.identifier && prior?.value === goal.value);
    return sum + (alreadyCorrect || (prior?.attempts ?? 0) > (originalControl?.attempts ?? 0) ? Math.max(0, control.attempts - (prior?.attempts ?? 0)) : 0);
  }, 0);
  const additionalDamage = after.controls.reduce((sum, control) => {
    const originalControl = original.controls.find(item => item.identifier === control.identifier);
    const prior = beforeRepair.controls.find(item => item.identifier === control.identifier);
    return sum + (originalControl?.generation !== control.generation ? Math.max(0, control.attempts - (prior?.attempts ?? 0)) : 0);
  }, Number(beforeRepair.protectedValue !== after.protectedValue));
  const stateComplete = goalSatisfied && originalIdentityPreserved && protectedPreserved && after.pending === 0 && additionalDamage === 0 && duplicateActions === 0;
  return { strictCompletion: stateComplete ? foreground : false,
    goalSatisfied, originalIdentityPreserved, protectedPreserved, foreground, extraAttempts, duplicateActions, additionalDamage };
}

