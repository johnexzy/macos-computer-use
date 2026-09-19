import { z } from "zod";
import { READ_ONLY_ANNOTATIONS } from "../core/config.js";
import { NativeBridge } from "../core/native-bridge.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const getActiveAppSchema = z.object({});

export const getActiveAppTool: ToolDefinition<Record<string, never>> = {
  name: "get_active_app",
  description: "Get the frontmost active macOS application name and window title.",
  annotations: READ_ONLY_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {},
  },
  schema: getActiveAppSchema,
  execute: async () => {
    const active = await NativeBridge.getFrontmostApplication();
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              activeApp: active.appName,
              pid: active.pid,
              bundleIdentifier: active.bundleIdentifier,
            },
            null,
            2
          ),
        },
      ],
    };
  },
};
