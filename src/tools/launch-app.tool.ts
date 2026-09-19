import { z } from "zod";
import { LAUNCH_ANNOTATIONS } from "../core/config.js";
import { executionMetadata, requireUnsafeMode } from "../core/errors.js";
import { WindowService } from "../services/window.service.js";
import { AccessibilityService } from "../services/accessibility.service.js";
import { NativeBridge } from "../core/native-bridge.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const launchAppSchema = z.object({
  appName: z.string(),
  activate: z.boolean().optional().default(false),
});

type LaunchAppInput = z.infer<typeof launchAppSchema>;

export const launchAppTool: ToolDefinition<LaunchAppInput> = {
  name: "launch_app",
  description:
    "Launch a macOS application in the background by default. Set activate=true only when foreground activation is intentional.",
  annotations: LAUNCH_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      appName: {
        type: "string",
        description:
          "Name of the application (e.g. 'Google Chrome', 'Safari', 'Finder', 'Slack', 'TextEdit', 'Calculator').",
      },
      activate: {
        type: "boolean",
        default: false,
        description: "Bring the app to the foreground. Defaults to false.",
      },
    },
    required: ["appName"],
  },
  schema: launchAppSchema,
  execute: async (args) => {
    const activate = args.activate === true;
    if (activate) requireUnsafeMode("launch_app");
    const before = activate ? null : await NativeBridge.getFrontmostApplication();
    const launched = await WindowService.launchApplication(args.appName, { activate });
    const foreground = activate
      ? null
      : await AccessibilityService.assertTargetStayedBackground(before, launched.target);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ...launched,
              foregroundPreserved: activate ? null : before.pid === foreground.pid,
              execution: executionMetadata({
                method: "/usr/bin/open",
                verification: "window_observed",
                foregroundPreserved: activate ? null : before.pid === foreground.pid,
                target: launched.target,
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
