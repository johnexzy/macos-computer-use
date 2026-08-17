#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const NATIVE_HELPER = path.join(__dirname, "native_helper");

class AgentCursorOverlay {
  constructor() {
    this.child = null;
    this.reader = null;
    this.readyPromise = null;
    this.resolveReady = null;
    this.rejectReady = null;
    this.readyTimer = null;
    this.pending = new Map();
    this.nextId = 1;
    this.lastError = "";
  }

  async start() {
    if (this.child && this.readyPromise) {
      return this.readyPromise;
    }

    this.lastError = "";
    this.readyPromise = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    const child = spawn(NATIVE_HELPER, ["cursor_overlay"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    this.reader = createInterface({ input: child.stdout });
    this.reader.on("line", (line) => this.handleLine(line));
    child.stderr.on("data", (chunk) => {
      this.lastError = `${this.lastError}${chunk}`.slice(-1000);
    });
    child.stdin.on("error", (error) => this.handleExit(child, error));
    child.once("error", (error) => this.handleExit(child, error));
    child.once("exit", (code, signal) => {
      this.handleExit(
        child,
        new Error(
          this.lastError.trim() ||
            `cursor overlay exited${signal ? ` from ${signal}` : ` with code ${code}`}`,
        ),
      );
    });
    this.readyTimer = setTimeout(() => {
      this.rejectReady?.(new Error("cursor overlay did not become ready"));
      this.stop();
    }, 2000);

    return this.readyPromise;
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      return;
    }

    if (message.status === "ready") {
      clearTimeout(this.readyTimer);
      this.readyTimer = null;
      this.resolveReady?.(message);
      this.resolveReady = null;
      this.rejectReady = null;
      return;
    }

    const request = this.pending.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    this.pending.delete(message.id);
    request.resolve(message);
  }

  handleExit(child, error) {
    if (this.child !== child) return;
    clearTimeout(this.readyTimer);
    this.readyTimer = null;
    this.rejectReady?.(error);
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.resolve({ status: "unavailable", error: error.message });
    }
    this.pending.clear();
    this.reader?.close();
    this.reader = null;
    this.child = null;
    this.readyPromise = null;
    this.resolveReady = null;
    this.rejectReady = null;
  }

  async send(command) {
    try {
      await this.start();
      if (!this.child?.stdin.writable) {
        throw new Error("cursor overlay input is unavailable");
      }

      const id = String(this.nextId++);
      const response = new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          resolve({ status: "unavailable", error: "cursor overlay command timed out" });
        }, 2500);
        this.pending.set(id, { resolve, timer });
      });
      this.child.stdin.write(`${JSON.stringify({ id, ...command })}\n`);
      return await response;
    } catch (error) {
      return { status: "unavailable", error: error.message };
    }
  }

  stop() {
    clearTimeout(this.readyTimer);
    this.readyTimer = null;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.resolve({ status: "unavailable", error: "cursor overlay stopped" });
    }
    this.pending.clear();
    this.reader?.close();
    this.reader = null;
    this.child?.kill();
    this.child = null;
    this.readyPromise = null;
  }
}

const agentCursor = new AgentCursorOverlay();

async function runPointAction(x, y, helperArgs, successFeedback) {
  const cursorOverlay = await agentCursor.send({
    action: "move",
    x,
    y,
    durationMs: 160,
  });

  try {
    const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
    const action = JSON.parse(stdout.trim());
    if (action.status !== "ok") {
      throw targetError(action.code || "ACTION_FAILED", action.error || "action could not be delivered");
    }
    await agentCursor.send({ action: successFeedback });
    return { action, cursorOverlay };
  } catch (error) {
    await agentCursor.send({ action: "error" });
    throw error;
  }
}

process.once("exit", () => agentCursor.stop());
process.stdin.once("end", () => agentCursor.stop());

// Key code mapping for macOS System Events
const KEY_CODES = {
  return: 36,
  enter: 36,
  tab: 48,
  space: 49,
  backspace: 51,
  delete: 117,
  escape: 53,
  esc: 53,
  up: 126,
  down: 125,
  left: 123,
  right: 124,
  pageup: 116,
  pagedown: 121,
  home: 115,
  end: 119,
  f1: 122,
  f2: 120,
  f3: 99,
  f4: 118,
  f5: 96,
  f6: 97,
  f7: 98,
  f8: 100,
  f9: 101,
  f10: 109,
  f11: 103,
  f12: 111,
};

async function getDisplayInfo() {
  try {
    const { stdout } = await execFileAsync(NATIVE_HELPER, ["size"]);
    return JSON.parse(stdout.trim());
  } catch (err) {
    return { width: 1800, height: 1169, scale: 2, pixelWidth: 3600, pixelHeight: 2338 };
  }
}

async function findWindowByApp(appName) {
  try {
    const { stdout } = await execFileAsync(NATIVE_HELPER, ["find_window", appName]);
    const parsed = JSON.parse(stdout.trim());
    if (parsed.status === "ok") {
      return parsed;
    }
  } catch (_) {}
  return null;
}

async function getWindowBounds(windowId) {
  try {
    const { stdout } = await execFileAsync(NATIVE_HELPER, ["get_window_bounds", String(windowId)]);
    const parsed = JSON.parse(stdout.trim());
    if (parsed.status === "ok") {
      return parsed;
    }
  } catch (_) {}
  return null;
}

async function listAllWindows(appName = null) {
  try {
    const args = ["list_windows"];
    if (appName) args.push(appName);
    const { stdout } = await execFileAsync(NATIVE_HELPER, args);
    return JSON.parse(stdout.trim());
  } catch (err) {
    return [];
  }
}

function targetError(code, message) {
  const error = new Error(`${code}: ${message}`);
  error.code = code;
  return error;
}

function normalizeAppName(value) {
  return String(value || "")
    .normalize("NFKC")
    .replace(/\p{Cf}/gu, "")
    .trim()
    .toLocaleLowerCase();
}

function windowMatchesApp(windowInfo, appName) {
  const query = normalizeAppName(appName);
  if (!query) return true;
  return [windowInfo?.appName, windowInfo?.title]
    .map(normalizeAppName)
    .some((candidate) => candidate.includes(query));
}

async function resolveTarget({ windowId = null, appName = null, targetApp = null } = {}) {
  if (appName && targetApp && normalizeAppName(appName) !== normalizeAppName(targetApp)) {
    throw targetError("TARGET_MISMATCH", `appName "${appName}" and targetApp "${targetApp}" disagree`);
  }

  const requestedApp = appName || targetApp;

  if (windowId !== null && windowId !== undefined) {
    if (!Number.isInteger(windowId) || windowId <= 0) {
      throw targetError("INVALID_TARGET", `windowId must be a positive integer; received ${windowId}`);
    }

    const windowInfo = await getWindowBounds(windowId);
    if (!windowInfo) {
      throw targetError("TARGET_NOT_FOUND", `windowId ${windowId} does not exist`);
    }
    if (requestedApp && !windowMatchesApp(windowInfo, requestedApp)) {
      throw targetError(
        "TARGET_MISMATCH",
        `windowId ${windowId} belongs to "${windowInfo.appName}", not "${requestedApp}"`,
      );
    }
    return windowInfo;
  }

  if (requestedApp) {
    const windowInfo = await findWindowByApp(requestedApp);
    if (!windowInfo) {
      throw targetError("TARGET_NOT_FOUND", `no window found for application "${requestedApp}"`);
    }
    return windowInfo;
  }

  return null;
}

async function captureScreenshot({
  maxWidth = 1440,
  format = "jpeg",
  cursor = null,
  windowId = null,
  appName = null,
  targetApp = null,
} = {}) {
  const ext = format === "png" ? "png" : "jpg";
  const mimeType = format === "png" ? "image/png" : "image/jpeg";
  const tmpFile = path.join(os.tmpdir(), `mcp_screen_${Date.now()}.${ext}`);

  const windowInfo = await resolveTarget({ windowId, appName, targetApp });

  try {
    const screencaptureArgs = ["-x"];

    if (windowInfo && windowInfo.windowId) {
      screencaptureArgs.push("-o", "-l", String(windowInfo.windowId));
    }

    if (format === "jpeg") {
      screencaptureArgs.push("-t", "jpg");
    } else {
      screencaptureArgs.push("-t", "png");
    }
    screencaptureArgs.push(tmpFile);

    await execFileAsync("/usr/sbin/screencapture", screencaptureArgs);

    const display = await getDisplayInfo();

    // Mark virtual synthetic cursor indicator on screenshot
    if (cursor && typeof cursor.x === "number" && typeof cursor.y === "number") {
      try {
        const baseWidth = windowInfo?.bounds?.width || display.width;
        await execFileAsync(NATIVE_HELPER, [
          "mark_cursor",
          tmpFile,
          String(cursor.x),
          String(cursor.y),
          String(baseWidth),
        ]);
      } catch (_) {}
    }

    // Downscale if requested
    if (maxWidth && maxWidth > 0) {
      await execFileAsync("/usr/bin/sips", ["-Z", String(maxWidth), tmpFile]);
    }

    const imageBuffer = await fs.readFile(tmpFile);
    const base64 = imageBuffer.toString("base64");

    return {
      base64,
      mimeType,
      display,
      windowInfo,
    };
  } finally {
    await fs.unlink(tmpFile).catch(() => {});
  }
}

async function runAppleScript(script) {
  try {
    const { stdout, stderr } = await execFileAsync("/usr/bin/osascript", ["-e", script]);
    return { output: stdout.trim(), error: stderr ? stderr.trim() : null, exitCode: 0 };
  } catch (err) {
    return {
      output: err.stdout?.trim() || null,
      error: err.stderr?.trim() || err.message,
      exitCode: typeof err.code === "number" ? err.code : 1,
    };
  }
}

async function resolveCoordinatesAndPid(x, y, { relativeCoords, windowId, appName }) {
  const win = await resolveTarget({ windowId, appName });

  if (relativeCoords && !win) {
    throw targetError("INVALID_TARGET", "relativeCoords requires appName or windowId");
  }

  const pid = win?.pid || null;

  if (relativeCoords && win && win.bounds) {
    return {
      x: win.bounds.x + x,
      y: win.bounds.y + y,
      pid,
      windowInfo: win,
    };
  }

  return { x, y, pid, windowInfo: win };
}

const server = new Server(
  {
    name: "macos-computer-use",
    version: "2.3.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "screenshot",
        description:
          "Capture a screenshot of the macOS display or a specific target application window in the background (without stealing focus or capturing overlapping windows). Features virtual cursor overlay.",
        inputSchema: {
          type: "object",
          properties: {
            appName: {
              type: "string",
              description:
                "Optional application name (e.g. 'Google Chrome', 'Safari', 'Slack'). When provided, captures ONLY that target window in the background without bringing it to front or capturing overlapping windows.",
            },
            targetApp: {
              type: "string",
              description: "Alias for appName.",
            },
            windowId: {
              type: "number",
              description: "Optional specific window ID to capture directly.",
            },
            maxWidth: {
              type: "number",
              description: "Maximum pixel width to scale the image (default: 1440). Pass 0 for full raw resolution.",
            },
            format: {
              type: "string",
              enum: ["jpeg", "png"],
              description: "Image format: 'jpeg' (fast, compact) or 'png' (lossless). Default: 'jpeg'.",
            },
            cursor: {
              type: "object",
              properties: {
                x: { type: "number", description: "X coordinate of the cursor to highlight" },
                y: { type: "number", description: "Y coordinate of the cursor to highlight" },
              },
              description:
                "Optional cursor coordinates. For a window screenshot these are window-local logical points; for a display screenshot they are screen logical points.",
            },
          },
        },
      },
      {
        name: "find_text",
        description:
          "High-speed native Vision OCR: Finds text, buttons, labels, and UI elements on screen or inside a specific background window. Returns exact bounding boxes and click coordinates.",
        inputSchema: {
          type: "object",
          properties: {
            text: {
              type: "string",
              description: "Text or substring to search for (e.g. 'Search', 'Submit', 'Keyboard Shortcuts').",
            },
            appName: {
              type: "string",
              description: "Optional application name to search within.",
            },
            windowId: {
              type: "number",
              description: "Optional specific window ID to search within.",
            },
            matchMode: {
              type: "string",
              enum: ["exact", "word", "prefix", "substring"],
              description: "Text matching mode (default: 'substring').",
            },
          },
          required: ["text"],
        },
      },
      {
        name: "click_text",
        description:
          "Find text using native Apple Vision OCR, glide the live agent cursor to it, and invoke the matching Accessibility control. Targeted actions fail closed when no semantic control exists.",
        inputSchema: {
          type: "object",
          properties: {
            text: {
              type: "string",
              description: "The text/button label to click (e.g. 'Search', 'Keyboard Shortcuts…', 'quantum computing').",
            },
            appName: {
              type: "string",
              description: "Optional target application name.",
            },
            windowId: {
              type: "number",
              description: "Optional window ID.",
            },
            button: {
              type: "string",
              enum: ["left", "right", "middle"],
              description: "Mouse button to click (default: 'left')",
            },
            clickCount: {
              type: "number",
              description: "1 for single click, 2 for double click (default: 1)",
            },
            returnScreenshot: {
              type: "boolean",
              description: "Whether to return a new screenshot with virtual cursor highlight after clicking (default: false)",
            },
            matchMode: {
              type: "string",
              enum: ["exact", "word", "prefix", "substring"],
              description: "Text matching mode (default: 'word').",
            },
            occurrence: {
              type: "number",
              description:
                "One-based match occurrence to click. Required when more than one element matches.",
            },
          },
          required: ["text"],
        },
      },
      {
        name: "wait_for_text",
        description:
          "Reactively poll the screen or target window until specific text appears (e.g., live autocomplete dropdowns, modal sheets, success toasts).",
        inputSchema: {
          type: "object",
          properties: {
            text: {
              type: "string",
              description: "The text to wait for.",
            },
            appName: {
              type: "string",
              description: "Optional application name to monitor.",
            },
            windowId: {
              type: "number",
              description: "Optional window ID to monitor.",
            },
            timeoutSeconds: {
              type: "number",
              description: "Maximum seconds to wait (default: 5.0).",
            },
          },
          required: ["text"],
        },
      },
      {
        name: "list_windows",
        description:
          "List open application windows on macOS with their window IDs, process IDs (PID), application names, titles, and screen bounds.",
        inputSchema: {
          type: "object",
          properties: {
            appName: {
              type: "string",
              description: "Optional filter by application name (e.g. 'Google Chrome', 'Finder', 'Slack').",
            },
          },
        },
      },
      {
        name: "mouse_click",
        description:
          "Glide the live agent cursor to coordinates and click. With appName/windowId, invokes an Accessibility control without moving the hardware pointer and fails if no semantic control exists. Without a target, performs a global hardware click.",
        inputSchema: {
          type: "object",
          properties: {
            x: { type: "number", description: "X coordinate in logical points" },
            y: { type: "number", description: "Y coordinate in logical points" },
            appName: {
              type: "string",
              description: "Optional target application name for Accessibility delivery.",
            },
            windowId: {
              type: "number",
              description: "Optional exact window ID for Accessibility delivery.",
            },
            relativeCoords: {
              type: "boolean",
              description: "If true, treats (x, y) as relative to the target window's top-left corner (default: false).",
            },
            button: {
              type: "string",
              enum: ["left", "right", "middle"],
              description: "Mouse button to click (default: 'left')",
            },
            clickCount: {
              type: "number",
              description: "1 for single click, 2 for double click, 3 for triple click (default: 1)",
            },
            returnScreenshot: {
              type: "boolean",
              description: "Whether to return a new screenshot immediately with the virtual cursor highlighted (default: false)",
            },
          },
          required: ["x", "y"],
        },
      },
      {
        name: "type_text",
        description:
          "Type plain text. A target is resolved to an exact window before process delivery; unresolved or unsupported window targets fail closed.",
        inputSchema: {
          type: "object",
          properties: {
            text: { type: "string", description: "The text to type" },
            appName: {
              type: "string",
              description: "Optional target application name to receive background keystrokes.",
            },
            windowId: {
              type: "number",
              description: "Optional target window ID to receive background keystrokes.",
            },
          },
          required: ["text"],
        },
      },
      {
        name: "press_key",
        description:
          "Press a key or key combination (e.g. return, escape, space, tab, backspace, or shortcuts like Cmd+C, Cmd+Space).",
        inputSchema: {
          type: "object",
          properties: {
            key: {
              type: "string",
              description:
                "Key name: 'return', 'enter', 'tab', 'space', 'escape', 'backspace', 'delete', 'up', 'down', 'left', 'right', 'f1'-'f12', or single characters like 'a', 'c', 'v', 'w', 'q'.",
            },
            modifiers: {
              type: "array",
              items: {
                type: "string",
                enum: ["command", "cmd", "shift", "option", "alt", "control", "ctrl"],
              },
              description: "Optional modifier keys to hold (e.g. ['command'], ['command', 'shift'])",
            },
          },
          required: ["key"],
        },
      },
      {
        name: "scroll",
        description:
          "Glide the live agent cursor to a scroll target, then scroll vertically or horizontally. Targeted scrolling uses Accessibility scrollbars and fails closed; untargeted scrolling uses the global pointer location.",
        inputSchema: {
          type: "object",
          properties: {
            x: { type: "number", description: "X coordinate in logical points" },
            y: { type: "number", description: "Y coordinate in logical points" },
            appName: {
              type: "string",
              description: "Optional target application name if using relative coordinates.",
            },
            windowId: {
              type: "number",
              description: "Optional window ID if using relative coordinates.",
            },
            relativeCoords: {
              type: "boolean",
              description: "If true, treats (x, y) as relative to the target window's top-left corner (default: false).",
            },
            deltaY: {
              type: "number",
              description: "Vertical scroll amount. Negative values scroll down, positive scroll up.",
            },
            deltaX: {
              type: "number",
              description: "Horizontal scroll amount (default: 0).",
            },
          },
          required: ["x", "y", "deltaY"],
        },
      },
      {
        name: "launch_app",
        description: "Launch, focus, or bring a macOS application to the foreground.",
        inputSchema: {
          type: "object",
          properties: {
            appName: {
              type: "string",
              description: "Name of the application (e.g. 'Google Chrome', 'Safari', 'Finder', 'Slack', 'TextEdit', 'Calculator', 'WhatsApp').",
            },
          },
          required: ["appName"],
        },
      },
      {
        name: "get_active_app",
        description: "Get the frontmost active macOS application name and window title.",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "run_applescript",
        description: "Execute a custom AppleScript for advanced macOS UI scripting and accessibility inspection.",
        inputSchema: {
          type: "object",
          properties: {
            script: { type: "string", description: "The AppleScript code to run" },
          },
          required: ["script"],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  try {
    if (name === "screenshot") {
      const { base64, mimeType, display, windowInfo } = await captureScreenshot({
        maxWidth: args.maxWidth !== undefined ? args.maxWidth : 1440,
        format: args.format || "jpeg",
        cursor: args.cursor,
        windowId: args.windowId,
        appName: args.appName,
        targetApp: args.targetApp,
      });

      let descriptionText = `Screenshot captured. Display: ${display.width}x${display.height} (scale: ${display.scale}x).`;
      if (windowInfo) {
        descriptionText = `Target window captured in background: "${windowInfo.appName}" (ID: ${windowInfo.windowId}, Title: "${windowInfo.title}", Bounds: ${windowInfo.bounds.width}x${windowInfo.bounds.height} at (${windowInfo.bounds.x}, ${windowInfo.bounds.y})).`;
      }

      return {
        content: [
          {
            type: "image",
            data: base64,
            mimeType,
          },
          {
            type: "text",
            text: descriptionText,
          },
        ],
      };
    }

    if (name === "find_text") {
      const target = await resolveTarget(args);
      const helperArgs = ["find_text", args.text];
      helperArgs.push("nil", target ? String(target.windowId) : "nil", args.matchMode || "substring");

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());
      if (parsed.status === "error") {
        throw targetError(parsed.code || "OCR_FAILED", parsed.error || "text search failed");
      }
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(parsed, null, 2),
          },
        ],
      };
    }

    if (name === "click_text") {
      const target = await resolveTarget(args);
      const helperArgs = ["find_text", args.text];
      helperArgs.push("nil", target ? String(target.windowId) : "nil", args.matchMode || "word");

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());

      if (parsed.status === "error") {
        throw targetError(parsed.code || "OCR_FAILED", parsed.error || "text search failed");
      }

      if (!parsed.found || !parsed.bestMatch) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: `Could not find text "${args.text}" to click. Visible text candidates: ${JSON.stringify(parsed.availableText || [])}`,
            },
          ],
        };
      }

      const matches = parsed.allMatches || [];
      const occurrence = args.occurrence || null;
      if (occurrence !== null && (!Number.isInteger(occurrence) || occurrence < 1 || occurrence > matches.length)) {
        throw targetError(
          "INVALID_OCCURRENCE",
          `occurrence must be between 1 and ${matches.length}; received ${occurrence}`,
        );
      }
      const highestRank = parsed.bestMatch.matchRank || 0;
      const highestRankMatches = matches.filter((match) => (match.matchRank || 0) === highestRank);
      if (occurrence === null && highestRankMatches.length > 1) {
        throw targetError(
          "AMBIGUOUS_TEXT",
          `"${args.text}" matched ${highestRankMatches.length} equally ranked elements; pass occurrence to select one`,
        );
      }

      const selectedMatch = occurrence === null ? parsed.bestMatch : matches[occurrence - 1];
      const coords = selectedMatch.globalCoordinates || {
        x: selectedMatch.bounds.centerX,
        y: selectedMatch.bounds.centerY,
      };

      const button = args.button || "left";
      const count = args.clickCount || 1;
      const pid = target?.pid || parsed.pid || null;

      const clickArgs = target
        ? [
            "ax_click",
            String(coords.x),
            String(coords.y),
            button,
            String(count),
            String(target.pid),
            String(target.windowId),
          ]
        : ["click", String(coords.x), String(coords.y), button, String(count)];

      const { action, cursorOverlay } = await runPointAction(
        coords.x,
        coords.y,
        clickArgs,
        "click",
      );

      const contents = [
        {
          type: "text",
          text: JSON.stringify(
            {
              status: "delivered_unverified",
              match: selectedMatch,
              action,
              cursorOverlay,
              target: target || { scope: "global" },
            },
            null,
            2,
          ),
        },
      ];

      if (args.returnScreenshot) {
        const { base64, mimeType } = await captureScreenshot({
          cursor: target
            ? { x: coords.x - target.bounds.x, y: coords.y - target.bounds.y }
            : coords,
          appName: args.appName,
          windowId: args.windowId,
        });
        contents.unshift({ type: "image", data: base64, mimeType });
      }

      return { content: contents };
    }

    if (name === "wait_for_text") {
      const target = await resolveTarget(args);
      const helperArgs = ["wait_for_text", args.text];
      helperArgs.push("nil", target ? String(target.windowId) : "nil");

      helperArgs.push(String(args.timeoutSeconds || 5.0));

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());

      if (parsed.status === "error") {
        throw targetError(parsed.code || "WAIT_FAILED", parsed.error || "wait_for_text failed");
      }

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(parsed, null, 2),
          },
        ],
      };
    }

    if (name === "list_windows") {
      const windows = await listAllWindows(args.appName || null);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(windows, null, 2),
          },
        ],
      };
    }

    if (name === "mouse_click") {
      const { x, y, pid, windowInfo } = await resolveCoordinatesAndPid(args.x, args.y, args);
      const button = args.button || "left";
      const count = args.clickCount || 1;

      const clickArgs = windowInfo
        ? [
            "ax_click",
            String(x),
            String(y),
            button,
            String(count),
            String(pid),
            String(windowInfo.windowId),
          ]
        : ["click", String(x), String(y), button, String(count)];

      const { action, cursorOverlay } = await runPointAction(x, y, clickArgs, "click");

      const contents = [
        {
          type: "text",
          text: JSON.stringify(
            {
              status: "delivered_unverified",
              action,
              cursorOverlay,
              target: windowInfo || { scope: "global" },
            },
            null,
            2,
          ),
        },
      ];

      if (args.returnScreenshot) {
        const { base64, mimeType } = await captureScreenshot({
          cursor: windowInfo
            ? { x: x - windowInfo.bounds.x, y: y - windowInfo.bounds.y }
            : { x, y },
          appName: args.appName,
          windowId: args.windowId,
        });
        contents.unshift({ type: "image", data: base64, mimeType });
      }

      return { content: contents };
    }

    if (name === "type_text") {
      const target = await resolveTarget(args);
      const pid = target?.pid || null;

      const typeArgs = ["type_text", args.text];
      if (pid) typeArgs.push(String(pid), String(target.windowId));

      const { stdout } = await execFileAsync(NATIVE_HELPER, typeArgs);
      const action = JSON.parse(stdout.trim());
      if (action.status !== "ok") {
        throw targetError(action.code || "ACTION_FAILED", action.error || "text could not be delivered");
      }
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                status: "delivered_unverified",
                action,
                target: target || { scope: "active_app" },
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    if (name === "press_key") {
      const rawKey = args.key.toLowerCase();
      const mods = (args.modifiers || []).map((m) => {
        const lower = m.toLowerCase();
        if (lower === "cmd" || lower === "command") return "command down";
        if (lower === "shift") return "shift down";
        if (lower === "alt" || lower === "option") return "option down";
        if (lower === "ctrl" || lower === "control") return "control down";
        return `${lower} down`;
      });

      const usingClause = mods.length > 0 ? ` using {${mods.join(", ")}}` : "";

      let script = "";
      if (KEY_CODES[rawKey] !== undefined) {
        script = `tell application "System Events" to key code ${KEY_CODES[rawKey]}${usingClause}`;
      } else {
        const escaped = args.key.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
        script = `tell application "System Events" to keystroke "${escaped}"${usingClause}`;
      }

      const res = await runAppleScript(script);
      if (res.error) {
        throw new Error(res.error);
      }
      return {
        content: [
          {
            type: "text",
            text: `Pressed key: ${args.key}${mods.length ? ` with [${args.modifiers.join("+")}]` : ""}`,
          },
        ],
      };
    }

    if (name === "scroll") {
      const { x, y, pid, windowInfo } = await resolveCoordinatesAndPid(args.x, args.y, args);
      const dx = args.deltaX || 0;
      const scrollArgs = windowInfo
        ? [
            "ax_scroll",
            String(x),
            String(y),
            String(args.deltaY),
            String(dx),
            String(pid),
            String(windowInfo.windowId),
          ]
        : ["scroll", String(x), String(y), String(args.deltaY), String(dx)];

      const { action, cursorOverlay } = await runPointAction(x, y, scrollArgs, "scroll");
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
              status: "delivered_unverified",
              action,
              cursorOverlay,
              target: windowInfo || { scope: "global" },
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    if (name === "launch_app") {
      let target = args.appName;
      if (!target.startsWith("/") && !target.endsWith(".app")) {
        try {
          const { stdout } = await execFileAsync("/usr/bin/find", [
            "/Applications",
            path.join(os.homedir(), "Applications"),
            "-maxdepth",
            "2",
            "-name",
            `*${args.appName}*.app`,
          ]);
          const found = stdout.trim().split("\n").filter(Boolean)[0];
          if (found) {
            target = found;
          }
        } catch (_) {}
      }
      await execFileAsync("/usr/bin/open", [target.startsWith("/") ? target : "-a", target]);
      return {
        content: [{ type: "text", text: `Launched / focused application: "${target}"` }],
      };
    }

    if (name === "get_active_app") {
      const script = `
        tell application "System Events"
          set frontApp to first application process whose frontmost is true
          set frontAppName to name of frontApp
          set windowTitle to ""
          try
            tell frontApp
              if (count of windows) > 0 then
                set windowTitle to name of front window
              end if
            end tell
          end try
          return frontAppName & " | " & windowTitle
        end tell
      `;
      const { output, error } = await runAppleScript(script);
      if (error) {
        return {
          isError: true,
          content: [{ type: "text", text: JSON.stringify({ error, note: "Check macOS Accessibility permissions in System Settings > Privacy & Security > Accessibility." }) }],
        };
      }
      const [appName, windowTitle] = (output || "").split(" | ");
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ activeApp: appName || output, windowTitle: windowTitle || "" }, null, 2),
          },
        ],
      };
    }

    if (name === "run_applescript") {
      const res = await runAppleScript(args.script);
      if (res.error) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify(
                {
                  code: "APPLESCRIPT_FAILED",
                  error: res.error,
                  exitCode: res.exitCode,
                },
                null,
                2,
              ),
            },
          ],
        };
      }
      return {
        content: [{ type: "text", text: res.output || "Script executed." }],
      };
    }

    throw new Error(`Unknown tool: ${name}`);
  } catch (error) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              code: error.code || "TOOL_FAILED",
              tool: name,
              error: error.message,
            },
            null,
            2,
          ),
        },
      ],
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
