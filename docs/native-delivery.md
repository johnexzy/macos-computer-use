# Native macOS installation and migration

The native archive contains `bin/useui` and its sibling `bin/useui-runtime`.
End users need neither Node.js, Rust, Swift nor a local compiler. Keep the pair
together and configure the absolute path to `useui`; its working directory can
be anywhere, including a path containing spaces. Installation does not start a
daemon or replace the existing npm server.

## Install from a disk image

Open the local review DMG and drag **UseUI.app** into
**Applications**. Double-click the installed app and choose **Copy MCP
Config**. Merge the copied server entry into your MCP client
configuration and reconnect the client. The setup window uses the app's actual
installed path and enables the activity badge and live preview. The MCP client
launches the runtime when it connects.

In Claude Code Desktop, use **Install Skill…** and select the folder
you open as your local project. The setup window copies the bundled
`useui` skill into that project's `.claude/skills/`
directory. Start or reopen a local Code session in that folder and choose
`/useui` from the slash menu to invoke it with a task.
Claude Code can also choose the skill when relevant.
[Claude Code Desktop skills](https://code.claude.com/docs/en/desktop#use-skills)

The command in the copied configuration is typically
`/Applications/UseUI.app/Contents/MacOS/useui`. The helper
ships next to it inside the app. Permission preflight runs in the MCP client's
launch context. See the permission guidance below if a capability is unavailable.

Build the DMG and its SHA-256 checksum with:

```sh
sh scripts/package-dmg.sh
```

The default output directory is `.artifacts/dmg-dist`. The script also accepts a
different output directory. The image and its app are intended for local
review. The app is ad-hoc signed. Public distribution requires a Developer ID
Application identity and [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Supported targets and evidence

The deployment target remains **macOS 13.0**, on **Apple Silicon and Intel**.
Semantic AX observations/actions work within the app's advertised capabilities.
`targets` also lists visible windows owned by verified live processes without a
bundle ID. Narrow these results with `unbundledOnly`, `ownerContains`, or
`titleContains`. Use the exact returned PID and window ID. The runtime attempts AX
on the owner process and exposes only controls it can bind to that window.
Screenshot and OCR remain available when AX cannot describe the window.
Screenshot/OCR capture requires macOS 14+ and Screen Recording permission; on
macOS 13 the visual channel reports `unsupported` while AX can remain available.
The build produces and checks both `arm64` and `x86_64` slices in each executable.

Builder requirements are the macOS SDK, Swift 6, Rust 1.88+, both Rust Darwin
targets, Python 3 and the standard Apple command-line tools. End-user requirements
are only supported macOS and an MCP client. Xcode's own host OS requirement is
separate from the executable's deployment target. Apple's
[Xcode support table](https://developer.apple.com/xcode/system-requirements) and
[Xcode 27 release notes](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-27-release-notes)
document universal back deployment; Rust documents
[Darwin targets and `MACOSX_DEPLOYMENT_TARGET`](https://doc.rust-lang.org/rustc/platform-support/apple-darwin.html).

`manifest.json` records the exact build tools, revision, signing identifiers,
dependencies and per-slice deployment metadata. A successful cross-build or
Rosetta launch does not establish native Intel or macOS 13/14 runtime coverage.
Record those release checks explicitly rather than treating a deployment target
as a test result.

The package build leaves build-only Rust proc macros unstripped. This avoids the
documented [Rust/LLVM LINKEDIT alignment defect](https://github.com/rust-lang/rust/issues/157750)
when macOS 27 loads affected compiler plugins. It does not change the deployment
target or patch/sign compiler libraries after the build.

## Review archive and client setup

This initial artifact is **ad-hoc signed**, not Developer ID signed or notarized.
Signature integrity is checked; public-download Gatekeeper approval is not claimed.
Do not disable Gatekeeper or remove quarantine as a substitute for the release
checks below. Keep a review archive separate from a production installation.

Verify the archive against its adjacent `.sha256` file, extract it to a new
directory, and verify its contents with `shasum -a 256 -c SHA256SUMS` from inside
that directory. Both binaries can also be checked with:

```sh
codesign --verify --strict --all-architectures /absolute/path/bin/useui
codesign --verify --strict --all-architectures /absolute/path/bin/useui-runtime
/absolute/path/bin/useui --version
```

Use `mcp-config.example.json`, replacing its placeholder path:

```json
{
  "mcpServers": {
    "useui": {
      "command": "/absolute/path/with spaces/useui-native/bin/useui",
      "args": []
    }
  }
}
```

The command is a path, not a shell command string. Use no `npx`, `node`, `swift`,
build command or shell quoting inside it. The bundled helper resolves relative to
the actual host executable. `--helper` is an explicit development override;
production client configuration should omit it. Background authority is the
default. With the operator's `--allow-foreground` grant, an individual
`act` request can select foreground input with `foreground: true`. The
background route remains the default for other calls.
Visual-only coordinate clicks require the exact window to be foreground and
unobscured at the click point. The runtime rechecks the selected pixels and
window identity before dispatch. AX-backed input can raise its retained window
and restore the previous focus under the existing foreground checks.

Connect the client and call `capabilities` before protected operations. It uses
preflight APIs and does not request permissions. Permission booleans are evidence
for that actual launch context, not a promise that another MCP client has the
same permissions. macOS can attribute access to the responsible client, launcher
or executable; record the executable paths and signing identity shown by that
installation. Grant only required access manually in System Settings, then
restart/reconnect the client when necessary. A rebuilt/ad-hoc-signed executable
can change privacy attribution. Never auto-grant permissions during installation.

The host supervises one persistent helper per connection. Client EOF, SIGINT and
SIGTERM close it and reap it; no automatic restart or mutation replay occurs.
If a connection fails after possible input, preserve its unknown delivery receipt
and reconcile the actual state before another attempt.

## v3 workflow migration

The native API is deliberate and smaller. The existing `server.mjs`/npm entry
points still start v3; installing an archive does not migrate them automatically.

| v3 tool/workflow | Native replacement or gap |
| --- | --- |
| `get_capabilities` | `capabilities`; permission preflight and supported actions. |
| `list_windows` | `targets`; retain the returned PID/window ID and logical bounds. |
| `get_active_app` | No equivalent public tool. Background preservation is enforced by native dispatch and verification. |
| `inspect_accessibility` | Use `observe` with explicit `includeValues` and optional `axSelectors`. Each actionable ref belongs to its live observation and target. |
| `wait_for_accessibility` | `waitFor` with typed element existence/absence, enabled, exact value or window absence. Selectors are not arbitrary substring queries. |
| `screenshot` | `observe(includeScreenshot:true)` on an exact target; MCP image plus explicit transform metadata. No full-desktop capture. |
| `find_text` | `observe(includeOcr:true,ocrQuery:...)` returns Vision substring geometry in image pixels. Include a screenshot to prepare a foreground click. |
| `wait_for_text` | No OCR wait predicate. A bounded caller can request fresh visual observations. |
| `set_accessibility_value` | `act` → `setValue`; intrinsic exact readback, including already-satisfied state. |
| `perform_accessibility_action` | `act` → `press` for advertised AXPress. Other actions such as focus/increment/show-menu remain unsupported. |
| `type_text` | `act` → `typeText` only on an explicit live AXSelectedText-settable element; no global typing or whole-value substitution. |
| `mouse_click`, `click_text` | A foreground `click` step sends a left click after fresh pixel, window and focus checks. For text, obtain the point from an observation that includes OCR and its matching screenshot. |
| `press_key` | A foreground `key` step on the exact focused AX reference. Supported keys are Return, Tab, Escape, Backspace and arrows. |
| `scroll` | `act` → `scroll` on an observed `AXScrollArea` that advertises it. Select `vertical` or `horizontal` and a signed amount in thousandths of the full range. Positive moves down or right. Background delivery requires a readable, writable AX scrollbar and verifies movement. Observe again to locate newly revealed content. |
| `launch_app`, `open_url`, `run_applescript` | Unsupported; use separate explicitly authorized setup when required. |
| Cursor overlay | [On-screen feedback](runtime.md#on-screen-feedback) is built into the runtime and enabled per MCP connection with `USEUI_VISUAL_FEEDBACK=1`. |

For transient selected state, opt in to `eventHistory` on `observe`.
History includes a cursor and coverage evidence. Use refs from the current
observation to act.

An act request has at most 16 typed steps, one exact target and one whole-operation
budget. Reference retention is bounded; re-observe after layout/identity changes.
An observation ID or TTL does not establish fresh geometry. A failed or partial
sequence retains its settled prefix, independent delivery/verification and unsent
suffix. Do not translate an uncertain v3 result into a known native rejection.

## Build and verify in a checkout

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
sh scripts/package-native.sh .artifacts/native-review
python3 test/distribution/package-smoke.py .artifacts/native-review/useui-native-1.1.0-macos-universal.tar.gz
```

The smoke extracts only the archive into a clean path containing spaces, uses a
different working directory and a minimal PATH, and exercises the actual MCP
stdio handshake, repeated permission preflight, EOF and both termination signals.
It sends no desktop mutations, captures no images and requests no permissions.
An explicit `--architecture x86_64` can check the Intel slice on Intel or an
already available Rosetta installation. Do not install Rosetta automatically.

## Rollback and release checklist

1. Preserve the existing MCP configuration and the prior known-good native pair.
2. Require a clean source revision for release; review checksums, deployment
   slices, system-only dependency paths and signing metadata.
3. Run clean-path/package smoke on Apple Silicon and native Intel, then test
   macOS 13 and macOS 14 visual support on the actual supported systems.
4. Separately authorize any live permission/AX/image checks in the intended MCP
   clients. Record their actual privacy attribution and graceful shutdown.
5. For public distribution, obtain separate release authority, use a Developer ID
   identity, notarize and staple/verify the chosen distribution format. Credentials
   and notarization are outside this local review build.
6. Review the version, artifact hashes, migration gaps and permissions before
   changing a client command. Activation is a separate action.
7. To roll back, disconnect the new client, restore its saved v3 command or prior
   native pair path, and reconnect. Do not run two mutating servers simultaneously.
   Keep existing permission grants; do not reset unrelated macOS privacy data.

CI creates downloadable review artifacts only. The legacy npm workflow is
manual-only; neither a PR nor a main push publishes. No native release upload,
package-manager installation, privileged installer or activation occurs here.
