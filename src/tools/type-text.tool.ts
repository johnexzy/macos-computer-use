import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import { InputService } from "../services/input.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const selectorSchema = z.object({
  role: z.string().optional(),
  identifier: z.string().optional(),
  title: z.string().optional(),
  description: z.string().optional(),
  query: z.string().optional(),
  occurrence: z.number().int().positive().optional(),
});

const typeTextSchema = z.object({
  text: z.string(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  selector: selectorSchema.optional(),
  executionMode: z.enum(["background_required", "foreground_allowed"]).optional(),
});

type TypeTextInput = z.infer<typeof typeTextSchema>;

export const typeTextTool: ToolDefinition<TypeTextInput> = {
  name: "type_text",
  description:
    "Type plain text. Targeted calls default to verified background delivery and require a semantic selector; untargeted calls operate on the active app.",
  annotations: MUTATING_ANNOTATIONS,
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
      selector: {
        type: "object",
        description: "Semantic Accessibility selector. Combine fields to identify one control precisely.",
        properties: {
          role: { type: "string", description: "Exact AX role, such as AXButton or AXTextArea." },
          identifier: { type: "string", description: "Exact Accessibility identifier." },
          title: { type: "string", description: "Exact Accessibility title." },
          description: { type: "string", description: "Exact Accessibility description." },
          query: { type: "string", description: "Substring matched across semantic text attributes." },
          occurrence: {
            type: "integer",
            minimum: 1,
            description: "One-based occurrence when the selector intentionally matches multiple controls.",
          },
        },
        additionalProperties: false,
      },
      executionMode: {
        type: "string",
        enum: ["background_required", "foreground_allowed"],
        description: "Targeted calls default to background_required; untargeted calls use foreground_allowed.",
      },
    },
    required: ["text"],
  },
  schema: typeTextSchema,
  execute: async (args) => {
    return await InputService.typeText(args);
  },
};
