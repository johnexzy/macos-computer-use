import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { VisionService } from "../services/vision.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const waitForTextSchema = z.object({
  text: z.string(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  timeoutSeconds: z.number().optional(),
});

type WaitForTextInput = z.infer<typeof waitForTextSchema>;

export const waitForTextTool: ToolDefinition<WaitForTextInput> = {
  name: "wait_for_text",
  description:
    "Reactively polls the target window or screen using high-speed native OCR until the expected text appears (autocomplete dropdowns, toasts, dialogs, state changes). Much faster and more reliable than blind sleep().",
  annotations: READ_ONLY_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      text: {
        type: "string",
        description: "Text to wait for.",
      },
      appName: {
        type: "string",
        description: "Optional application name to search within.",
      },
      windowId: {
        type: "number",
        description: "Optional specific window ID to search within.",
      },
      timeoutSeconds: {
        type: "number",
        description: "Maximum seconds to wait (default: 5.0).",
      },
    },
    required: ["text"],
  },
  schema: waitForTextSchema,
  execute: async (args) => {
    const result = await VisionService.waitForText(args);
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
