import { z } from "zod";
import { failedExecutionMetadata, targetError } from "./errors.js";
import type { ToolAnnotations, ToolResult } from "../types/index.js";

export interface ToolDefinition<T = any> {
  name: string;
  description: string;
  annotations: ToolAnnotations;
  inputSchema: Record<string, any>;
  schema?: z.ZodType<T>;
  execute: (args: T) => Promise<ToolResult>;
}

export class ToolRegistry {
  private tools = new Map<string, ToolDefinition>();

  register(tool: ToolDefinition): void {
    this.tools.set(tool.name, tool);
  }

  getTool(name: string): ToolDefinition | undefined {
    return this.tools.get(name);
  }

  listTools() {
    return Array.from(this.tools.values()).map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: tool.annotations,
    }));
  }

  async invoke(name: string, rawArgs: any): Promise<ToolResult> {
    const tool = this.tools.get(name);
    if (!tool) {
      throw new Error(`Unknown tool: ${name}`);
    }

    try {
      let parsedArgs = rawArgs;
      if (tool.schema) {
        const parseResult = tool.schema.safeParse(rawArgs || {});
        if (!parseResult.success) {
          const firstIssue = parseResult.error.issues[0];
          throw targetError(
            "INVALID_ARGUMENTS",
            `Invalid arguments for tool ${name}: ${firstIssue?.message || "validation failed"}`,
            parseResult.error.issues
          );
        }
        parsedArgs = parseResult.data;
      }

      return await tool.execute(parsedArgs);
    } catch (error: any) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                status: "error",
                code: error.code || "TOOL_FAILED",
                tool: name,
                error: error.message,
                execution: failedExecutionMetadata(),
              },
              null,
              2
            ),
          },
        ],
      };
    }
  }
}
