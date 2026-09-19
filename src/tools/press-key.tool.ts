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

const pressKeySchema = z.object({
  key: z.string(),
  modifiers: z
    .array(z.enum(["command", "cmd", "shift", "option", "alt", "control", "ctrl"]))
    .optional(),
  appName: z.string().optional(),
  targetApp: z.string().optional(),
  windowId: z.number().optional(),
  selector: selectorSchema.optional(),
  executionMode: z.enum(["background_required", "foreground_allowed"]).optional(),
});

type PressKeyInput = z.infer<typeof pressKeySchema>;

export const pressKeyTool: ToolDefinition<PressKeyInput> = {
  name: "press_key",
  description:
    "Press a key or key combination. background_required targets a semantic editable control without activating its app; foreground_allowed operates on the active app.",
  annotations: MUTATING_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      key: {
        type: "string",
        description:
          "Key name: 'return', 'enter', 'tab', 'space', 'escape', 'backspace', 'delete', 'up', 'down', 'left', 'right', 'f1'-'f12', or single characters like 'a', 'c', 'v', 'w', 'q'.",
      },
      modifiers: {
        type: "array",
        items: {
          type: "string",
          enum: ["command", "cmd", "shift", "option", "alt", "control", "ctrl"],
        },
        description: "Optional modifier keys to hold (e.g. ['command'], ['command', 'shift'])",
      },
      appName: { type: "string", description: "Application name whose window should remain backgrounded." },
      windowId: { type: "integer", minimum: 1, description: "Exact target window ID." },
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
    required: ["key"],
  },
  schema: pressKeySchema,
  execute: async (args) => {
    return await InputService.pressKey(args);
  },
};
