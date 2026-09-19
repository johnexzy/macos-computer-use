---
name: macos-computer-use
description: macOS desktop and browser automation MCP server. Automates native Mac applications and background browser windows with sub-100ms Vision OCR, background window capture, semantic clicks, and focus preservation. Use when needing to interact with macOS apps, browse or search the web in Chrome/Safari, click buttons or text, fill inputs, or extract on-screen text without hijacking physical user focus.
---

# macOS Computer Use: Agent Operating Playbook

This skill provides comprehensive tool specifications, standard operating procedures, and strict efficiency heuristics for operating the `macos-computer-use` MCP server on macOS.

---

## 🚨 CRITICAL EFFICIENCY DIRECTIVE: DO NOT READ CODE OR SCHEMAS

> [!IMPORTANT]
> **DO NOT** search the filesystem (`find`, `grep`), inspect `~/.gemini/antigravity/mcp/...` schema JSON files, or read repository source code (`src/...`, `native/...`).
> **ALL TOOL PARAMETERS, TYPES, BEHAVIORS, AND EXAMPLES ARE FULLY DOCUMENTED BELOW.**
> You have immediate, direct access to invoke all tools listed here. Reading internal schemas or source code wastes turns, consumes context, and delays the user's task.

---

## ⚡ 3-Step Instant Web Browsing & Search Recipe

When asked to search the web, open a webpage, or research information using a browser:
**NEVER** launch Chrome, click the URL bar, type a search engine URL, press Enter, wait, click the search box, and type the query.
Instead, execute this **3-step instant recipe**:

```
Step 1: Direct URL Navigation (Background)
        open_url({
          url: "https://www.google.com/search?q=my+query+terms",
          appName: "Google Chrome"
        })

Step 2: Reactive Sync (Waits for results to render, sub-100ms)
        wait_for_text({
          text: "my query",
          appName: "Google Chrome",
          timeoutSeconds: 5.0
        })

Step 3: Capture Snapshot with Inline OCR (NO view_file needed!)
        screenshot({
          appName: "Google Chrome",
          extractText: true
        })
```

> [!TIP]
> **No need to call `view_file` on screenshots!** Passing `extractText: true` to `screenshot` automatically runs sub-100ms Apple Vision OCR and returns all on-screen text lines directly in the tool response text. Read the returned text directly!

---

## 🧭 Core Philosophy & Rules of Engagement

1. **Semantic-First, Never Guess Coordinates**:
   * **Always prefer `click_text` and `find_text`** over raw $(x, y)$ `mouse_click`.
   * Use `matchMode: "word"` or `"exact"` for actions. If multiple equally ranked matches exist, inspect candidates and pass `occurrence`.
   
2. **Preserve User Focus (Non-Intrusive by Default)**:
   * **Always pass `appName` or `windowId`** to tool calls (`screenshot`, `click_text`, `find_text`, `mouse_click`, `type_text`).
   * Prefer `windowId` in multi-window applications. It is authoritative and fails closed if stale or inconsistent with `appName`.
   * Targeted clicks and scrolling use Accessibility actions. Exact-window typing focuses the requested AX window before process delivery.
   * The live agent cursor is a click-through visual indicator. It does not move or replace the user's physical pointer.

3. **Reactive Polling Over Blind Sleeps**:
   * **Never call `screenshot` immediately after an action that triggers an async network request or animation** (e.g., submitting a search query, opening a modal, waiting for a dropdown).
   * **Always use `wait_for_text`** with the expected text label and an appropriate timeout.

4. **Verify Every Mutation**:
   * Action delivery is reported as `delivered_unverified` because dispatch success is not proof of the intended UI state.
   * After clicking, typing, or scrolling, verify the expected state with `wait_for_text`, `find_text`, or `screenshot`.

---

## 🛠️ Complete Tool Reference & Parameter Signatures

### 1. `open_url`
Open any `http://`, `https://`, or `file://` URL directly in a browser without stealing foreground focus.
* **`url`** (`string`, required): URL to open (e.g. `"https://www.google.com/search?q=agentic+ai"`).
* **`appName`** (`string`, optional): Target browser (e.g. `"Google Chrome"`, `"Safari"`). Defaults to default browser.
* **`background`** (`boolean`, optional, default `true`): If `true`, uses macOS `-g` flag so user focus is not interrupted.
* **`newWindow`** (`boolean`, optional, default `false`): Open in a new window instead of a new tab.

### 2. `screenshot`
Capture visual frame of entire display or a specific background application window.
* **`appName`** / **`targetApp`** (`string`, optional): Target app name (e.g. `"Google Chrome"`, `"Slack"`). Captures ONLY that window buffer in background without bringing it to front.
* **`windowId`** (`number`, optional): Specific window ID from `list_windows`.
* **`extractText`** (`boolean`, optional, default `false`): **HIGHLY RECOMMENDED.** Runs fast Apple Vision OCR and inlines all recognized text lines in the response so you never need to call `view_file` on image artifacts.
* **`maxWidth`** (`number`, optional, default `1440`): Max width to scale image (0 for raw resolution).
* **`format`** (`"jpeg" | "png"`, optional, default `"jpeg"`): Image format.
* **`cursor`** (`{ x: number, y: number }`, optional): Coordinates to render virtual agent cursor dot.

### 3. `click_text`
Find on-screen text via Apple Vision OCR and invoke its Accessibility action or click target point.
* **`text`** (`string`, required): Exact text or word to click (e.g. `"Sign In"`, `"Submit"`, `"Search"`).
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`matchMode`** (`"word" | "exact" | "prefix" | "contains"`, optional, default `"word"`): Matching strategy.
* **`occurrence`** (`number`, optional, default `1`): 1-based index if multiple matches exist.
* **`clickCount`** (`number`, optional, default `1`): 1 for single click, 2 for double click.
* **`button`** (`"left" | "right"`, optional, default `"left"`).

### 4. `find_text`
Inspect OCR coordinates and bounding boxes of on-screen text without performing a click.
* **`text`** (`string`, required): Text to search for.
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`matchMode`** (`"word" | "exact" | "prefix" | "contains"`, optional, default `"word"`).
* **`occurrence`** (`number`, optional): 1-based occurrence index.
* Returns: `{ found: boolean, matches: [{ text, bounds: { x, y, width, height, centerX, centerY }, confidence }] }`.

### 5. `wait_for_text`
Poll the target window buffer at high speed until expected text appears or timeout expires.
* **`text`** (`string`, required): Text string to wait for.
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`timeoutSeconds`** (`number`, optional, default `5.0`): Maximum time to wait in seconds.
* **`matchMode`** (`"word" | "exact" | "prefix" | "contains"`, optional, default `"word"`).

### 6. `type_text`
Inject keystrokes into the focused control or target window.
* **`text`** (`string`, required): String to type.
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`clearBeforeTyping`** (`boolean`, optional, default `false`): Select-all and backspace before typing.

### 7. `press_key`
Press a single keyboard key or key combination.
* **`key`** (`string`, required): Key name (e.g. `"Return"`, `"Tab"`, `"Escape"`, `"Space"`, `"Up"`, `"Down"`, `"Left"`, `"Right"`, `"Backspace"`, `"a"`, etc.).
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`modifiers`** (`string[]`, optional): Modifier keys (e.g. `["command"]`, `["shift", "command"]`, `["control"]`, `["option"]`).

### 8. `scroll`
Scroll target window or element under coordinate.
* **`deltaY`** (`number`, required): Vertical scroll amount. Negative values scroll down (reveal content below); positive values scroll up.
* **`deltaX`** (`number`, optional, default `0`): Horizontal scroll amount.
* **`x`** / **`y`** (`number`, optional): Logical coordinate inside the container to scroll.
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.

### 9. `mouse_click`
Fallback physical/AX click at raw coordinates when text is unavailable (e.g. icon buttons).
* **`x`** / **`y`** (`number`, required): Logical coordinates within target window or display.
* **`appName`** (`string`, optional): Target application name.
* **`windowId`** (`number`, optional): Target window ID.
* **`clickCount`** (`number`, optional, default `1`).
* **`button`** (`"left" | "right"`, optional, default `"left"`).

### 10. `list_windows`
List open application windows. By default returns curated list of real user application windows.
* **`appName`** (`string`, optional): Filter windows by application name.
* **`includeAll`** (`boolean`, optional, default `false`): If `true`, returns all system overlays, daemons, and offscreen buffers. Keep `false` to avoid token clutter.

### 11. `launch_app`
Launch or bring an application into running state.
* **`appName`** (`string`, required): Name of application (e.g. `"Google Chrome"`, `"Notes"`).
* **`background`** (`boolean`, optional, default `true`): Launch in background without activating foreground focus.

### 12. `get_active_app`
Returns the frontmost application currently focused by the physical user.
* Arguments: `{}` (none).

### 13. `get_capabilities`
Inspect available permissions and active server policies.
* Arguments: `{}` (none).

---

## 📋 Standard Operating Procedures (SOP)

### SOP 1: Interacting with Search Bars & Autocomplete Dropdowns
```
Step 1: Locate and focus search input
        -> click_text({ text: "Search", appName: "Google Chrome" })

Step 2: Enter query
        -> type_text({ text: "quantum computing", appName: "Google Chrome" })

Step 3: Reactively wait for dropdown suggestions to appear
        -> wait_for_text({ text: "quantum", appName: "Google Chrome", timeoutSeconds: 3.0 })

Step 4: Inspect suggestions and click desired row
        -> find_text({ text: "quantum", appName: "Google Chrome" })
        -> click_text({ text: "quantum computing roadmap", appName: "Google Chrome" })
```

### SOP 2: Submitting Forms & Confirming Success
```
Step 1: Fill inputs sequentially via semantic labels
        -> click_text({ text: "Email", appName: "Slack" })
        -> type_text({ text: "user@example.com", appName: "Slack" })

Step 2: Click submit action
        -> click_text({ text: "Send Message", appName: "Slack" })

Step 3: Wait for confirmation state / toast
        -> wait_for_text({ text: "Delivered", appName: "Slack", timeoutSeconds: 5.0 })
```

### SOP 3: Handling Icon-Only Elements (Magnifying Glass, Gear, Cross)
When an element has no text label:
1. Use `find_text` to locate a **stable neighboring text element** (e.g., search input placeholder, section header).
2. Calculate the relative offset from the neighbor element's bounding box.
3. Click using `mouse_click({ x: neighbor.centerX + offset, y: neighbor.centerY, appName: "..." })`.

---

## 🚫 Common Antipatterns to Avoid

| ❌ Antipattern | ✅ Correct Practice |
| :--- | :--- |
| Inspecting `.json` schema files or reading repo code | Use the full tool documentation provided in this skill document. |
| Typing URLs into browser address bar manually | Use `open_url({ url: "..." })` directly with Google search query or target URL. |
| Calling `view_file` on screenshot images | Pass `extractText: true` to `screenshot` to receive recognized text in the tool output. |
| Calling `screenshot` immediately after clicking a submit button | Call `wait_for_text` with the expected success state or destination header. |
| Calling `launch_app` for background tasks | Pass `appName` to `open_url`, `screenshot`, or `click_text` to work in the background. |
| Guessing $(x, y)$ pixels from visual screenshots | Use `find_text` / `click_text` to let Vision OCR resolve exact coordinates. |
| Re-trying failed clicks with the exact same stale coordinates | Capture a fresh frame or call `scroll` if the target is out of view. |

---

## 🔧 Failure Recovery & Self-Healing

1. **Target Text Not Found (`found: false`)**:
   * **Container Not Scrolled**: The element might be below the fold. Call `scroll({ x: 500, y: 500, deltaY: -6, appName: targetApp })` and re-run `find_text`.
   * **Wrong Active Tab / Sub-Window**: Call `list_windows({ appName: targetApp })` to verify the correct window or tab is targeted.
   * **Synonym / Alternate Wording**: Search for a substring or alternate label (e.g. `"Search or type a URL"` vs `"Search"`).

2. **Input Not Registering Keystrokes**:
   * Check whether `click_text` returned an AX action or a fail-closed error before calling `type_text`.
   * For multi-window apps, pass the exact `windowId` to both calls and verify the intended window changed.
