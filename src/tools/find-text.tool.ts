import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { VisionService } from "../services/vision.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const findTextSchema = z.object({
  text: z.string(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  matchMode: z.enum(["exact", "word", "prefix", "substring"]).optional(),
});

type FindTextInput = z.infer<typeof findTextSchema>;

export const findTextTool: ToolDefinition<FindTextInput> = {
  name: "find_text",
  description:
    "High-speed native Vision OCR: Finds text, buttons, labels, and UI elements on screen or inside a specific background window. Returns exact bounding boxes and click coordinates.",
  annotations: READ_ONLY_ANNOTATIONS,
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
  schema: findTextSchema,
  execute: async (args) => {
    const result = await VisionService.findText(args);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result, null, 2),
        },
      ],
    };
  },
};
