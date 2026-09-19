import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { WindowService } from "../services/window.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const listWindowsSchema = z.object({
  appName: z.string().optional(),
});

type ListWindowsInput = z.infer<typeof listWindowsSchema>;

export const listWindowsTool: ToolDefinition<ListWindowsInput> = {
  name: "list_windows",
  description:
    "List visible application windows on macOS, including window IDs, owner app names, process IDs (PID), window titles, and screen bounds in front-to-back Z-order.",
  annotations: READ_ONLY_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      appName: {
        type: "string",
        description: "Optional filter by application name (case-insensitive substring).",
      },
    },
  },
  schema: listWindowsSchema,
  execute: async (args) => {
    const windows = await WindowService.listAllWindows(args.appName || null);
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
