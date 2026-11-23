---
name: macos-computer-use-native
description: Use the native macOS Computer Use MCP server to launch apps/URLs and inspect or control Mac apps and browsers (background-first, with opt-in foreground input). Follow this skill when a task calls for macOS desktop control or specifies this CUA server.
---

# Native macOS computer use

Use the connected server's `capabilities`, `targets`, `open`, `observe`, `act`, and `waitFor` tools. Use the client-provided tool schemas for arguments.

## Launch, find, and observe

1. Check `capabilities` for available permissions, actions, and the installed execution mode (`backgroundRequired` or `foregroundAllowed`).
2. Use `targets` to find an open window. Filter by exact `bundleId` when known, or `titleContains` / `ownerContains` (and `unbundledOnly: true` for launcher child processes). Pass the returned `key` as `target` with its exact `pid` and `windowId`. Resolve ambiguity before observing or acting.
3. Use `open` to launch an app (`bundleId` or `appName`) and/or open a URL (`url`, e.g. `https://...` or `file://...`) in a browser or default handler. By default `open` runs in the background (`activate: false`) without stealing focus and returns the `pid`, `bundleId`, and any visible `targets` ready for `observe`. Setting `activate: true` requires `foregroundAllowed`.
4. Observe the target close to the action:
   - Use `scope: "webArea"` on browsers to skip tab strips, toolbars, and window chrome and focus the 256-element cap on the page DOM.
   - Use `interactiveOnly: true` to return only interactive controls (buttons, links, inputs, checkboxes, menus, scroll areas, web areas).
   - Use `scope: "menuBar"` to inspect the app's native macOS menu bar items (`"File > New Tab"`, `"History > Back"`, etc.) before calling `invokeMenu`.
   - Use `axSelectors` (with exact `label`, `identifier`, or substring `labelContains`) when a narrower read suffices.
   - Use `includeValues: true` when you need to read or verify field/text values.
   - Use `includeOcr: true` (optionally with `ocrQuery`) for visible text omitted by Accessibility (such as PDFs or `<canvas>`), and `includeScreenshot: true` when visual/pixel evidence or foreground pointer actions are needed.

## Act and verify

- Keep actions in the background by default. Pass the exact `target`, current `observationId`, and the element's `reference` as `elementRef`, using only actions advertised by that element:
  - `setValue` replaces the whole value and verifies readback.
  - `typeText` replaces the current UTF-16 selection via `AXSelectedText`.
  - `press` invokes `AXPress` on buttons, links, checkboxes, tabs.
  - `confirm` invokes `AXConfirm` (submit text/search fields, forms, dialogs).
  - `showMenu` invokes `AXShowMenu` (open popups, dropdowns, context menus).
  - `cancel` invokes `AXCancel` (dismiss sheets, popovers, search inputs).
  - `scrollToVisible` scrolls a web/list control into view in the background.
  - `scroll` moves a live `AXScrollArea` (`axis`: `vertical` or `horizontal`, nonzero `amount` in `[-1000, 1000]`).
  - `invokeMenu` executes an exact native macOS `AXMenuBar` path (e.g. `path: ["File", "New Tab"]`, `["History", "Back"]`, `["Edit", "Copy"]`) in the background without stealing focus.
- Each step has an `actionId` and an `operation` with `kind` and `params`. Group up to 16 compatible steps on one target and observation within one `budgetMs`.
- Use `waitFor` with `elementExists` / `elementAbsent` (supporting `labelContains`), `valueEquals`, `valueContains`, `enabled`, `urlContains`, or `windowAbsent`. Pass `includeValues: true` and/or `scope: "webArea"` on `waitFor` when you want values or page-scoped elements directly in the returned satisfied observation.
- Use foreground input only when `capabilities` reports `foregroundAllowed`, setting `foreground: true` on `act`:
  - Pointer actions (`click`, `doubleClick`, `rightClick`, `hover`, `drag`) require a fresh screenshot-backed observation (`includeScreenshot: true`) and verify target pixels/hit-testing before dispatch.
  - Keyboard actions include `key` (control-scoped or browser shortcuts), `hotkey` (arbitrary canonical key name like `"a"`–`"z"`, `"0"`–`"9"`, `"return"`, `"tab"`, `"escape"`, `"delete"`, `"space"`, `"f1"`–`"f12"` with `modifiers`: `["command", "control", "option", "shift"]` and optional `elementRef`), and `typeKeys` (Unicode text typing into the focused window/control).

## Recover from interrupted input

- For `not_dispatched` with `alreadySatisfied` and confirmed evidence, continue from the verified state.
- For `not_dispatched` with `targetStale`, re-find the window if needed, observe again, and retry with fresh references.
- For `unknown`, a lost receipt, or `dispatched` with uncertain effect, observe current state before repeating any mutation.
