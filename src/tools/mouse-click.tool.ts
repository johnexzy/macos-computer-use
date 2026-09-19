import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import { InputService } from "../services/input.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const mouseClickSchema = z.object({
  x: z.number(),
  y: z.number(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  relativeCoords: z.boolean().optional(),
  button: z.enum(["left", "right", "middle"]).optional(),
  clickCount: z.number().optional(),
  returnScreenshot: z.boolean().optional(),
});

type MouseClickInput = z.infer<typeof mouseClickSchema>;

export const mouseClickTool: ToolDefinition<MouseClickInput> = {
  name: "mouse_click",
  description:
    "Glide the live agent cursor to coordinates and click. With appName/windowId, invokes an Accessibility control without moving the hardware pointer and fails if no semantic control exists. Without a target, performs a global hardware click.",
  annotations: MUTATING_ANNOTATIONS,
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
  schema: mouseClickSchema,
  execute: async (args) => {
    return await InputService.mouseClick(args);
  },
};
