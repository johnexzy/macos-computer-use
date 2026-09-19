import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import { VisionService } from "../services/vision.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const clickTextSchema = z.object({
  text: z.string(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  matchMode: z.enum(["exact", "word", "prefix", "substring"]).optional(),
  occurrence: z.number().int().positive().optional(),
  button: z.enum(["left", "right", "middle"]).optional(),
  clickCount: z.number().int().positive().optional(),
  returnScreenshot: z.boolean().optional(),
});

type ClickTextInput = z.infer<typeof clickTextSchema>;

export const clickTextTool: ToolDefinition<ClickTextInput> = {
  name: "click_text",
  description:
    "High-speed Vision OCR Click: Finds text on screen or in a background window and clicks it. In safe mode, background window clicks use non-intrusive Accessibility delivery. Untargeted global clicks require MACOS_COMPUTER_USE_UNSAFE=1.",
  annotations: MUTATING_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      text: {
        type: "string",
        description: "Text or label to click (e.g. 'Submit', 'Cancel', 'Save').",
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
        description: "Text matching mode (default: 'word').",
      },
      occurrence: {
        type: "integer",
        minimum: 1,
        description:
          "One-based index when multiple elements match the text. If omitted and multiple matches share the highest rank, the action fails closed with an error.",
      },
      button: {
        type: "string",
        enum: ["left", "right", "middle"],
        description: "Mouse button to click (default: 'left'). Background clicks support only 'left'.",
      },
      clickCount: {
        type: "number",
        description: "Number of clicks: 1 for single, 2 for double, 3 for triple (default: 1).",
      },
      returnScreenshot: {
        type: "boolean",
        description: "If true, captures and returns a post-action screenshot with cursor highlight.",
      },
    },
    required: ["text"],
  },
  schema: clickTextSchema,
  execute: async (args) => {
    return await VisionService.clickText(args);
  },
};
