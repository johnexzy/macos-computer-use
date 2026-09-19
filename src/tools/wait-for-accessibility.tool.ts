import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
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

const waitForAccessibilitySchema = z.object({
  appName: z.string().optional(),
  windowId: z.number().int().positive().optional(),
  selector: selectorSchema,
  roles: z.array(z.string()).optional(),
  minCount: z.number().int().min(1).max(500).optional().default(1),
  timeoutMs: z.number().int().min(100).max(30000).optional().default(5000),
  maxDepth: z.number().int().min(1).max(50).optional().default(30),
  maxResults: z.number().int().min(1).max(500).optional().default(100),
  includeValues: z.boolean().optional().default(false),
  includeSettableAttributes: z.boolean().optional().default(false),
});

type WaitForAccessibilityInput = z.infer<typeof waitForAccessibilitySchema>;

export const waitForAccessibilityTool: ToolDefinition<WaitForAccessibilityInput> = {
  name: "wait_for_accessibility",
  description:
    "Wait until semantic Accessibility controls appear in a specific background window without requiring Screen Recording.",
  annotations: READ_ONLY_ANNOTATIONS,
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
      roles: {
        type: "array",
        items: { type: "string" },
        description: "Optional exact AX roles to include.",
      },
      minCount: {
        type: "integer",
        minimum: 1,
        maximum: 500,
        default: 1,
        description: "Minimum matching element count required to finish waiting.",
      },
      timeoutMs: {
        type: "integer",
        minimum: 100,
        maximum: 30000,
        default: 5000,
      },
      maxDepth: { type: "integer", minimum: 1, maximum: 50, default: 30 },
      maxResults: { type: "integer", minimum: 1, maximum: 500, default: 100 },
      includeValues: {
        type: "boolean",
        default: false,
      },
      includeSettableAttributes: { type: "boolean", default: false },
    },
    required: ["selector"],
    anyOf: [{ required: ["appName"] }, { required: ["windowId"] }],
  },
  schema: waitForAccessibilitySchema,
  execute: async (args) => {
    const target = await WindowService.resolveRequiredTarget(args);
    const outcome = await AccessibilityService.runBackgroundStep(target, () =>
      AccessibilityService.waitForAccessibility(target, args.selector, {
        minCount: args.minCount,
        timeoutMs: args.timeoutMs,
        roles: args.roles,
        maxDepth: args.maxDepth,
      })
    );
    return {
      content: [{ type: "text", text: JSON.stringify(outcome.result, null, 2) }],
    };
  },
};
