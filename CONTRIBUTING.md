# Contributing to UseUI

Thank you for your interest in contributing to **UseUI**. Whether you are fixing an Accessibility edge case, improving the Chromium browser accelerator, tightening protocol contracts, or updating documentation, this guide walks through our setup, invariants, and verification workflow.

---

## Prerequisites

Developing and testing the native runtime requires a Mac running **macOS 13.0+** (**macOS 14.2+** if working on ScreenCaptureKit visual capture, Vision OCR, or Live Preview):

- **Xcode Command Line Tools / Swift 6**:
  ```sh
  xcode-select --install
  ```
- **Rust 1.88+** (with `rustfmt` and `clippy`):
  ```sh
  rustup toolchain install stable --component rustfmt --component clippy
  ```
  If you are building or verifying universal packages (`arm64` + `x86_64`), also install both Apple Darwin targets:
  ```sh
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```
- **Node.js 20+** (CI runs Node 24) and **Python 3** (used by process and distribution smoke tests)

---

## Local Setup

```sh
git clone https://github.com/johnexzy/useui.git
cd useui
npm ci
npm run build:runtime
```

`npm run build:runtime` compiles the Rust MCP host (`useui`) and Swift native runtime (`useui-runtime`) and installs a matched pair into `.artifacts/runtime-install/`.

---

## Repository Layout

```text
crates/
  useui-protocol/       Shared Rust wire protocol v1 types, codecs, and schemas
  useui-client/         Typed Rust IPC client, framing, deadlines, and progress tracking
  useui-host/           Standalone MCP stdio server (`useui`) + Chrome Native Messaging host
protocol/
  swift/                Foundation-only Swift protocol v1 package (must match Rust crate)
  fixtures/             Cross-language valid, invalid, and correlation conformance fixtures
runtime/
  Sources/              Persistent Swift native runtime (`UseUIRuntime` + `useui-runtime`)
  Tests/                Swift unit tests + Python process-lifecycle smoke test
extension/
  chromium/             Manifest V3 Chromium Browser Accelerator extension
packaging/
  macos/                `UseUI.app` Info.plist and Setup launcher (`Setup.swift`)
scripts/                Runtime build, universal archive, and DMG packaging scripts
skills/
  useui/                Agent skill instructions bundled with `UseUI.app`
src/ & native/          Legacy v3 Node/Swift MCP server (`macos-computer-use-mcp`)
test/                   Automated contract tests, disposable macOS fixture, and live suites
docs/                   Architecture, protocol, delivery, evaluation, and evidence docs
```

---

## Core Design & Safety Invariants

UseUI enforces strict safety, privacy, and protocol guarantees. Please preserve these in every change:

1. **Rust–Swift protocol parity**: Any change to the private IPC contract must update both `crates/useui-protocol` and `protocol/swift`, add or update shared test vectors in `protocol/fixtures/`, and update `docs/protocol.md`. Never bypass `decode_line` / `Frame.decodeLine` or weaken the 8 MiB frame limit.
2. **Background-first & fail-closed**:
   - Exact `(pid, windowId)` targeting is authoritative. Never silently fall back to another window, activate an app in background mode, or guess an ambiguous target.
   - Execution authority (`backgroundRequired` vs. `foregroundAllowed`) is installed strictly by the operator (`--allow-foreground`). MCP tool arguments must never install or escalate authority.
3. **Privacy by default**:
   - AX field values and clipboard text stay redacted unless explicitly requested (`includeValues: true` / `includeText: true`).
   - Diagnostics, telemetry, and child stderr must never leak private field values or raw clipboard contents.
4. **Honest delivery & verification receipts**:
   - Keep delivery (`not_dispatched`, `dispatched`, `unknown`) independent from verification (`confirmed`, `mismatch`, `unverified`).
   - Never silently restart a dead helper mid-request or automatically replay mutations.
5. **No unexpected permission prompts**:
   - `capabilities` must use macOS preflight APIs only and never trigger permission dialogs.
6. **Self-contained native distribution**:
   - End-user native binaries (`useui` and `useui-runtime`) must not require Node.js, Rust, or Swift at runtime and must continue targeting macOS 13.0+ on both `arm64` and `x86_64` (MSRV Rust 1.88).

---

## Running Checks Before Opening a PR

Pull requests run `.github/workflows/foundations.yml` and `.github/workflows/native-package.yml` on macOS runners (Apple Silicon and Intel). Run the matching checks locally before pushing:

### 1. Rust formatting, lints, tests, and MSRV

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-features --locked
```

If you added new Rust language features or dependencies, also verify our documented minimum Rust version (1.88):

```sh
cargo +1.88.0 check --workspace --all-targets --all-features --locked
```

### 2. Swift protocol & runtime tests

```sh
swift test --package-path protocol/swift
swift test
```

### 3. Installed runtime build & automated smoke tests

```sh
npm run build:runtime
python3 runtime/Tests/process-smoke.py
node --test test/runtime/*.test.mjs
```

### 4. Baseline, evaluation, and legacy v3 checks

Run these when modifying `src/`, `native/`, `test/baseline/`, `test/evaluation/`, or shared build tooling:

```sh
node --test test/baseline/*.test.mjs test/evaluation/*.test.mjs
npm run build
npm test
sh test/fixtures/macos/build.sh
```

### 5. Live macOS & browser suites (opt-in)

When changing AX traversal, window association, visual capture, foreground input, or the Chromium extension, run the relevant live tests locally (requires Accessibility / Screen Recording permissions for your terminal; the fixture suites mutate only the disposable test app):

```sh
npm run test:semantic:live
npm run test:composition:live
npm run test:visual:live
npm run test:foreground:live
npm run test:browser:live
```

### 6. Packaging smoke (when touching `packaging/`, `scripts/`, or `extension/`)

```sh
sh scripts/package-native.sh .artifacts/native-review
python3 test/distribution/package-smoke.py .artifacts/native-review/*.tar.gz
sh scripts/package-dmg.sh
```

---

## Pull Request & Commit Guidelines

- **Branching**: Create a focused feature or fix branch from `main` (for example, `feat/...`, `fix/...`, `docs/...`).
- **Commit messages**: Follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `style:`), matching the repository history.
- **Keep docs and skills in sync**: When adding or changing MCP tool schemas, CLI flags, environment variables, or behavior, update `README.md`, the relevant files under `docs/`, and `skills/useui/SKILL.md`.
- **Describe verification clearly**: In your PR description, list which automated and live suites you ran, along with your macOS version and CPU architecture (`arm64` or `x86_64`) for live GUI/browser changes.
- **Keep the tree clean**: Never commit generated build artifacts (`.artifacts/`, `target/`, `.build/`, `dist/`, `native_helper`) or bump release versions in unrelated PRs.

---

## Reporting Bugs & Security Issues

When opening a bug report on [GitHub Issues](https://github.com/johnexzy/useui/issues), please include:

- macOS version and architecture (Apple Silicon or Intel)
- MCP client (Claude Desktop, Cursor, Antigravity, etc.)
- Output of `useui --version`
- Output of the `capabilities` tool (redacting any private paths or personal info)
- Minimal reproduction steps and any structured error code / receipt returned

For sensitive security or privacy issues (for example, authority bypasses, unintended foreground escalation, or private value leakage), please avoid posting exploit details publicly and contact the maintainer directly via the email listed in `package.json`.

---

## License

By contributing to UseUI, you agree that your contributions will be licensed under the [MIT License](LICENSE).
