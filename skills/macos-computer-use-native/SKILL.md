---
name: macos-computer-use-native
description: Use the native macOS Computer Use MCP server to launch apps/URLs and inspect or control Mac apps and browsers (background-first, with opt-in foreground input). Follow this skill when a task calls for macOS desktop control or specifies this CUA server.
---

# Native macOS computer use

Use the connected server's `capabilities`, `browser`, `targets`, `open`, `clipboard`, `observe`, `act`, and `waitFor` tools. Use the client-provided tool schemas for arguments.

## Fast Chromium Browser Accelerator (`browser` tool)

1. Check `capabilities` first. When `browserExtension` reports `connected=true`, **prefer the `browser` tool** for all Chromium (Chrome/Brave/Arc/Edge) web workflows instead of AX `observe`/`act`:
   - Runs in background tabs (`active: false`) inside the user's real signed-in browser profile over Chrome Native Messaging with zero open TCP ports and zero focus stealing.
   - `browser(action: "openTab", url, active: false, returnSnapshot: true, includeText: true)` opens a background tab, waits for load + hydration, and returns a compact DOM outline (`bN.M` refs) + readable text in **one turn**.
   - `browser(action: "act", tabId, snapshotId, steps: [...], returnSnapshot: true, includeText: true)` executes 1–16 sequential DOM steps (`click` by `ref` or visible `text`/`role`/`selector`, `type`, `select`, `pressKey`, `scroll`, and `waitFor` with `urlContains`/`textContains`/`selector`/`ms`) and returns the fresh post-action snapshot in **one turn**.
   - `browser(action: "navigate", tabId, url | history: "back"|"forward"|"reload", returnSnapshot: true)` handles direct navigation or history traversal in **one turn**.
   - `browser(action: "batchRead", urls: [...], closeAfter: true)` opens up to 6 URLs in parallel background tabs, extracts clean main-content text and links, closes temporary tabs, and returns all pages in **one single turn**.
   - If `browserExtension` reports `connected=false` (or for Safari / restricted `chrome://` pages / native macOS apps), seamlessly fall back to native `open` + `observe` + `act` below.

## Launch, find, and observe (Native Mac Apps & Fallback)

1. Check `capabilities` for available permissions, actions, and the installed execution mode (`backgroundRequired` or `foregroundAllowed`).
2. Use `targets` to discover open windows, running/installed apps, and displays:
   - Filter windows by exact `bundleId`, case-insensitive `titleContains` / `ownerContains`, or `unbundledOnly: true` for launcher child processes.
   - Pass `includeOffscreen: true` to include minimized, hidden, or other-Space windows (each target gains an `onScreen` flag).
   - Pass `includeApps: true` to list running and installed apps, and `includeDisplays: true` to inspect display bounds (top-left logical points matching `target.bounds`), scale factors, and primary status.
   - Pass the returned `key` as `target` with its exact `pid` and `windowId`. Resolve ambiguity before observing or acting.
3. Use `open` to launch an app (`bundleId` or `appName`) and/or open a URL (`url`, e.g. `https://...` or `file://...`) in a browser or default handler. By default `open` runs in the background (`activate: false`) without stealing focus and returns the `pid`, `bundleId`, and any visible `targets`. Pass `observe: { scope, interactiveOnly, query, includeValues }` on `open` to capture and register an initial observation on the first opened target in the same call. Setting `activate: true` requires `foregroundAllowed`.
4. Use `clipboard` to read, write, or clear the macOS system clipboard without stealing focus:
   - `action: "read"` returns `changeCount`, UTI `types`, and `textBytes` without leaking contents unless `includeText: true` is explicitly set.
   - `action: "write"` requires exactly one of `text` (plain UTF-8), `filePath` (absolute local file path), or `imagePath` (absolute local image path).
   - `action: "clear"` empties the clipboard.
5. Observe the target close to the action:
   - Use `scope: "webArea"` on browsers to skip tab strips, toolbars, and window chrome and focus the 256-element cap on the page DOM.
   - Use `interactiveOnly: true` to return only interactive controls (buttons, links, inputs, checkboxes, menus, scroll areas, web areas).
   - Use `scope: "menuBar"` to inspect the app's native macOS menu bar items (`"File > New"`, `"File > New Tab"`, etc.) and verify `enabled: true` before calling `invokeMenu`.
   - Use `query` for fast case-insensitive substring search across `label`, `identifier`, `subrole`, `url` (and `value` only when `includeValues: true`) — works with `scope: "webArea"`, `scope: "menuBar"`, and `interactiveOnly: true`.
   - Use `axSelectors` (with optional `role` plus exact `label`, `identifier`, or substring `labelContains`) when you need structured query coverage or ambiguity reporting.
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
  - `invokeMenu` executes an exact native macOS `AXMenuBar` path (e.g. `path: ["File", "New"]`, `["File", "New Tab"]`) in the background without stealing focus when the menu item is `enabled: true` while inactive. Note that macOS AppKit disables first-responder / key-window menu items (such as `["History", "Back"]` or `["Edit", "Copy"]` in Chrome/Safari) while an app is inactive; for background browser navigation use the window's native toolbar `AXButton` controls (`scope: "window"`, e.g. `Back`/`Forward`/`Reload`) with `press`.
  - `setWindowFrame` moves and/or resizes the target window (`bounds: {x, y, width, height}` in top-left logical coordinates) in the background via AX.
  - `windowAction` runs background window lifecycle actions (`action: "minimize"` or `"close"`, optionally paired with `expect: {kind: "windowAbsent", params: {}}`).
- Each step has an `actionId` and an `operation` with `kind` and `params`. Group up to 16 compatible steps on one target and observation within one `budgetMs`. Pass `observeAfter: { scope, interactiveOnly, query, includeValues, includeOcr, ocrQuery, includeScreenshot }` on `act` to capture and register a fresh post-action observation in the same turn (collapsing `act` → `waitFor` → `observe` into a single call when combined with `step.expect`).
- Use `waitFor` with `elementExists` / `elementAbsent` (role-optional, supporting `label`, `labelContains`, `identifier`), `valueEquals`, `valueContains`, `enabled`, `urlContains`, `ocrContains` (visual Vision OCR text wait — works on `<canvas>` and AX-unavailable windows too, with optional `cropWindow`), or `windowAbsent`. Pass `includeValues: true` and/or `scope: "webArea"` on `waitFor` when you want values or page-scoped elements directly in the returned satisfied observation.
- **Background-first, temporary foreground escalation**: keep all standard steps in the background (`browser` `active: false`, `open` `activate: false`, `act` `foreground: false`). Escalate to `foreground: true` on `act` **only** when `capabilities` reports `foregroundAllowed` AND a control genuinely cannot be driven in the background—for example:
  - **macOS `NSOpenPanel` / `NSSavePanel` file pickers** (especially navigating to a path or inside a `.app` bundle): use `hotkey` (`key: "g"`, `modifiers: ["command", "shift"]`) → `typeKeys` (the target path) → `hotkey` (`key: "return"`) → press `Select`/`Open` (or `key: "return"`). The runtime automatically checks for live human input and restores focus to the prior app immediately afterward.
  - **`<canvas>` / visual-only controls without AX** or **Cocoa outline/table rows (`actions: []`)** requiring pointer `click`, `doubleClick`, `rightClick`, `hover`, `drag`, or `scrollWheel`: pair with a fresh `includeScreenshot: true` observation so target pixels and hit-testing are verified before dispatch.
  - **`focusWindow`**: raises and persistently focuses the exact target window without restoring prior focus afterwards (use only when the user asks to bring an app forward).
  - **Keyboard actions**: `key` (control-scoped or browser shortcuts), `hotkey` (arbitrary canonical key name like `"a"`–`"z"`, `"0"`–`"9"`, `"return"`, `"tab"`, `"escape"`, `"delete"`, `"space"`, `"f1"`–`"f12"` with `modifiers`: `["command", "control", "option", "shift"]` and optional `elementRef`), and `typeKeys` (Unicode text typing into the focused window/control).

## Recover from interrupted input

- For `not_dispatched` with `alreadySatisfied` and confirmed evidence, continue from the verified state.
- For `not_dispatched` with `targetStale`, re-find the window if needed, observe again, and retry with fresh references.
- For `unknown`, a lost receipt, or `dispatched` with uncertain effect, observe current state before repeating any mutation.
