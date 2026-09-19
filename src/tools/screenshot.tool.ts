import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { ScreenCaptureService } from "../services/capture.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const screenshotSchema = z.object({
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  maxWidth: z.number().optional(),
  format: z.enum(["jpeg", "png"]).optional(),
  cursor: z
    .object({
      x: z.number(),
      y: z.number(),
    })
    .optional(),
});

type ScreenshotInput = z.infer<typeof screenshotSchema>;

export const screenshotTool: ToolDefinition<ScreenshotInput> = {
  name: "screenshot",
  description:
    "Capture a screenshot of the macOS display or a specific target application window in the background (without stealing focus or capturing overlapping windows). Features virtual cursor overlay.",
  annotations: READ_ONLY_ANNOTATIONS,
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
  schema: screenshotSchema,
  execute: async (args) => {
    const { base64, mimeType, display, windowInfo } = await ScreenCaptureService.captureScreenshot({
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
  },
};
