import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { NativeBridge } from "../core/native-bridge.js";
import { targetError } from "../core/errors.js";
import { WindowService } from "./window.service.js";
import { NATIVE_HELPER } from "../core/config.js";
import type { Point, WindowTarget, DisplayInfo } from "../types/index.js";

const execFileAsync = promisify(execFile);

export interface CaptureScreenshotOptions {
  maxWidth?: number;
  format?: "jpeg" | "png";
  cursor?: Point | null;
  windowId?: number | null;
  appName?: string | null;
  targetApp?: string | null;
  extractText?: boolean;
}

export interface ScreenshotResult {
  base64: string;
  mimeType: string;
  display: DisplayInfo;
  windowInfo: WindowTarget | null;
  extractedText?: string[];
}

export class ScreenCaptureService {
  static async captureScreenshot({
    maxWidth = 1440,
    format = "jpeg",
    cursor = null,
    windowId = null,
    appName = null,
    targetApp = null,
    extractText = false,
  }: CaptureScreenshotOptions = {}): Promise<ScreenshotResult> {
    const ext = format === "png" ? "png" : "jpg";
    const mimeType = format === "png" ? "image/png" : "image/jpeg";
    const tmpFile = path.join(os.tmpdir(), `mcp_screen_${Date.now()}.${ext}`);

    const windowInfo = await WindowService.resolveTarget({
      windowId: windowId ?? undefined,
      appName: appName ?? undefined,
      targetApp: targetApp ?? undefined,
    });

    const capabilities = await NativeBridge.getCapabilities();
    if (!capabilities.permissions?.screenRecording) {
      throw targetError(
        "SCREEN_RECORDING_PERMISSION_REQUIRED",
        "Screen Recording permission is required. Inspect get_capabilities before retrying."
      );
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

      const display = await NativeBridge.getDisplayInfo();

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
        } catch {}
      }

      // Extract OCR text if requested
      let extractedText: string[] | undefined = undefined;
      if (extractText) {
        try {
          const baseWidth = windowInfo?.bounds?.width || display.width;
          const ocrRes = await NativeBridge.call([
            "ocr",
            tmpFile,
            "nil",
            String(baseWidth),
            "false",
          ]);
          if (ocrRes && Array.isArray(ocrRes.elements)) {
            extractedText = ocrRes.elements.map((el: any) => el.text).filter(Boolean);
          }
        } catch {}
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
        extractedText,
      };
    } finally {
      await fs.unlink(tmpFile).catch(() => {});
    }
  }
}
