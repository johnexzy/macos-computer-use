import { z } from "zod";
import { MUTATING_ANNOTATIONS } from "../core/config.js";
import {
  executionMetadata,
  failedExecutionMetadata,
  requireUnsafeMode,
} from "../core/errors.js";
import { InputService } from "../services/input.service.js";
import type { ToolDefinition } from "../core/tool-registry.js";

const runAppleScriptSchema = z.object({
  script: z.string(),
});

type RunAppleScriptInput = z.infer<typeof runAppleScriptSchema>;

export const runAppleScriptTool: ToolDefinition<RunAppleScriptInput> = {
  name: "run_applescript",
  description:
    "Execute a custom AppleScript for advanced macOS UI scripting and accessibility inspection.",
  annotations: MUTATING_ANNOTATIONS,
  inputSchema: {
    type: "object",
    properties: {
      script: { type: "string", description: "The AppleScript code to run" },
    },
    required: ["script"],
  },
  schema: runAppleScriptSchema,
  execute: async (args) => {
    requireUnsafeMode("run_applescript");
    const res = await InputService.runAppleScript(args.script);
    if (res.error) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                status: "error",
                code: "APPLESCRIPT_FAILED",
                error: res.error,
                exitCode: res.exitCode,
                execution: failedExecutionMetadata(),
              },
              null,
              2
            ),
          },
        ],
      };
    }
    return {
      content: [{ type: "text", text: res.output || "Script executed." }],
    };
  },
};
