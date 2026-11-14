# Disposable macOS fixture

The PER-1 fixture is a standalone AppKit app for testing the computer-use layer. It owns two windows and four editable text fields. Its stdin/stdout control channel reports native model and control state independently of Accessibility readback. It never synthesizes global input, activates another app, or requests privacy permissions.

## Build and launch

```sh
sh test/fixtures/macos/build.sh
test/fixtures/macos/.build/CUAFixture.app/Contents/MacOS/CUAFixture
```

Launch the executable directly as a child process with piped stdin/stdout. Do not use `open`, which does not provide the control channel. The build requires the macOS SDK and Swift compiler; it adds no package dependency. Generated app files stay in the fixture's ignored `.build` directory, outside the production native source glob.

The app uses the accessory activation policy and orders its own windows behind existing windows without making them key. Readiness includes the initial and current foreground PIDs and the fixture's `activationCount`, so the runner can detect focus interference. The fixture does not restore the foreground by activating an external app.

## JSONL protocol

After both windows exist, stdout emits one readiness line:

```json
{"event":"ready","status":"ok","state":{"pid":123,"runNonce":"...","revision":0,"resetGeneration":1,"activationCount":0,"startedForegroundPID":456,"foregroundPID":456,"windows":[...]}}
```

Send one request per line. Responses echo `id` and include `status: "ok"` or `status: "error"`, the current `state`, and an `error` string on failure. The app exits on `quit` or stdin EOF. Stdout contains only JSONL; AppKit diagnostics may appear on stderr.

| Command | Fields | Effect |
| --- | --- | --- |
| `state` | None | Return state without modifying it. |
| `reset` | None | Recreate both windows with deterministic original values and normal write modes; increment `resetGeneration`. |
| `configure` | `window`, `control`, optional `mode`, `delayMs` | Change one field's AX write behavior. `window` defaults to `primary`; `control` is `first` or `second`. |
| `configure` | `window`, optional `title`, `frame` | Change a window title/outer frame, including making both windows share a title and frame. `frame` requires `x`, `y`, `width`, `height` in AppKit screen points, with a bottom-left origin. |
| `reorder` | Optional `window` | Reverse row order while retaining the same field objects and control generations. |
| `recreate` | Optional `window`, `control` | Replace a field with a new object having the same AX identifier, label, value, and mode; increment its generation. Defaults: `primary`, `first`. |
| `close_reopen` | Optional `window` | Close and replace a window and its controls; retain title, frame, order, values, and modes; increment window/control generations. |
| `quit` | None | Reply with final state, then terminate. |

Examples:

```json
{"id":1,"command":"configure","window":"primary","control":"first","mode":"ignored"}
{"id":2,"command":"configure","window":"primary","control":"second","mode":"delayed","delayMs":250}
{"id":3,"command":"reorder","window":"primary"}
{"id":4,"command":"recreate","window":"primary","control":"first"}
{"id":5,"command":"close_reopen","window":"secondary"}
{"id":6,"command":"state"}
{"id":7,"command":"reset"}
{"id":8,"command":"quit"}
```

## Targets and independent state

`state.windows` is an array ordered `primary`, `secondary`. Each entry contains `key`, `windowId` (the AppKit window number), `title`, `generation`, `visible`, `keyWindow`, `frame`, `order`, and `controls`. Default titles are `CUA Fixture — Primary` and `CUA Fixture — Secondary`.

Each window has fields `first` and `second`. Their AX identifiers are `primary.first`, `primary.second`, `secondary.first`, and `secondary.second`. All four fields expose the same actual AX title and label, `Value`, as well as repeated visual labels. This permits both precise identifier selection and deliberately ambiguous role/title queries.

Each control state contains:

- `identifier`, `label`, `key`, and `generation`;
- `modelValue`, the fixture's source-of-truth model, and `controlValue`, the live `NSTextField.stringValue`, read directly rather than through AX;
- `mode`, `delayMs`, `attempts`, `appliedWrites`, `lastRequestedValue`, and `pendingWrites` (write IDs and requested values).

Default values are `<window>-<control>-original`, such as `primary-first-original`. The `NSTextField` subclass intercepts Accessibility value writes:

- `normal`: update the model and native control immediately;
- `ignored`: record the attempt without changing the model/control;
- `delayed`: record and schedule the change after `delayMs` (default 250, allowed range 0–10000).

Changing a mode does not cancel writes already scheduled. Reset, control recreation, and window replacement invalidate earlier delayed callbacks; they cannot write into replacement generations. Reordering preserves pending writes for the same objects. The controller serializes commands and delayed writes on the AppKit main thread.

`runNonce` identifies one fixture process. `resetGeneration` identifies resets within that process. `revision` advances on fixture mutation commands and AX write attempts/applications; it is an attribution marker, not an atomic AX snapshot version. Generation counters describe fixture object replacement and are not exposed to the production computer-use API.

## Verification boundary

A runner should launch the fixture, obtain native targets from readiness, exercise the computer-use API, then request `state` to check every field in both windows. Count an unchanged already-correct field separately from a newly applied write. For delayed writes, use the action's verification deadline and subsequently inspect independent fixture state; elapsed time alone is not completion evidence.

Fixture startup/lifecycle smoke verification covered readiness, duplicate labels, mode configuration, row reorder, control replacement, changed window IDs after close/reopen, reset attribution, clean termination, zero fixture activations, and unchanged foreground PID. This validates fixture behavior and lifecycle, not the external AX transport or the computer-use layer. The baseline runner must independently establish AX inspection and normal/ignored/delayed writes through that layer.
