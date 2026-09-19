import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { LAUNCH_ANNOTATIONS } from "../core/config.js";
import { executionMetadata, targetError } from "../core/errors.js";
import { WindowService } from "../services/window.service.js";
import { NativeBridge } from "../core/native-bridge.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const execFileAsync = promisify(execFile);

const openUrlSchema = z.object({
  url: z.string().describe("The URL to open (must begin with http://, https://, or file://)."),
  appName: z
    .string()
    .optional()
    .describe(
      "Browser application to use (e.g. 'Google Chrome', 'Safari', 'Arc'). Defaults to system default browser."
    ),
  background: z
    .boolean()
    .optional()
    .default(true)
    .describe("Open in background without stealing foreground focus. Defaults to true."),
  newWindow: z
    .boolean()
    .optional()
    .default(false)
    .describe("Open in a new window instead of a new tab if supported. Defaults to false."),
});

type OpenUrlInput = z.infer<typeof openUrlSchema>;

export const openUrlTool: ToolDefinition<OpenUrlInput> = {
  name: "open_url",
  description:
    "Open a web URL in a browser on macOS. By default, opens in the background without stealing user focus or activating the window.",
  annotations: LAUNCH_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description: "The URL to open (e.g. 'https://www.google.com/search?q=...').",
      },
      appName: {
        type: "string",
        description:
          "Optional browser application name (e.g. 'Google Chrome', 'Safari'). If omitted, uses the default system browser.",
      },
      background: {
        type: "boolean",
        default: true,
        description: "Open in background without bringing browser to front. Defaults to true.",
      },
      newWindow: {
        type: "boolean",
        default: false,
        description: "Open in a new window instead of a new tab. Defaults to false.",
      },
    },
    required: ["url"],
  },
  schema: openUrlSchema,
  execute: async (args) => {
    const rawUrl = args.url.trim();
    if (!/^https?:\/\//i.test(rawUrl) && !/^file:\/\//i.test(rawUrl)) {
      throw targetError(
        "INVALID_URL",
        `Only http://, https://, and file:// URLs are permitted. Received "${rawUrl}"`
      );
    }

    const isBackground = args.background !== false;
    const openArgs: string[] = [];

    if (isBackground) {
      openArgs.push("-g");
    }
    if (args.newWindow) {
      openArgs.push("-n");
    }
    if (args.appName) {
      openArgs.push("-a", args.appName);
    }
    openArgs.push(rawUrl);

    const before = isBackground ? await NativeBridge.getFrontmostApplication() : null;

    try {
      await execFileAsync("/usr/bin/open", openArgs);
    } catch (error: any) {
      throw targetError("OPEN_URL_FAILED", `Failed to open URL "${rawUrl}": ${error.message}`);
    }

    // Brief delay to allow the browser process to create/update window
    await new Promise((resolve) => setTimeout(resolve, 350));

    const target = args.appName
      ? await WindowService.findWindowByApp(args.appName)
      : (await WindowService.findWindowByApp("Google Chrome")) ||
        (await WindowService.findWindowByApp("Safari"));

    const after = isBackground ? await NativeBridge.getFrontmostApplication() : null;
    const foregroundPreserved =
      isBackground && before && after ? before.pid === after.pid : null;

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              status: "opened",
              url: rawUrl,
              appName: args.appName || "default_browser",
              background: isBackground,
              target: target || { scope: "browser" },
              execution: executionMetadata({
                method: "/usr/bin/open",
                verification: target ? "window_observed" : "process_exit_zero",
                foregroundPreserved,
                target: target || { scope: "browser" },
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
