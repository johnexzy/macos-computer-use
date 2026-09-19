import { NativeBridge } from "../core/native-bridge.js";
import { targetError, executionMetadata, requireUnsafeMode } from "../core/errors.js";
import { WindowService } from "./window.service.js";
import { ScreenCaptureService } from "./capture.service.js";
import { runPointAction } from "./overlay.service.js";
import type { MatchMode, TextMatchItem, ToolResult } from "../types/index.js";

export interface FindTextOptions {
  text: string;
  appName?: string;
  targetApp?: string;
  windowId?: number;
  matchMode?: MatchMode;
}

export interface ClickTextOptions extends FindTextOptions {
  occurrence?: number;
  button?: "left" | "right" | "middle";
  clickCount?: number;
  returnScreenshot?: boolean;
}

export interface WaitForTextOptions {
  text: string;
  appName?: string;
  targetApp?: string;
  windowId?: number;
  timeoutSeconds?: number;
}

export class VisionService {
  static async findText(args: FindTextOptions) {
    const target = await WindowService.resolveTarget(args);
    const helperArgs = [
      "find_text",
      args.text,
      "nil",
      target ? String(target.windowId) : "nil",
      args.matchMode || "substring",
    ];

    const parsed = await NativeBridge.call(helperArgs);
    if (parsed.status === "error") {
      throw targetError(parsed.code || "OCR_FAILED", parsed.error || "text search failed");
    }
    return parsed;
  }

  static async waitForText(args: WaitForTextOptions) {
    const target = await WindowService.resolveTarget(args);
    const helperArgs = [
      "wait_for_text",
      args.text,
      "nil",
      target ? String(target.windowId) : "nil",
      String(args.timeoutSeconds || 5.0),
    ];

    const parsed = await NativeBridge.call(helperArgs);
    if (parsed.status === "error") {
      throw targetError(parsed.code || "WAIT_FAILED", parsed.error || "wait_for_text failed");
    }
    return parsed;
  }

  static async clickText(args: ClickTextOptions): Promise<ToolResult> {
    const target = await WindowService.resolveTarget(args);
    if (!target) {
      requireUnsafeMode("click_text");
      await NativeBridge.requireInputPostingAccess("click_text");
    }

    const helperArgs = [
      "find_text",
      args.text,
      "nil",
      target ? String(target.windowId) : "nil",
      args.matchMode || "word",
    ];

    const parsed = await NativeBridge.call(helperArgs);
    if (parsed.status === "error") {
      throw targetError(parsed.code || "OCR_FAILED", parsed.error || "text search failed");
    }

    if (!parsed.found || !parsed.bestMatch) {
      throw targetError(
        "TEXT_NOT_FOUND",
        `Could not find text "${args.text}" to click. Visible text candidates: ${JSON.stringify(
          parsed.availableText || []
        )}`
      );
    }

    const matches: TextMatchItem[] = parsed.allMatches || [];
    const occurrence = args.occurrence || null;
    if (
      occurrence !== null &&
      (!Number.isInteger(occurrence) || occurrence < 1 || occurrence > matches.length)
    ) {
      throw targetError(
        "INVALID_OCCURRENCE",
        `occurrence must be between 1 and ${matches.length}; received ${occurrence}`
      );
    }

    const highestRank = parsed.bestMatch.matchRank || 0;
    const highestRankMatches = matches.filter((m) => (m.matchRank || 0) === highestRank);
    if (occurrence === null && highestRankMatches.length > 1) {
      throw targetError(
        "AMBIGUOUS_TEXT",
        `"${args.text}" matched ${highestRankMatches.length} equally ranked elements; pass occurrence to select one`
      );
    }

    const selectedMatch = occurrence === null ? parsed.bestMatch : matches[occurrence - 1];
    const coords = selectedMatch.globalCoordinates || {
      x: selectedMatch.bounds.centerX,
      y: selectedMatch.bounds.centerY,
    };

    const button = args.button || "left";
    const count = args.clickCount || 1;

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
      "click"
    );

    const contents: any[] = [
      {
        type: "text",
        text: JSON.stringify(
          {
            status: "delivered_unverified",
            match: selectedMatch,
            action,
            cursorOverlay,
            target: target || { scope: "global" },
            execution: executionMetadata({
              method: action.action,
              foregroundPreserved: action.foregroundPreserved ?? null,
              target: target || { scope: "global" },
            }),
          },
          null,
          2
        ),
      },
    ];

    if (args.returnScreenshot) {
      const { base64, mimeType } = await ScreenCaptureService.captureScreenshot({
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
}
