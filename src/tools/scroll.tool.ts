import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import { InputService } from "../services/input.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const scrollSchema = z.object({
  x: z.number(),
  y: z.number(),
  deltaY: z.number(),
  deltaX: z.number().optional(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  relativeCoords: z.boolean().optional(),
});

type ScrollInput = z.infer<typeof scrollSchema>;

export const scrollTool: ToolDefinition<ScrollInput> = {
  name: "scroll",
  description:
    "Glide the live agent cursor to a scroll target, then scroll vertically or horizontally. Targeted scrolling uses Accessibility scrollbars and fails closed; untargeted scrolling uses the global pointer location.",
  annotations: MUTATING_ANNOTATIONS,
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
  schema: scrollSchema,
  execute: async (args) => {
    return await InputService.scroll(args);
  },
};
