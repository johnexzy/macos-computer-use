---
name: macos-computer-use-native
description: Use the native macOS Computer Use MCP server for tasks in open Mac apps, such as reading a PDF in Preview, editing a TextEdit document, or working with a dialog. Follow this skill when a task calls for macOS desktop control or specifies this CUA server.
---

# Native macOS computer use

Use the connected server's `capabilities`, `targets`, `observe`, `act`, and `waitFor` tools. Use the client-provided tool schemas for arguments.

## Find and observe

1. Check `capabilities` for available permissions, actions, and the installed execution mode.
2. Use `targets` to find the intended open window. Filter by exact `bundleId` when known. If that misses an open app, use `titleContains` or `ownerContains` instead. A launcher child process may own the window without its own bundle ID. For that case, combine a title or owner filter with `unbundledOnly: true`. Pass the returned `key` as `target` with its exact `pid` and `windowId`. Resolve any target ambiguity before observing or acting.
3. Observe that target close to the action. Use `includeValues: true` when you need to read or verify field values. Use `axSelectors` for known controls when a narrower read suffices. Partial coverage, an omitted value, or `enabled: null` gives incomplete evidence.
4. Use `includeOcr: true` for visible text that Accessibility omits, such as PDF content. Request `includeScreenshot: true` when layout or image evidence is needed. The live preview and pointer are operator feedback. Use tool results as task evidence.
5. For windows without a bundle ID, use `observe` as usual. It probes the actual window owner's AX tree. Add window screenshot or OCR when the app omits controls or reports unavailable AX coverage.

## Act and verify

- Keep actions in the background by default. Pass the exact `target`, current `observationId`, and the element's `reference` as `elementRef`. Choose an action the observed element advertises. `setValue` replaces the whole value, `typeText` replaces the current selection, `press` invokes an advertised control, and `scrollToVisible` scrolls a web/list control into view in the background.
- For browsers (Chrome, Dia, Brave, Edge, Arc, Safari), `observe` exposes live `url` fields on `AXWebArea` and `AXLink` elements, retains visible interactive controls ahead of dense text/cell runs when hitting the 256-element cap, and automatically enables Chromium web accessibility so `<a href>`, `<button>`, `<input>`, and checkboxes work in the background via `press` and `setValue`. Use `waitFor` with `{"kind":"urlContains","params":{"contains":"..."}}` (optionally scoped with `elementRef`) to verify navigation. For non-AX `<canvas>` or image-only controls, escalate to `includeScreenshot: true` + `includeOcr: true` + `ocrQuery`.
- To scroll, use `operation: {"kind":"scroll","params":{"elementRef":"<scroll area reference>","axis":"vertical","amount":250}}` with a live `AXScrollArea` that advertises `scroll`. Choose `vertical` or `horizontal`. `amount` is a nonzero integer from -1000 to 1000. Positive moves down or right. `250` requests 25% of the scrollbar's full range. Scroll runs in the background and verifies movement. Observe again to find newly revealed content.
- Each step has an `actionId` and an `operation` with `kind` and `params`. Group up to 16 compatible steps on one target and observation within one `budgetMs`. Observe again after any change that introduces new controls, including an attached sheet. A wait inside `act` uses the original refs. Use standalone `waitFor` for an expected state change.
- Check each receipt's `delivery` and `verification`, plus `stopReason` and `remainingSteps` for a sequence. Use an observable `expect`, such as `valueEquals` or `urlContains`, or read back the intended result. A confirmed field edit verifies its value. When the task requires a saved file, also verify the save through the app.
- Use foreground input only when the operator permits it and the connection reports `foregroundAllowed`. Request `foreground: true` on that `act` call. Control-scoped keys (`return`, `tab`, `escape`, `saveAs`) need the exact focused control; window-scoped browser navigation shortcuts (`focusAddressBar`, `reload`, `newTab`, `closeTab`, `navigateBack`, `navigateForward`) target the validated focused browser window. A `click` needs a fresh screenshot-backed observation. When AX is unavailable, the exact window must already be in the foreground with the destination unobscured. Use a coordinate click without AX conditions and observe again to verify the result.

## Recover from interrupted input

- For `not_dispatched` with `alreadySatisfied` and confirmed evidence, continue from the verified state.
- For a scroll that returns `verificationFailed` with `not_dispatched`, check the current scroll area's position and visible content before deciding what to do next. A scrollbar at the requested boundary cannot move farther. `unsupported` means the selected axis has no usable Accessibility scrollbar for this route.
- For `not_dispatched` with a stale target or reference, find the same intended window again if needed, observe it, then retry the unapplied step with a fresh reference.
- For `unknown`, a lost receipt, or `dispatched` with uncertain effect, observe the current state before any further input. Keep earlier settled effects. Repeat an action only if fresh evidence shows it is still needed and safe to repeat. Report any unresolved effect.
