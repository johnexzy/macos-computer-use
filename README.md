# 🍏 macOS Computer Use (MCP Server)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon%20%26%20Intel)-lightgrey.svg)]()
[![Model Context Protocol](https://img.shields.io/badge/MCP-Standard%20Compatible-green.svg)](https://modelcontextprotocol.io)

An ultra-fast, native **Model Context Protocol (MCP)** server that gives LLMs and autonomous agents full visual inspection and desktop automation capabilities on macOS **without hijacking your physical hardware mouse or keyboard focus**.

Built with a compiled Swift core leveraging Apple's native **CoreGraphics**, **Vision OCR (`VNRecognizeTextRequest`)**, and direct process-level event routing (`CGEvent.postToPid`).

---

## ⚡ Key Highlights

* **🎯 Sub-30ms Apple Vision OCR (`find_text` / `click_text`)**: No blind $(x, y)$ coordinate guessing. The agent finds buttons, labels, and text placeholders by name with pixel accuracy using Apple Neural Engine acceleration.
* **🛡️ Non-Intrusive Background Execution**: Decoupled from global macOS hardware event taps. Clicks, scrolls, and keystrokes can be targeted directly to specific application PIDs while you continue working in your IDE or browser.
* **👁️ Virtual Cursor Overlay (`mark_cursor`)**: The agent's target coordinates are visually drawn onto screenshot frames (cyan target ring + magenta pulse dot) without moving your physical mouse on screen.
* **⚡ Reactive UI Synchronization (`wait_for_text`)**: Replaces blind `sleep()` timeouts with a high-speed OCR polling loop that resolves the instant dynamic autocomplete dropdowns, modals, or state changes appear.
* **🖼️ Window-Isolated Screen Capture**: Captures target application buffers cleanly in the background (`screencapture -l <wid> -o -x`) without bringing the window to the front or capturing overlapping windows.

---

## 🛠️ Tools Exposed

| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| **`click_text`** | Finds any button, label, or UI text via Apple Vision OCR and smoothly clicks its exact center. | `text`, `appName` (optional), `windowId` (optional), `button`, `clickCount`, `returnScreenshot` |
| **`find_text`** | Inspects on-screen or window-specific text and returns exact bounding boxes and logical coordinates. | `text`, `appName` (optional), `windowId` (optional) |
| **`wait_for_text`** | Reactively polls the target window/screen until expected text appears (autocomplete dropdowns, toasts, sheets). | `text`, `appName` (optional), `timeoutSeconds` (default: 5.0) |
| **`screenshot`** | Captures the entire display or a specific background application window with optional virtual cursor rendering. | `appName`, `windowId`, `maxWidth`, `format` (`jpeg` \| `png`), `cursor` (`{x, y}`) |
| **`list_windows`** | Lists open application windows, process IDs (`pid`), titles, and coordinate bounds in front-to-back Z-order. | `appName` (optional filter) |
| **`mouse_click`** | Clicks at logical `(x, y)` points (supports window-relative and PID-targeted routing). | `x`, `y`, `appName`, `windowId`, `relativeCoords`, `button`, `clickCount` |
| **`mouse_move`** | Smoothly glides mouse cursor to `(x, y)` coordinates. | `x`, `y`, `appName`, `relativeCoords`, `smooth`, `duration` |
| **`mouse_drag`** | Smoothly drags mouse from `(startX, startY)` to `(endX, endY)`. | `startX`, `startY`, `endX`, `endY`, `duration` |
| **`type_text`** | Injects plain text into active input fields (or directly into target process queues). | `text`, `appName` (optional), `windowId` (optional) |
| **`press_key`** | Presses special keys or keyboard shortcuts with modifiers. | `key` (`return`, `space`, `tab`, `escape`, `c`, etc.), `modifiers` (`command`, `shift`, `option`, `control`) |
| **`scroll`** | Scrolls the mouse wheel vertically and horizontally. | `x`, `y`, `deltaY`, `deltaX`, `appName`, `windowId` |
| **`launch_app`** | Launches or brings a macOS application to the front. | `appName` (e.g. `Google Chrome`, `Safari`, `Finder`, `Slack`, `Notes`) |
| **`get_active_app`** | Returns the currently active frontmost application name and window title. | None |
| **`run_applescript`**| Runs custom AppleScript for deep macOS Accessibility and UI hierarchy inspection. | `script` |

---

## 🚀 Installation & Setup

### 1. Prerequisites
* **macOS 13.0+** (Apple Silicon or Intel)
* **Node.js 18+**
* **Xcode Command Line Tools** (for compiling the native Swift binary):
  ```bash
  xcode-select --install
  ```

### 2. Clone & Build
```bash
git clone https://github.com/johnexzy/macos-computer-use.git
cd macos-computer-use
npm install
```
*(The `postinstall` script automatically compiles `native_helper.swift` into an optimized native binary).*

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

---

## 📄 License

MIT © [John Oba](https://github.com/johnexzy)
