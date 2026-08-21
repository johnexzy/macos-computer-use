# 🍏 macOS Computer Use (MCP Server)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon%20%26%20Intel)-lightgrey.svg)]()
[![Model Context Protocol](https://img.shields.io/badge/MCP-Standard%20Compatible-green.svg)](https://modelcontextprotocol.io)

An ultra-fast, native **Model Context Protocol (MCP)** server that gives LLMs and autonomous agents visual inspection and fail-closed desktop automation on macOS.

Built with a compiled Swift core leveraging Apple's native **CoreGraphics**, **Vision OCR (`VNRecognizeTextRequest`)**, and **Accessibility APIs** for semantic background actions. Untargeted input remains an explicit global CoreGraphics fallback.

---

## ⚡ Key Highlights

* **🎯 Native Apple Vision OCR (`find_text` / `click_text`)**: Finds visible text with explicit `exact`, `word`, `prefix`, or `substring` matching and refuses ambiguous clicks unless an occurrence is selected.
* **🛡️ Fail-Closed Targeting**: `windowId` is authoritative. Invalid IDs and app/window mismatches return errors instead of falling back to another window or the full display.
* **🔐 Safe by Default**: Global pointer/keyboard input, foreground app activation, and custom AppleScript are disabled unless the MCP process starts with `MACOS_COMPUTER_USE_UNSAFE=1`.
* **🩺 Permission Preflight**: `get_capabilities` reports Accessibility, Screen Recording, and event-synthesis readiness without calling macOS permission request APIs.
* **♿ Background Accessibility Actions**: Inspect controls, set values, press semantic actions, and target editable controls without activating their application.
* **⏱️ Semantic Background Waiting**: Waits for Accessibility controls to appear without taking a screenshot or requiring Screen Recording.
* **🖱️ Live Agent Cursor**: Clicks and scrolling glide a distinctive, click-through cursor overlay to the target, show success or failure feedback, and fade when idle without moving your physical pointer.
* **👁️ Matching Screenshot Cursor (`mark_cursor`)**: Returned action screenshots render the same agent cursor at the target coordinate.
* **⚡ Reactive UI Synchronization (`wait_for_text`)**: Replaces blind `sleep()` timeouts with a high-speed OCR polling loop that resolves the instant dynamic autocomplete dropdowns, modals, or state changes appear.
* **🖼️ Window-Isolated Screen Capture**: Captures target application buffers cleanly in the background (`screencapture -l <wid> -o -x`) without bringing the window to the front or capturing overlapping windows.

---

## 🛠️ Tools Exposed

| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| **`click_text`** | Finds OCR text, glides the live cursor to it, resolves ambiguity, and invokes the matching Accessibility control. | `text`, `matchMode`, `occurrence`, `appName`, `windowId`, `returnScreenshot` |
| **`find_text`** | Inspects on-screen or window-specific text and returns exact bounding boxes and logical coordinates. | `text`, `appName` (optional), `windowId` (optional) |
| **`wait_for_text`** | Reactively polls the target window/screen until expected text appears (autocomplete dropdowns, toasts, sheets). | `text`, `appName` (optional), `timeoutSeconds` (default: 5.0) |
| **`screenshot`** | Captures the entire display or a specific background application window with optional virtual cursor rendering. | `appName`, `windowId`, `maxWidth`, `format` (`jpeg` \| `png`), `cursor` (`{x, y}`) |
| **`get_capabilities`** | Reports permission readiness, platform details, and the active safe/unsafe policy without requesting access. | None |
| **`list_windows`** | Lists open application windows, process IDs (`pid`), titles, and coordinate bounds in front-to-back Z-order. | `appName` (optional filter) |
| **`inspect_accessibility`** | Reads semantic controls from an exact background window. Values are private by default and require `includeValues: true`. | `appName` or `windowId`, `selector`, `roles`, `maxResults` |
| **`wait_for_accessibility`** | Waits for one or more semantic controls in an exact background window. | `appName` or `windowId`, `selector`, `minCount`, `timeoutMs` |
| **`set_accessibility_value`** | Sets a semantic control value while checking that the target stayed in the background. | `appName` or `windowId`, `selector`, `value` |
| **`perform_accessibility_action`** | Performs `press`, `focus`, `confirm`, `cancel`, increment/decrement, or menu actions without activating the target app. | `appName` or `windowId`, `selector`, `action` |
| **`mouse_click`** | Glides the live cursor to `(x, y)`, then invokes the targeted AX control. Untargeted global clicks require unsafe mode. | `x`, `y`, `appName`, `windowId`, `relativeCoords`, `button`, `clickCount` |
| **`type_text`** | Uses verified application-targeted delivery when a target and semantic selector are supplied. `foreground_allowed` requires unsafe mode. | `text`, `appName` or `windowId`, `selector`, `executionMode` |
| **`press_key`** | Posts supported keys to a semantic editable control in `background_required` mode. `foreground_allowed` requires unsafe mode. | `key`, `appName` or `windowId`, `selector`, `executionMode`, `modifiers` |
| **`scroll`** | Glides the live cursor to the target and adjusts an AX scrollbar. Untargeted global scrolling requires unsafe mode. | `x`, `y`, `deltaY`, `deltaX`, `appName`, `windowId` |
| **`launch_app`** | Launches in the background by default. `activate: true` also requires unsafe mode. | `appName`, `activate` |
| **`get_active_app`** | Returns the frontmost application from `NSWorkspace` without System Events/Automation access. | None |
| **`run_applescript`**| Runs custom AppleScript only when unsafe mode is enabled; omitted from the default tool list. | `script` |

---

## 🚀 Installation & Setup

### Run with npx

Configure an MCP client to download, build, and launch the latest public package:

```json
{
  "mcpServers": {
    "macos-computer-use": {
      "command": "npx",
      "args": ["-y", "macos-computer-use-mcp"]
    }
  }
}
```

The package includes an ad-hoc-signed universal Swift helper for Apple Silicon and Intel Macs, so `npx` does not require a local Swift compiler or install-script approval.

The default configuration exposes semantic background automation and read-only inspection. For workflows that intentionally need global pointer/keyboard input, foreground activation, or arbitrary AppleScript, opt in explicitly:

```json
{
  "mcpServers": {
    "macos-computer-use": {
      "command": "npx",
      "args": ["-y", "macos-computer-use-mcp"],
      "env": {
        "MACOS_COMPUTER_USE_UNSAFE": "1"
      }
    }
  }
}
```

### 1. Prerequisites
* **macOS 13.0+** (Apple Silicon or Intel)
* **Node.js 20+**
* **Xcode Command Line Tools** only when building from source:
  ```bash
  xcode-select --install
  ```

### 2. Clone & Build
```bash
git clone https://github.com/johnexzy/macos-computer-use.git
cd macos-computer-use
npm install
npm run build
```

---

## 🔒 Capability-Based macOS Permissions

Only grant the permission needed by the tools you use. macOS attributes the permission to the host application running the MCP server (Terminal, OpenCode, Cursor, VS Code, and so on):

1. **Accessibility**: Required for semantic inspection and actions. It does not require Screen Recording.
2. **Screen & System Audio Recording**: Required only for screenshots and Vision OCR tools such as `screenshot`, `find_text`, `click_text`, and `wait_for_text`.
3. **Event synthesis**: Unsafe-mode global CoreGraphics clicks, typing, key presses, and scrolling require event-posting access. Semantic Accessibility actions do not use this global fallback.
4. **Automation**: Can be requested by macOS only when unsafe mode is enabled and `run_applescript` sends an event to another application. Core input and background tools use the native helper instead of System Events.

Call `get_capabilities` before protected operations. Permission inspection uses Apple's preflight APIs and does not open a permission prompt. If access is absent, screenshot/OCR and global input paths return `SCREEN_RECORDING_PERMISSION_REQUIRED` or `INPUT_POSTING_PERMISSION_REQUIRED` before dispatch. Grant access manually in System Settings, then reconnect the MCP if the host still holds stale privacy state.

macOS can still require the host app to be restarted after a newly granted privacy permission. This is enforced by macOS; the server does not repeatedly prompt or request unrelated permissions.

Background UI automation is cooperative: macOS can address Accessibility elements in another process, but an application may ignore targeted keyboard events or change its identifiers in a later release. These tools return explicit unsupported/unconfirmed errors in those cases instead of activating the app or reporting a false success.

---

## 🔌 MCP Configuration

Add this server to your MCP client configuration:

### **Antigravity / Claude Desktop / Cursor / Windsurf**
Add to your `mcp_config.json` / `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macos-computer-use": {
      "command": "node",
      "args": ["/absolute/path/to/macos-computer-use/server.mjs"]
    }
  }
}
```

---

## 🧪 Testing the Native Swift Helper Directly

You can test the native binary directly from your terminal:

```bash
# Display resolution and scaling
./native_helper size

# List active Chrome windows in Z-order
./native_helper list_windows "Google Chrome"

# Find a button or text on screen with Apple Vision OCR in ~30ms
./native_helper find_text "Search" "Google Chrome"

# Reactively wait for dynamic text to appear
./native_helper wait_for_text "quantum" "Google Chrome" nil 5.0
```

Run the automated fail-closed and matching regressions:

```bash
npm test
```

Verify semantic inspection against a background Calculator window:

```bash
npm run test:background -- Calculator
```

With Calculator and System Settings open, run the live native-app smoke suite. The test opts into unsafe mode because it uses AppleScript to create and clean up TextEdit fixtures:

```bash
npm run test:live
```

Mutating tool results include an `execution` object with a versioned contract, delivery method, verification level, foreground-preservation state, and target. Coordinate-based actions retain `status: "delivered_unverified"`; verify consequential post-state with semantic inspection, OCR, or a screenshot.

The MCP server starts one cursor overlay process lazily on the first click or scroll and stops it when the MCP connection closes. The overlay never intercepts mouse input, joins all Spaces and full-screen windows, and reports `cursorOverlay.status: "unavailable"` without blocking the requested action if AppKit cannot display it.

---

## 📦 Publishing

Pushes to `main` run the npm publishing workflow. To release a new version, update the version in `package.json` and `package-lock.json` before merging. Versions that already exist on npm are tested and skipped.

---

## 📄 License

MIT © [John Oba](https://github.com/johnexzy)
