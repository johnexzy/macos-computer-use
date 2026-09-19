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

const performAccessibilityActionSchema = z.object({
  appName: z.string().optional(),
  windowId: z.number().int().positive().optional(),
  selector: selectorSchema,
  action: z.enum(["press", "focus", "confirm", "cancel", "increment", "decrement", "show_menu"]),
});

type PerformAccessibilityActionInput = z.infer<typeof performAccessibilityActionSchema>;

export const performAccessibilityActionTool: ToolDefinition<PerformAccessibilityActionInput> = {
  name: "perform_accessibility_action",
  description:
    "Perform a semantic Accessibility action in a background window and verify that the target app did not become frontmost.",
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
      action: {
        type: "string",
        enum: ["press", "focus", "confirm", "cancel", "increment", "decrement", "show_menu"],
      },
    },
    required: ["selector", "action"],
    anyOf: [{ required: ["appName"] }, { required: ["windowId"] }],
  },
  schema: performAccessibilityActionSchema,
  execute: async (args) => {
    const target = await WindowService.resolveRequiredTarget(args);
    const outcome = await AccessibilityService.runBackgroundStep(target, () =>
      AccessibilityService.performAccessibilityAction(target, args.selector, args.action)
    );
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ...outcome,
              execution: executionMetadata({
                method: (outcome.result as any).action,
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
