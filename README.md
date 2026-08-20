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
* **♿ Accessibility Actions**: Targeted clicks invoke `AXPress`, targeted scrolling adjusts AX scrollbars, and exact-window typing focuses the requested AX window before process delivery.
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
| **`list_windows`** | Lists open application windows, process IDs (`pid`), titles, and coordinate bounds in front-to-back Z-order. | `appName` (optional filter) |
| **`mouse_click`** | Glides the live cursor to `(x, y)`, then invokes the targeted AX control or performs an explicit global click. | `x`, `y`, `appName`, `windowId`, `relativeCoords`, `button`, `clickCount` |
| **`type_text`** | Types into the active app or focuses an exact AX window before background process delivery. | `text`, `appName` (optional), `windowId` (optional) |
| **`press_key`** | Presses special keys or keyboard shortcuts with modifiers. | `key` (`return`, `space`, `tab`, `escape`, `c`, etc.), `modifiers` (`command`, `shift`, `option`, `control`) |
| **`scroll`** | Glides the live cursor to the target and adjusts an AX scrollbar; without a target, scrolls globally. | `x`, `y`, `deltaY`, `deltaX`, `appName`, `windowId` |
| **`launch_app`** | Launches or brings a macOS application to the front. | `appName` (e.g. `Google Chrome`, `Safari`, `Finder`, `Slack`, `Notes`) |
| **`get_active_app`** | Returns the currently active frontmost application name and window title. | None |
| **`run_applescript`**| Runs custom AppleScript for deep macOS Accessibility and UI hierarchy inspection. | `script` |

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

## 🔒 Required macOS Permissions

To allow desktop capture and input simulation, grant your host application (Terminal, iTerm2, Antigravity, Cursor, or VS Code) permissions in **System Settings > Privacy & Security**:

1. **Screen & System Audio Recording**: Required for `screenshot` and visual OCR.
2. **Accessibility**: Required for `mouse_click`, `type_text`, and `press_key`.

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

With Calculator, System Settings, and two TextEdit windows open, run the live native-app smoke suite:

```bash
npm run test:live
```

Mutating actions return `status: "delivered_unverified"`. Verify the expected post-state with `wait_for_text`, `find_text`, or a screenshot before continuing.

The MCP server starts one cursor overlay process lazily on the first click or scroll and stops it when the MCP connection closes. The overlay never intercepts mouse input, joins all Spaces and full-screen windows, and reports `cursorOverlay.status: "unavailable"` without blocking the requested action if AppKit cannot display it.

---

## 📦 Publishing

Pushes to `main` run the npm publishing workflow. To release a new version, update the version in `package.json` and `package-lock.json` before merging. Versions that already exist on npm are tested and skipped.

---

## 📄 License

MIT © [John Oba](https://github.com/johnexzy)
