# Disposable macOS fixture

The fixture is a standalone AppKit app for testing the computer-use layer. It owns two windows, four editable text fields, and one press button per window. Its stdin/stdout control channel reports native model and control state independently of Accessibility readback. It never synthesizes global input, activates another app, or requests privacy permissions.

## Build and launch

```sh
sh test/fixtures/macos/build.sh
test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture
```

Launch the executable directly as a child process with piped stdin/stdout. Do not use `open`, which does not provide the control channel. The build requires the macOS SDK and Swift compiler; it adds no package dependency. Generated app files stay in the fixture's ignored `.build` directory, outside the production native source glob.

The app uses the accessory activation policy and orders its own windows behind existing windows without making them key. Window animations are disabled and the requested outer frame is applied explicitly, so initial frame transitions are not part of a scenario. Readiness includes the initial and current foreground PIDs and the fixture's `activationCount`, so the runner can detect observed focus interference. These samples cannot exclude every transient or external foreground change. The fixture does not restore the foreground by activating an external app.

## JSONL protocol

After both windows exist, stdout emits one readiness line:

```json
{"event":"ready","status":"ok","state":{"pid":123,"runNonce":"...","revision":0,"resetGeneration":1,"activationCount":0,"startedForegroundPID":456,"foregroundPID":456,"windows":[...]}}
```

`ready` means native windows, controls, and model state have been constructed. It
does not prove CG registration or external AX publication is complete. A live
runner must separately gate target registration and successful read-only AX
inspection within a bounded setup budget, recording attempts and setup latency.
This is a setup distinction, not a production action retry or fixed startup sleep.

Send one request per line. Responses echo `id` and include `status: "ok"` or `status: "error"`, the current `state`, and an `error` string on failure. The app exits on `quit` or stdin EOF. Stdout contains only JSONL; AppKit diagnostics may appear on stderr.

| Command | Fields | Effect |
| --- | --- | --- |
| `state` | None | Return state without modifying it. |
| `reset` | None | Recreate both windows with deterministic original values and normal write modes; increment `resetGeneration`. |
| `configure` | `window`, `control`, optional `mode`, `delayMs`, `enabled`, `value`, `selection`, `pauseAfterApplyMs` | Configure one field's behavior or initial state. `window` defaults to `primary`; `control` is `first` or `second`. Selection uses UTF-16 `location`/`length`. |
| `configure` | `window`, optional `title`, `frame` | Change a window title/outer frame, including making both windows share a title and frame. `frame` requires `x`, `y`, `width`, `height` in AppKit screen points, with a bottom-left origin. |
| `configure` | Optional `window`, `pressEffect` | Set the button effect to `counter` (default), `disableSecond`, or `removeSecond`. |
| `reorder` | Optional `window` | Move existing arranged rows in place, reversing order while retaining field/view objects and generations. Rows are not detached and reinserted. |
| `recreate` | Optional `window`, `control` | Replace a field with a new object having the same AX identifier, label, value, and mode; increment its generation. Defaults: `primary`, `first`. |
| `close_reopen` | Optional `window` | Close and replace a window and its controls; retain title, frame, order, values, and modes; increment window/control generations. |
| `hide_window` | Optional `window` | Order only the fixture's own window out without closing or replacing it. This is a native test control for hidden-versus-absent checks. |
| `quit` | None | Reply with final state, then terminate. |

Examples:

```json
{"id":1,"command":"configure","window":"primary","control":"first","mode":"ignored"}
{"id":2,"command":"configure","window":"primary","control":"second","mode":"delayed","delayMs":250}
{"id":"selection","command":"configure","control":"first","value":"A🙂éZ","selection":{"location":1,"length":2},"enabled":true}
{"id":"effect","command":"configure","pressEffect":"removeSecond"}
{"id":3,"command":"reorder","window":"primary"}
{"id":4,"command":"recreate","window":"primary","control":"first"}
{"id":5,"command":"close_reopen","window":"secondary"}
{"id":6,"command":"state"}
{"id":7,"command":"reset"}
{"id":8,"command":"quit"}
```

## Targets and independent state

`state.windows` is an array ordered `primary`, `secondary`. Each entry contains `key`, `windowId` (the AppKit window number), `title`, `generation`, `visible`, `keyWindow`, `frame`, `order`, `pressCount`, `pressEffect`, and `controls`. Default titles are `CUA Fixture — Primary` and `CUA Fixture — Secondary`.

Each window has fields `first` and `second`. Their AX identifiers are `primary.first`, `primary.second`, `secondary.first`, and `secondary.second`. All four fields expose the same actual AX title and label, `Value`, as well as repeated visual labels. This permits both precise identifier selection and deliberately ambiguous role/title queries.

Each control state contains:

- `identifier`, `label`, `key`, and `generation`;
- `modelValue`, the fixture's source-of-truth model, and `controlValue`, the live `NSTextField.stringValue`, read directly rather than through AX;
- `enabled`, `attached`, and `selection` (`location`/`length` in UTF-16 units), read directly from the fixture's control/view state;
- `mode`, `delayMs`, `attempts`, `appliedWrites`, `lastRequestedValue`, and `pendingWrites` (write IDs and requested values).

Default values are `<window>-<control>-original`, such as `primary-first-original`. The `NSTextField` subclass intercepts Accessibility value writes:

- `normal`: update the model and native control immediately;
- `ignored`: record the attempt without changing the model/control;
- `delayed`: record and schedule the change after `delayMs` (default 250, allowed range 0–10000).

The field also implements `AXSelectedText` and `AXSelectedTextRange`. Selected-text
replacement uses the current UTF-16 selection and sends the resulting value
through the same normal/ignored/delayed oracle path. A successfully applied
immediate replacement collapses the selection after the inserted text.

`configure.value` sets model/control state directly for setup, cancels pending
writes for that field, and resets selection to zero. A supplied selection is then
validated against the resulting value's UTF-16 length. `configure.enabled` changes
the actual control's enabled state. These are test-only setup commands, not AX
delivery evidence.

Changing a mode does not cancel writes already scheduled. Reset, control recreation, and window replacement invalidate earlier delayed callbacks; they cannot write into replacement generations. In-place reordering preserves pending writes and view membership for the same objects. Removing a row from its superview and reattaching it can invalidate external AX proxy identity even if the `NSTextField` instance is retained, so that is not the reorder scenario. The controller serializes commands and delayed writes on the AppKit main thread.

Each button exposes `primary.press` or `secondary.press` as its AX identifier. Its
native target/action increments that window's `pressCount`; requesting `state`
reads the counter directly. This independently establishes a fixture button
effect even when an AX receipt has delivery but no declared postcondition proof.
`pressEffect: "counter"` performs only that increment. `disableSecond` also disables
the second field; `removeSecond` cancels its pending writes and detaches its row
from the view tree. The detached object remains in the independent oracle with
`attached: false`, its original identifier/generation, and write counters. This
lets the runner detect an attempted write to a control that is no longer in the
live AX tree. Reset restores new normal fields and the default counter effect.

`hide_window` changes native visibility without changing the window number or
generation. A hidden window still present in the complete CG list must not satisfy
`windowAbsent`. `close_reopen` instead removes the old key and creates a replacement;
absence of the old exact key can be confirmed without inventing an observation of
the closed window.

`runNonce` identifies one fixture process. `resetGeneration` identifies resets within that process. `revision` advances on fixture mutation commands and AX write attempts/applications; it is an attribution marker, not an atomic AX snapshot version. Generation counters describe fixture object replacement and are not exposed to the production computer-use API.

## Verification boundary

A runner should launch the fixture, obtain native targets from readiness, complete the external readiness gates, exercise the computer-use API, then request `state` to check every field and press counter in both windows. Count an unchanged already-correct field separately from a newly applied write. For delayed writes, use the action's verification deadline and subsequently inspect independent fixture state; elapsed time alone is not completion evidence.

Run the installed Rust/Swift semantic campaign with Accessibility access already
granted to the test host:

```sh
npm run build:runtime
sh test/fixtures/macos/build.sh
node test/runtime/semantic-live.mjs --repetitions 3
node test/runtime/composition-live.mjs --repetitions 3
```

The runner creates a fresh fixture per trial and records setup attempts, receipts,
independent before/after state, and cleanup under `.artifacts/semantic-live`.
`--output PATH` selects another output directory. Cases cover privacy, exact and
ignored/delayed writes, already-satisfied state, in-place reorder versus
replacement, ambiguous windows, stale sessions/targets, selected-text typing,
press, waits, and cooperative helper locking. An expected refusal or an honestly
reported ignored write can pass conformance without completing a mutation. These
results do not establish arbitrary-app or autonomous task success.

The separate 12-scenario composition runner writes to `.artifacts/composition-live`
and tests bounded mixed steps, immutable progress, stop/deadline behavior, typed
presence/absence/enabled waits, hidden/closed windows, private projection feedback,
and causally gated helper loss. The matched scripted/model comparison is described
in [evaluation.md](evaluation.md); it has its own budgets, lanes, and evidence.
Neither runner should run concurrently with another native UI campaign. The legacy
`baseline:*` commands remain a separate comparison path.

## PER-14 scripted readiness

The workflow mode runs independently of the small fixture. Invoice entry presents
a source window and a 27-field form with a protected Notes field in each window.
A valid submission records the invoice, closes the form and opens confirmation.
Settings has three pages and 15 fields and checkboxes. Eight start incorrect and
seven start correct. Only the active page exposes settings controls to AX.

The friction variant uses the same task data. Its fault triggers follow field
actions, so all lanes encounter the same edits. The fixture delays one write,
recreates a row or field, clears one value and displays a validation message, and
canonicalizes one decimal field. The scripted driver deliberately sends `12.5`
to check readback of `12.50`. It records the mismatch receipt and reconciles by
reading the state. A canonical submission can satisfy the oracle directly.

```sh
npm run build
npm run build:runtime
sh test/fixtures/macos/build.sh
node --test test/workflow/task.test.mjs
node test/workflow/scripted.mjs --output .artifacts/workflow-readiness
```

The runner assigns 12 trials across both tasks, clean and friction, and the three
lanes. Use `--task invoice|settings`, `--variant clean|friction`, or
`--lane legacy|single|composed` to select a subset. Each trial starts a new fixture
and MCP connection, checks public AX readiness and grades the fixture's private
state and event journal. It retains pending and failed assignments, tool results,
and foreground monitoring through cleanup in an owner-readable `report.json`.
Run serially on an unlocked Mac with Accessibility access already available.

The driver uses expected values to exercise a reference action sequence. Its
results measure scripted readiness. See the [PER-14 delivery guide](per-14-delivery.md)
for the session harness, user-active checks, and paid pilot controls.

The controlled `pauseAfterApplyMs` fault (0–2000 ms, default zero) emits a
`write_applied` event with independent native state after changing the value, then
holds the fixture AX setter before returning. The native crash suite uses that
event to kill the real Swift child after effect and before its response. The pause
is a fixture fault, not a sleep used to infer a crash phase. Relay request markers
are nonce-bound to the current child, request, epoch and observation.
