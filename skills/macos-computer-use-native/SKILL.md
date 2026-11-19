---
name: macos-computer-use-native
description: Use the native macOS Computer Use MCP server for tasks in open Mac apps, such as reading a PDF in Preview, editing a TextEdit document, or working with a dialog. Follow this skill when a task calls for macOS desktop control or specifies this CUA server.
---

# Native macOS computer use

Use the connected server's `capabilities`, `targets`, `observe`, `act`, and `waitFor` tools. Use the client-provided tool schemas for arguments.

## Find and observe

1. Check `capabilities` for available permissions, actions, and the installed execution mode.
2. Use `targets`, optionally with `bundleId`, to find the intended open window. Match the app and document title, then pass the returned `key` as `target` with its exact `pid` and `windowId`. Resolve ambiguity before input.
3. Observe that target close to the action. Use `includeValues: true` when you need to read or verify field values. Use `axSelectors` for known controls when a narrower read suffices. Partial coverage, an omitted value, or `enabled: null` gives incomplete evidence.
4. Use `includeOcr: true` for visible text that Accessibility omits, such as PDF content. Request `includeScreenshot: true` when layout or image evidence is needed. The live preview and pointer are operator feedback. Use tool results as task evidence.

## Act and verify

- Keep actions in the background by default. Pass the exact `target`, current `observationId`, and the element's `reference` as `elementRef`. Choose an action the observed element advertises. `setValue` replaces the whole value, `typeText` replaces the current selection, and `press` invokes an advertised control.
- Each step has an `actionId` and an `operation` with `kind` and `params`. Group up to 16 compatible steps on one target and observation within one `budgetMs`. Observe again after any change that introduces new controls, including an attached sheet. A wait inside `act` uses the original refs. Use standalone `waitFor` for an expected state change.
- Check each receipt's `delivery` and `verification`, plus `stopReason` and `remainingSteps` for a sequence. Use an observable `expect`, such as `valueEquals`, or read back the intended result. A confirmed field edit verifies its value. When the task requires a saved file, also verify the save through the app.
- Use foreground input only when the operator permits it and the connection reports `foregroundAllowed`. Request `foreground: true` on that `act` call. A `key` needs the exact focused control. The `saveAs` key sends the macOS Save As shortcut where supported. A `click` needs a fresh screenshot-backed observation with matching AX geometry.

## Recover from interrupted input

- For `not_dispatched` with `alreadySatisfied` and confirmed evidence, continue from the verified state.
- For `not_dispatched` with a stale target or reference, find the same intended window again if needed, observe it, then retry the unapplied step with a fresh reference.
- For `unknown`, a lost receipt, or `dispatched` with uncertain effect, observe the current state before any further input. Keep earlier settled effects. Repeat an action only if fresh evidence shows it is still needed and safe to repeat. Report any unresolved effect.
