import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { NativeBridge } from "../core/native-bridge.js";
import {
  targetError,
  requireUnsafeMode,
  executionMetadata,
} from "../core/errors.js";
import { WindowService } from "./window.service.js";
import { AccessibilityService } from "./accessibility.service.js";
import { ScreenCaptureService } from "./capture.service.js";
import { runPointAction } from "./overlay.service.js";
import type { ToolResult, WindowTarget } from "../types/index.js";

const execFileAsync = promisify(execFile);

export const KEY_CODES: Record<string, number> = {
  a: 0,
  s: 1,
  d: 2,
  f: 3,
  h: 4,
  g: 5,
  z: 6,
  x: 7,
  c: 8,
  v: 9,
  b: 11,
  q: 12,
  w: 13,
  e: 14,
  r: 15,
  y: 16,
  t: 17,
  "1": 18,
  "2": 19,
  "3": 20,
  "4": 21,
  "6": 22,
  "5": 23,
  "=": 24,
  "9": 25,
  "7": 26,
  "-": 27,
  "8": 28,
  "0": 29,
  "]": 30,
  o: 31,
  u: 32,
  "[": 33,
  i: 34,
  p: 35,
  l: 37,
  j: 38,
  "'": 39,
  k: 40,
  ";": 41,
  "\\": 42,
  ",": 43,
  "/": 44,
  n: 45,
  m: 46,
  ".": 47,
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

export class InputService {
  static async resolveCoordinatesAndPid(
    x: number,
    y: number,
    args: { relativeCoords?: boolean; windowId?: number; appName?: string; targetApp?: string }
  ): Promise<{
    x: number;
    y: number;
    pid: number | null;
    windowInfo: WindowTarget | null;
  }> {
    const win = await WindowService.resolveTarget(args);

    if (args.relativeCoords && !win) {
      throw targetError("INVALID_TARGET", "relativeCoords requires appName or windowId");
    }

    const pid = win?.pid || null;

    if (args.relativeCoords && win && win.bounds) {
      return {
        x: win.bounds.x + x,
        y: win.bounds.y + y,
        pid,
        windowInfo: win,
      };
    }

    return { x, y, pid, windowInfo: win };
  }

  static async mouseClick(args: {
    x: number;
    y: number;
    appName?: string;
    targetApp?: string;
    windowId?: number;
    relativeCoords?: boolean;
    button?: "left" | "right" | "middle";
    clickCount?: number;
    returnScreenshot?: boolean;
  }): Promise<ToolResult> {
    const { x, y, pid, windowInfo } = await this.resolveCoordinatesAndPid(args.x, args.y, args);
    if (!windowInfo) {
      requireUnsafeMode("mouse_click");
      await NativeBridge.requireInputPostingAccess("mouse_click");
    }
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

    const contents: any[] = [
      {
        type: "text",
        text: JSON.stringify(
          {
            status: "delivered_unverified",
            action,
            cursorOverlay,
            target: windowInfo || { scope: "global" },
            execution: executionMetadata({
              method: action.action,
              foregroundPreserved: action.foregroundPreserved ?? null,
              target: windowInfo || { scope: "global" },
            }),
          },
          null,
          2
        ),
      },
    ];

    if (args.returnScreenshot) {
      const { base64, mimeType } = await ScreenCaptureService.captureScreenshot({
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

  static async typeText(args: {
    text: string;
    appName?: string;
    targetApp?: string;
    windowId?: number;
    selector?: Record<string, any>;
    executionMode?: "background_required" | "foreground_allowed";
  }): Promise<ToolResult> {
    const targetRequested = args.appName || args.windowId;
    const executionMode =
      args.executionMode || (targetRequested ? "background_required" : "foreground_allowed");

    if (executionMode === "background_required") {
      const target = await WindowService.resolveRequiredTarget(args);
      const outcome = await AccessibilityService.runBackgroundStep(target, () =>
        AccessibilityService.typeTextIntoAccessibilityElement(target, args.selector || {}, args.text)
      );
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                status: "delivered_verified",
                ...outcome,
                execution: executionMetadata({
                  method: outcome.result.action,
                  verification: "value_readback",
                  foregroundPreserved: outcome.foreground.preserved,
                  target,
                }),
              },
              null,
              2
            ),
          },
        ],
      };
    }

    requireUnsafeMode("type_text");
    await NativeBridge.requireInputPostingAccess("type_text");
    const target = await WindowService.resolveTarget(args);
    const pid = target?.pid || null;

    const typeArgs = ["type_text", args.text];
    if (pid && target) typeArgs.push(String(pid), String(target.windowId));

    const action = await NativeBridge.call(typeArgs);
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
              execution: executionMetadata({
                method: action.action,
                target: target || { scope: "active_app" },
              }),
            },
            null,
            2
          ),
        },
      ],
    };
  }

  static async pressKey(args: {
    key: string;
    appName?: string;
    targetApp?: string;
    windowId?: number;
    selector?: Record<string, any>;
    executionMode?: "background_required" | "foreground_allowed";
    modifiers?: string[];
  }): Promise<ToolResult> {
    const targetRequested = args.appName || args.windowId;
    const executionMode =
      args.executionMode || (targetRequested ? "background_required" : "foreground_allowed");

    if (executionMode === "background_required") {
      const target = await WindowService.resolveRequiredTarget(args);
      if ((args.modifiers || []).length > 0) {
        throw targetError(
          "UNSUPPORTED_BACKGROUND_MODIFIERS",
          "background-required key presses do not support modifiers"
        );
      }
      const outcome = await AccessibilityService.runBackgroundStep(target, () =>
        AccessibilityService.postAccessibilityKey(target, args.selector || {}, args.key)
      );
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                status: "delivered",
                ...outcome,
                execution: executionMetadata({
                  method: outcome.result.action,
                  foregroundPreserved: outcome.foreground.preserved,
                  target,
                }),
              },
              null,
              2
            ),
          },
        ],
      };
    }

    requireUnsafeMode("press_key");
    await NativeBridge.requireInputPostingAccess("press_key");
    const rawKey = args.key.toLowerCase();
    const modifiers = args.modifiers || [];
    const keyCode = KEY_CODES[rawKey];

    if (keyCode === undefined) {
      if (modifiers.length === 0 && [...args.key].length === 1) {
        const action = await NativeBridge.call(["type_text", args.key]);
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(
                {
                  ...action,
                  execution: executionMetadata({
                    method: action.action,
                    target: { scope: "active_app" },
                  }),
                },
                null,
                2
              ),
            },
          ],
        };
      }
      throw targetError("UNSUPPORTED_KEY", `native key delivery does not support "${args.key}"`);
    }

    const action = await NativeBridge.call([
      "press_key",
      String(keyCode),
      JSON.stringify(modifiers),
    ]);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ...action,
              execution: executionMetadata({
                method: action.action,
                target: { scope: "active_app" },
              }),
            },
            null,
            2
          ),
        },
      ],
    };
  }

  static async scroll(args: {
    x: number;
    y: number;
    deltaY: number;
    deltaX?: number;
    appName?: string;
    targetApp?: string;
    windowId?: number;
    relativeCoords?: boolean;
  }): Promise<ToolResult> {
    const { x, y, pid, windowInfo } = await this.resolveCoordinatesAndPid(args.x, args.y, args);
    if (!windowInfo) {
      requireUnsafeMode("scroll");
      await NativeBridge.requireInputPostingAccess("scroll");
    }

    const scrollArgs = windowInfo
      ? [
          "ax_scroll",
          String(x),
          String(y),
          String(args.deltaY),
          String(args.deltaX || 0),
          String(pid),
          String(windowInfo.windowId),
        ]
      : [
          "scroll",
          String(x),
          String(y),
          String(args.deltaY),
          String(args.deltaX || 0),
        ];

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
              execution: executionMetadata({
                method: action.action,
                foregroundPreserved: action.foregroundPreserved ?? null,
                target: windowInfo || { scope: "global" },
              }),
            },
            null,
            2
          ),
        },
      ],
    };
  }

  static async runAppleScript(script: string) {
    try {
      const { stdout, stderr } = await execFileAsync("/usr/bin/osascript", ["-e", script]);
      return { output: stdout.trim(), error: stderr ? stderr.trim() : null, exitCode: 0 };
    } catch (err: any) {
      return {
        output: err.stdout?.trim() || null,
        error: err.stderr?.trim() || err.message,
        exitCode: typeof err.code === "number" ? err.code : 1,
      };
    }
  }
}
