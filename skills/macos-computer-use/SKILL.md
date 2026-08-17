---
name: macos-computer-use
description: Expert guidelines, decision trees, and best practices for automating macOS applications with the macos-computer-use MCP server. Use when an agent needs to perform desktop automation, interact with native Mac apps or background browser windows, execute non-intrusive clicks via Apple Vision OCR, or reactively sync with live UI states without hijacking the user's physical mouse or keyboard focus.
---

# macOS Computer Use: Agent Operating Playbook

This skill provides the standard operating procedures, decision trees, and failure recovery heuristics for operating the `macos-computer-use` MCP server on macOS.

---

## 🧭 Core Philosophy & Rules of Engagement

1. **Semantic-First, Never Guess Coordinates**:
   * **Always prefer `click_text` and `find_text`** over raw $(x, y)$ `mouse_click`.
   * Apple Vision OCR runs in sub-$30\text{ ms}$ on the Apple Neural Engine. It guarantees zero-drift clicking on buttons, labels, and input fields.
   
2. **Preserve User Focus (Non-Intrusive by Default)**:
   * **Always pass `appName` or `windowId`** to tool calls (`screenshot`, `click_text`, `find_text`, `mouse_click`, `type_text`).
   * Specifying the target application directs events straight to that process queue (`postToPid`) and captures background buffers without stealing the user's active keyboard focus or moving their physical mouse cursor.

3. **Reactive Polling Over Blind Sleeps**:
   * **Never call `screenshot` immediately after an action that triggers an async network request or animation** (e.g., submitting a search query, opening a modal, waiting for a dropdown).
   * **Always use `wait_for_text`** with the expected text label and an appropriate timeout.

---

## 🎯 Tool Decision Matrix

| Intent | Recommended Tool | Why |
| :--- | :--- | :--- |
| **Click a button, link, or tab with text** | `click_text({ text: "Submit", appName: "Safari" })` | Locates the exact bounding box center via OCR and clicks non-intrusively. |
| **Inspect elements / coordinates** | `find_text({ text: "Search", appName: "Google Chrome" })` | Returns exact bounding box `{ x, y, width, height, centerX, centerY }` in logical points. |
| **Wait for async UI transition** | `wait_for_text({ text: "Results", appName: "Google Chrome", timeoutSeconds: 5.0 })` | Polls target window buffer at $100\text{ ms}$ intervals until text renders. |
| **Take a background visual snapshot** | `screenshot({ appName: "Google Chrome", cursor: {x, y} })` | Captures only the target window buffer without bringing it to front. |
| **Type text into focused field** | `type_text({ text: "hello world", appName: "Google Chrome" })` | Injects text directly into the target application. |
| **Click icon without text** | `find_text` on neighboring label $\rightarrow$ offset `mouse_click`, OR inspect screenshot. | Uses semantic anchor text to calculate the icon's coordinate offset. |
| **Scroll container or page** | `scroll({ x, y, deltaY: -5, appName: "Notes" })` | Scrolls target container. Negative `deltaY` scrolls down; positive scrolls up. |

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
| Guessing $(x, y)$ pixels from visual screenshots | Use `find_text` / `click_text` to let Vision OCR resolve exact coordinates. |
| Calling `screenshot` immediately after clicking a submit button | Call `wait_for_text` with the expected success state or destination header. |
| Calling `launch_app` for background tasks | Pass `appName` to `screenshot`, `click_text`, or `find_text` to work in the background. |
| Re-trying failed clicks with the exact same stale coordinates | Capture a fresh frame or call `scroll` if the target is out of view. |
| Clicking top-level browser chrome $(y < 80)$ when targeting web page inputs | Use `click_text` targeting the in-page placeholder text. |

---

## 🔧 Failure Recovery & Self-Healing

1. **Target Text Not Found (`found: false`)**:
   * **Container Not Scrolled**: The element might be below the fold. Call `scroll({ x: 500, y: 500, deltaY: -6, appName: targetApp })` and re-run `find_text`.
   * **Wrong Active Tab / Sub-Window**: Call `list_windows({ appName: targetApp })` to verify the correct window or tab is targeted.
   * **Synonym / Alternate Wording**: Search for a substring or alternate label (e.g. `"Search or type a URL"` vs `"Search"`).

2. **Input Not Registering Keystrokes**:
   * Ensure the text field was clicked first via `click_text` to guarantee cursor focus before calling `type_text`.
