<img src="brand/app-icon.svg" width="76" height="76" alt="UseUI app icon">

# UseUI

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon%20%26%20Intel)-lightgrey.svg)](docs/native-delivery.md)
[![Model Context Protocol](https://img.shields.io/badge/MCP-Standard%20Compatible-green.svg)](https://modelcontextprotocol.io)

A native **Model Context Protocol (MCP)** server for background-first desktop and browser automation — starting with macOS.

UseUI pairs a standalone Rust MCP host (`useui`) with a persistent Swift native runtime (`useui-runtime`) and a Chrome Native Messaging browser accelerator. End-user binaries are universal (`arm64` + `x86_64`) and require no Node.js or local compiler at runtime.

---

## Highlights

- **Background-First Native Control**: Inspect Accessibility trees, invoke semantic actions (`setValue`, `typeText`, `press`, `confirm`, `showMenu`, `cancel`, `invokeMenu`, `scroll`, `scrollToVisible`, window ops), and wait for UI state without stealing focus.
- **Fast Chromium Browser Accelerator (`browser`)**: Drives Chrome, Brave, Arc, and Edge tabs directly via Chrome Native Messaging (`active: false` background tabs, compact DOM snapshots, 1–16 step action sequences, parallel `batchRead`, respectful tab groups, closed Shadow DOM in-page stage cursor, and live human takeover) with zero open TCP ports and zero focus stealing.
- **Opt-In Temporary Foreground Escalation**: Start with `--allow-foreground` to permit per-request `foreground: true` sequences (clicks, double/right clicks, drags, scroll wheel, keys, hotkeys, Unicode typing, and `focusWindow`) for controls that cannot be driven in the background (such as `NSOpenPanel` or `<canvas>`), with live human-input checks and automatic focus restoration.
- **Fail-Closed Targeting & Honest Receipts**: Associates CoreGraphics and Accessibility windows by exact PID, logical bounds, and title. Every action revalidates retained AX identity and separates delivery (`not_dispatched`, `dispatched`, `unknown`) from verification (`confirmed`, `mismatch`, `unverified`).
- **Private by Default**: AX values and clipboard text are omitted unless explicitly requested (`includeValues: true` / `includeText: true`). Permissions are inspected via preflight APIs without triggering system prompts.
- **On-Screen Feedback, Menu Bar Live Island & Live Preview**: Optional `USEUI_VISUAL_FEEDBACK=1` renders UseUI's Mint/Ink click-through window marker, agent pointer, and unified macOS Menu Bar Live Island (streaming live Native AX + Chromium activity over a private Unix telemetry socket); `USEUI_LIVE_PREVIEW=1` (macOS 14.2+) opens a floating preview panel of the controlled window and attached sheet.

---

## Architecture

| Component | Path | Role |
| --- | --- | --- |
| Rust MCP host (`useui`) | `crates/useui-host`, `crates/useui-client` | MCP stdio server (`rmcp`), argument validation, host authority enforcement, end-to-end deadlines, Native Messaging host, and child-process supervision. |
| Swift native runtime (`useui-runtime`) | `runtime/` | Persistent per-connection macOS worker owning AX references, exact CG/AX window association, ScreenCaptureKit capture, Vision OCR, clipboard, and overlays. |
| Shared protocol v1 | `crates/useui-protocol`, `protocol/swift`, `protocol/fixtures` | Strict 8 MiB line-delimited JSON contract and conformance corpus shared between Rust and Swift. |
| Chromium MV3 extension | `extension/chromium/` | Manifest V3 extension bridging `browser` tool calls over Chrome Native Messaging. |
| macOS app & packaging | `packaging/macos/`, `scripts/` | `UseUI.app` setup helper, universal archive builder, and local DMG packager. |
| Legacy Node/Swift server | `src/`, `native/`, `server.mjs` | Existing `macos-computer-use-mcp` v3 server retained for backwards compatibility. |

---

## MCP Tools

| Tool | Scope |
| --- | --- |
| `capabilities` | Permission preflight (Accessibility, Screen Recording, event synthesis), browser bridge connection status, installed execution mode, and supported action kinds — without triggering permission prompts. |
| `browser` | Zero-focus-stealing Chromium tab and DOM automation over Chrome Native Messaging (`status`, `listTabs`, `openTab`, `navigate`, `snapshot`, `act`, `batchRead`, `closeTab`). |
| `targets` | Exact `(pid, windowId)` keys and logical bounds for visible windows (including unbundled processes), with filters (`bundleId`, `titleContains`, `ownerContains`, `unbundledOnly`) and optional offscreen windows, installed/running apps, and display geometry. |
| `open` | Launch applications (`bundleId` or `appName`) or open URLs/files in the background by default, with optional immediate post-launch `observe`. |
| `clipboard` | Read, write (`text`, `filePath`, or `imagePath`), or clear the macOS pasteboard without stealing focus. Text content is omitted on read unless `includeText: true`. |
| `observe` | Bounded AX tree snapshots (up to 256 controls) with short generation-scoped refs, `scope` (`window`, `webArea`, `menuBar`), `interactiveOnly`, free-text `query`, structured `axSelectors`, Electron auto-AX, attached sheets, optional `eventHistory`, and opt-in screenshots / Vision OCR (macOS 14+). AX values are private by default. |
| `act` | Execute 1–16 ordered steps on one target, one observation, and one whole-request budget, with per-step delivery/verification receipts, optional `feedback`, and compound `observeAfter`. Supports background AX/window steps by default and foreground pointer/keyboard steps when `--allow-foreground` and `foreground: true` are set. |
| `waitFor` | Poll typed predicates (`elementExists`, `elementAbsent`, `enabled`, `valueEquals`, `valueContains`, `urlContains`, `ocrContains`, `windowAbsent`) within one deadline without mutating UI state. |

### Execution & Safety Semantics

- **Exact window binding & revalidation**: The runtime associates CG and AX windows through unique PID, exact logical bounds, and available titles. Each step revalidates the retained AX object, owning window, role/subrole, and raw AX identifier.
- **Bounded sequences**: Sequences target one window, one observation (original 60-second expiry), and one whole-request deadline. Settled progress is flushed before the next input step; read-only waits never claim input dispatch.
- **Visual evidence (macOS 14+)**: Opt-in ScreenCaptureKit screenshots and Vision OCR return mapped visual evidence (`imageToWindow` and `imageToScreen` transforms). macOS 13 supports the semantic AX route.
- **Compact feedback**: Optional `act.feedback` reports bounded changes to requested public projections using the same refs; `feedback: null` means unavailable, not unchanged.

See [docs/runtime.md](docs/runtime.md) and [docs/protocol.md](docs/protocol.md) for the full execution, privacy, locking, and evidence contract.

---

## Installation & Setup

### Option 1: Install `UseUI.app` from a Disk Image (Recommended)

1. Build (or download) the local DMG:
   ```sh
   sh scripts/package-dmg.sh
   ```
   The DMG and `.sha256` checksum are written to `.artifacts/dmg-dist`.
2. Open the DMG and drag **UseUI.app** into **Applications**.
3. Open **UseUI.app** to:
   - **Copy MCP Config** (automatically populated with `/Applications/UseUI.app/Contents/MacOS/useui` and an optional toggle for `--allow-foreground`),
   - **Install Browser Bridge** (registers the Chrome Native Messaging manifest and stages the unpacked MV3 extension), and
   - **Install Skill…** (copies `skills/useui` into a project's `.claude/skills/` folder for Claude Code Desktop).

For universal archive installation, code-signing checks, and v3 migration guidance, see [docs/native-delivery.md](docs/native-delivery.md).

### Option 2: Build from Source

**Prerequisites:**
- **macOS 13.0+** (Apple Silicon or Intel; **macOS 14+** for ScreenCaptureKit screenshots/OCR and **macOS 14.2+** for Live Preview)
- **Rust 1.88+** (`rustup`)
- **Swift 6** / Xcode Command Line Tools (`xcode-select --install`)
- **Node.js 20+** (for workspace scripts and tests)

```sh
git clone https://github.com/johnexzy/useui.git
cd useui
npm ci
npm run build:runtime
```

This builds and installs a matched pair at `.artifacts/runtime-install/useui` and `.artifacts/runtime-install/useui-runtime` (runnable directly via `npm run start:rust` or by its absolute path from any MCP client).

### MCP Client Configuration

Add `useui` to your MCP client configuration (Claude Desktop, Cursor, Windsurf, Antigravity, etc.):

```json
{
  "mcpServers": {
    "useui": {
      "command": "/Applications/UseUI.app/Contents/MacOS/useui",
      "args": ["--allow-foreground"],
      "env": {
        "USEUI_VISUAL_FEEDBACK": "1",
        "USEUI_LIVE_PREVIEW": "1"
      }
    }
  }
}
```

- Omit `"--allow-foreground"` to lock the session strictly to background-only authority (`backgroundRequired`).
- Omit `USEUI_VISUAL_FEEDBACK` or `USEUI_LIVE_PREVIEW` to run without on-screen overlays or the floating preview panel. See [on-screen feedback](docs/runtime.md#on-screen-feedback) and [live preview](docs/runtime.md#live-preview).

### Chromium Browser Accelerator Setup

Register the Native Messaging host manifest and stage the unpacked extension from the CLI (or via **Install Browser Bridge** inside `UseUI.app`):

```sh
/Applications/UseUI.app/Contents/MacOS/useui --install-browser-bridge
```

Then open `chrome://extensions` (or `brave://extensions`, `arc://extensions`, `edge://extensions`), enable **Developer mode**, and click **Load unpacked** on the staged extension directory printed by the command. Call `capabilities` to confirm `browserExtension.connected` is `true`.

---

## macOS Permissions & Privacy

Only grant the permissions needed by the features you use. macOS attributes privacy permissions to the host app launching the MCP server (your terminal, IDE, or desktop client):

1. **Accessibility**: Required for semantic observation and background AX actions. Does not require Screen Recording.
2. **Screen & System Audio Recording** (macOS 14+): Required only for `observe(includeScreenshot: true)` / `observe(includeOcr: true)`, `waitFor(ocrContains)`, and `USEUI_LIVE_PREVIEW=1`.
3. **Event Synthesis / Input Posting**: Required only when running with `--allow-foreground` and sending foreground pointer or keyboard steps.

Always call `capabilities` first. It checks permissions via Apple's preflight APIs without prompting. After granting a new permission in System Settings, restart or reconnect your MCP client if macOS retains stale privacy state.

---

## Testing & Verification

Run the automated Rust, Swift, protocol conformance, and MCP host test suites:

```sh
npm run test:runtime
python3 runtime/Tests/process-smoke.py
```

Exercise the installed native pair against the disposable two-window macOS fixture (requires Accessibility permission for the test host; mutates only the fixture):

```sh
sh test/fixtures/macos/build.sh
node test/runtime/semantic-live.mjs --repetitions 3
node test/runtime/composition-live.mjs --repetitions 3
```

Additional live and packaging checks:

```sh
npm run test:visual:live       # ScreenCaptureKit + Vision OCR (macOS 14+)
npm run test:foreground:live   # Foreground input & focus restoration
npm run test:browser:live      # Live Chromium observation/scroll benchmark
sh scripts/package-native.sh .artifacts/native-review
python3 test/distribution/package-smoke.py .artifacts/native-review/*.tar.gz
```

---

## Documentation

- [Native installation, DMG, and v3 migration guide](docs/native-delivery.md)
- [Rust MCP host, semantic observations, and bounded composition](docs/runtime.md)
- [Rust–Swift protocol v1 contract](docs/protocol.md)
- [Selective AX reads and bounded transient retention](docs/selective-observation.md)
- [Bounded recovery evaluation](docs/recovery.md)
- [Disposable two-window macOS fixture](docs/fixture.md)
- [Matched fixture and model evaluation](docs/evaluation.md)
- [Legacy baseline and measurement boundaries](docs/baseline.md)
- [Agent skill instructions (`useui`)](skills/useui/SKILL.md)
- [Brand kit and logo guidelines](brand/README.md)

---

## Legacy Node/Swift Server (`macos-computer-use-mcp`)

The npm entry point (`server.mjs`, published as `macos-computer-use-mcp`) remains available alongside UseUI for existing v3 workflows:

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

Set `"env": { "MACOS_COMPUTER_USE_UNSAFE": "1" }` only when global pointer/keyboard input, foreground activation, or `run_applescript` is explicitly required. Legacy npm publishing is manual-only via the `Publish to npm` GitHub Actions workflow (`workflow_dispatch`).

<details>
<summary>Legacy v3 tools, local build, and test commands</summary>

### Build & Test (Legacy v3)

```sh
npm install
npm run build
npm test                       # Fail-closed and matching regressions
npm run test:background -- Calculator
npm run test:live              # Requires Calculator and System Settings open
npm run test:foundations       # Baseline + Rust + Swift protocol checks
```

### Legacy v3 Tools

| Tool | Description |
| --- | --- |
| `get_capabilities` | Reports permission readiness and safe/unsafe policy without prompting. |
| `list_windows` | Lists open application windows, PIDs, titles, and bounds in Z-order. |
| `get_active_app` | Returns the frontmost app via `NSWorkspace`. |
| `inspect_accessibility` | Reads semantic controls from a background window (`includeValues: true` opt-in). |
| `wait_for_accessibility` | Waits for semantic controls in an exact background window. |
| `set_accessibility_value` | Sets a semantic control value while verifying background preservation. |
| `perform_accessibility_action` | Invokes `press`, `focus`, `confirm`, `cancel`, increment/decrement, or menu actions. |
| `screenshot` | Captures the display or a background window (`screencapture -l <wid>`) with optional cursor marker. |
| `find_text` / `click_text` / `wait_for_text` | Apple Vision OCR search, disambiguated click, and reactive text polling. |
| `mouse_click` / `type_text` / `press_key` / `scroll` | Targeted AX input by default; untargeted global input requires `MACOS_COMPUTER_USE_UNSAFE=1`. |
| `launch_app` / `open_url` | Background launch by default (`activate: true` requires unsafe mode). |
| `run_applescript` | Omitted unless `MACOS_COMPUTER_USE_UNSAFE=1` is set. |

</details>

---

## Contributing

Contributions are welcome — from bug fixes and Accessibility edge cases to browser accelerator improvements, documentation, and tests.

Before opening a pull request, please read [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Local toolchain setup (Rust 1.88+, Swift 6, Node.js 20+, Xcode Command Line Tools)
- Repository layout and Rust–Swift protocol parity rules
- Core safety, privacy, and receipt invariants
- Required formatting, linting, unit, and smoke checks matching CI

---

## License

MIT © [John Oba](https://github.com/johnexzy)
