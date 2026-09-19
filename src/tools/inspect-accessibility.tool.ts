import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { WindowService } from "../services/window.service.js";
import { AccessibilityService, normalizeSelector } from "../services/accessibility.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const selectorSchema = z.object({
  role: z.string().optional(),
  identifier: z.string().optional(),
  title: z.string().optional(),
  description: z.string().optional(),
  query: z.string().optional(),
  occurrence: z.number().int().positive().optional(),
});

const inspectAccessibilitySchema = z.object({
  appName: z.string().optional(),
  windowId: z.number().int().positive().optional(),
  selector: selectorSchema.optional(),
  roles: z.array(z.string()).optional(),
  maxDepth: z.number().int().min(1).max(50).optional().default(30),
  maxResults: z.number().int().min(1).max(500).optional().default(100),
  includeValues: z.boolean().optional().default(false),
  includeSettableAttributes: z.boolean().optional().default(false),
});

type InspectAccessibilityInput = z.infer<typeof inspectAccessibilitySchema>;

export const inspectAccessibilityTool: ToolDefinition<InspectAccessibilityInput> = {
  name: "inspect_accessibility",
  description:
    "Inspect semantic macOS Accessibility controls in a specific window without activating the application. Values are omitted unless includeValues is true.",
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
      maxDepth: { type: "integer", minimum: 1, maximum: 50, default: 30 },
      maxResults: { type: "integer", minimum: 1, maximum: 500, default: 100 },
      includeValues: {
        type: "boolean",
        default: false,
        description: "Include control values. Keep false unless the value is required.",
      },
      includeSettableAttributes: { type: "boolean", default: false },
    },
    anyOf: [{ required: ["appName"] }, { required: ["windowId"] }],
  },
  schema: inspectAccessibilitySchema,
  execute: async (args) => {
    const target = await WindowService.resolveRequiredTarget(args);
    const options: any = {
      roles: args.roles,
      maxDepth: args.maxDepth,
      maxResults: args.maxResults,
      includeValues: args.includeValues === true,
      includeSettableAttributes: args.includeSettableAttributes === true,
    };
    if (args.selector) {
      options.selector = normalizeSelector(args.selector);
    }
    const outcome = await AccessibilityService.runBackgroundStep(target, () =>
      AccessibilityService.inspectAccessibility(target, options)
    );
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(outcome.result, null, 2),
        },
      ],
    };
  },
};
