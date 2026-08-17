import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const NATIVE_HELPER = path.join(__dirname, "native_helper");

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

  let windowInfo = null;
  const searchApp = appName || targetApp;

  if (searchApp) {
    windowInfo = await findWindowByApp(searchApp);
  } else if (windowId) {
    windowInfo = await getWindowBounds(windowId);
  }

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
    return { output: stdout.trim(), error: stderr ? stderr.trim() : null };
  } catch (err) {
    return { output: null, error: err.message };
  }
}

async function resolveCoordinatesAndPid(x, y, { relativeCoords, windowId, appName }) {
  let win = null;
  if (appName) {
    win = await findWindowByApp(appName);
  } else if (windowId) {
    win = await getWindowBounds(windowId);
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
    version: "2.1.0",
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
              description: "Optional coordinates to draw a custom glowing virtual cursor indicator on the screenshot.",
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
          },
          required: ["text"],
        },
      },
      {
        name: "click_text",
        description:
          "Find any text/button by name using native Apple Vision OCR and smoothly click its exact center. Non-intrusive: targets the process directly without hijacking your hardware mouse.",
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
          "Click at coordinates (x, y). Automatically routes events directly to the target application PID if appName/windowId is provided, avoiding hardware mouse hijacking.",
        inputSchema: {
          type: "object",
          properties: {
            x: { type: "number", description: "X coordinate in logical points" },
            y: { type: "number", description: "Y coordinate in logical points" },
            appName: {
              type: "string",
              description: "Optional target application name for direct background process delivery.",
            },
            windowId: {
              type: "number",
              description: "Optional window ID for direct background process delivery.",
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
        description: "Type plain text into the target application without disturbing your active keyboard focus if appName/windowId is provided.",
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
        description: "Scroll mouse wheel vertically and horizontally.",
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
      const helperArgs = ["find_text", args.text];
      if (args.appName) helperArgs.push(args.appName);
      else if (args.windowId) helperArgs.push("nil", String(args.windowId));

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());
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
      const helperArgs = ["find_text", args.text];
      if (args.appName) helperArgs.push(args.appName);
      else if (args.windowId) helperArgs.push("nil", String(args.windowId));

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());

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

      const coords = parsed.bestMatch.globalCoordinates || {
        x: parsed.bestMatch.bounds.centerX,
        y: parsed.bestMatch.bounds.centerY,
      };

      const button = args.button || "left";
      const count = args.clickCount || 1;
      const pid = parsed.pid || null;

      const clickArgs = [
        "click",
        String(coords.x),
        String(coords.y),
        button,
        String(count),
      ];
      if (pid) clickArgs.push(String(pid));

      await execFileAsync(NATIVE_HELPER, clickArgs);

      const contents = [
        {
          type: "text",
          text: `Found and clicked text "${parsed.bestMatch.text}" at screen coordinates (${coords.x.toFixed(1)}, ${coords.y.toFixed(1)}) with confidence ${(parsed.bestMatch.confidence * 100).toFixed(0)}% (non-intrusive PID: ${pid || "global"})`,
        },
      ];

      if (args.returnScreenshot) {
        const { base64, mimeType } = await captureScreenshot({
          cursor: coords,
          appName: args.appName,
          windowId: args.windowId,
        });
        contents.unshift({ type: "image", data: base64, mimeType });
      }

      return { content: contents };
    }

    if (name === "wait_for_text") {
      const helperArgs = ["wait_for_text", args.text];
      if (args.appName) helperArgs.push(args.appName);
      else helperArgs.push("nil");

      if (args.windowId) helperArgs.push(String(args.windowId));
      else helperArgs.push("nil");

      helperArgs.push(String(args.timeoutSeconds || 5.0));

      const { stdout } = await execFileAsync(NATIVE_HELPER, helperArgs);
      const parsed = JSON.parse(stdout.trim());

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
      const { x, y, pid } = await resolveCoordinatesAndPid(args.x, args.y, args);
      const button = args.button || "left";
      const count = args.clickCount || 1;

      const clickArgs = [
        "click",
        String(x),
        String(y),
        button,
        String(count),
      ];
      if (pid) clickArgs.push(String(pid));

      await execFileAsync(NATIVE_HELPER, clickArgs);

      const contents = [
        {
          type: "text",
          text: `Clicked at (${x}, ${y}) [${button}, count: ${count}] (targeted PID: ${pid || "global"})`,
        },
      ];

      if (args.returnScreenshot) {
        const { base64, mimeType } = await captureScreenshot({
          cursor: { x, y },
          appName: args.appName,
          windowId: args.windowId,
        });
        contents.unshift({ type: "image", data: base64, mimeType });
      }

      return { content: contents };
    }

    if (name === "type_text") {
      let pid = null;
      if (args.appName) {
        const win = await findWindowByApp(args.appName);
        pid = win?.pid || null;
      } else if (args.windowId) {
        const win = await getWindowBounds(args.windowId);
        pid = win?.pid || null;
      }

      const typeArgs = ["type_text", args.text];
      if (pid) typeArgs.push(String(pid));

      await execFileAsync(NATIVE_HELPER, typeArgs);
      return {
        content: [{ type: "text", text: `Typed: "${args.text}" (targeted PID: ${pid || "active app"})` }],
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
      const { x, y, pid } = await resolveCoordinatesAndPid(args.x, args.y, args);
      const dx = args.deltaX || 0;
      const scrollArgs = [
        "scroll",
        String(x),
        String(y),
        String(args.deltaY),
        String(dx),
      ];
      if (pid) scrollArgs.push(String(pid));

      await execFileAsync(NATIVE_HELPER, scrollArgs);
      return {
        content: [
          {
            type: "text",
            text: `Scrolled at (${x}, ${y}) deltaY: ${args.deltaY}, deltaX: ${dx} (PID: ${pid || "global"})`,
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
      return {
        content: [{ type: "text", text: res.output || res.error || "Script executed." }],
      };
    }

    throw new Error(`Unknown tool: ${name}`);
  } catch (error) {
    return {
      isError: true,
      content: [{ type: "text", text: `Error executing ${name}: ${error.message}` }],
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
