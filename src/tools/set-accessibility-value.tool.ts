import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import { executionMetadata } from "../core/errors.js";
import { WindowService } from "../services/window.service.js";
import { AccessibilityService } from "../services/accessibility.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const selectorSchema = z.object({
  role: z.string().optional(),
  identifier: z.string().optional(),
  title: z.string().optional(),
  description: z.string().optional(),
  query: z.string().optional(),
  occurrence: z.number().int().positive().optional(),
});

const setAccessibilityValueSchema = z.object({
  appName: z.string().optional(),
  windowId: z.number().int().positive().optional(),
  selector: selectorSchema,
  value: z.string(),
});

type SetAccessibilityValueInput = z.infer<typeof setAccessibilityValueSchema>;

export const setAccessibilityValueTool: ToolDefinition<SetAccessibilityValueInput> = {
  name: "set_accessibility_value",
  description:
    "Set the value of a semantic Accessibility control in a background window and verify that the target app did not become frontmost.",
  annotations: MUTATING_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
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
      value: { type: "string", description: "Replacement value." },
    },
    required: ["selector", "value"],
    anyOf: [{ required: ["appName"] }, { required: ["windowId"] }],
  },
  schema: setAccessibilityValueSchema,
  execute: async (args) => {
    const target = await WindowService.resolveRequiredTarget(args);
    const outcome = await AccessibilityService.runBackgroundStep(target, () =>
      AccessibilityService.setAccessibilityValue(target, args.selector, args.value)
    );
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ...outcome,
              execution: executionMetadata({
                method: "AXSetValue",
                verification: "value_readback",
                foregroundPreserved: outcome.foreground.preserved,
                target,
              }),
            },
            null,
            2
          ),
        },
      ],
    };
  },
};
