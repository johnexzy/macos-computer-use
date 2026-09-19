import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { WindowService } from "../services/window.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const listWindowsSchema = z.object({
  appName: z.string().optional(),
  includeAll: z
    .boolean()
    .optional()
    .describe(
      "Include background daemons, accessory status items, and off-screen windows (default: false, returns only user-facing GUI application windows)."
    ),
});

type ListWindowsInput = z.infer<typeof listWindowsSchema>;

export const listWindowsTool: ToolDefinition<ListWindowsInput> = {
  name: "list_windows",
  description:
    "List visible application windows on macOS, including window IDs, owner app names, process IDs (PID), window titles, and screen bounds in front-to-back Z-order. By default, returns only active user-facing applications (excludes system daemons and menu bar popovers).",
  annotations: READ_ONLY_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      appName: {
        type: "string",
        description: "Optional filter by application name (case-insensitive substring).",
      },
      includeAll: {
        type: "boolean",
        description:
          "Include background daemons, accessory status items, and off-screen windows (default: false).",
      },
    },
  },
  schema: listWindowsSchema,
  execute: async (args) => {
    const windows = await WindowService.listAllWindows(
      args.appName || null,
      args.includeAll || false
    );
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(windows, null, 2),
        },
      ],
    };
  },
};
