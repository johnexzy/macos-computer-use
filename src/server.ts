import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { UNSAFE_MODE } from "./core/config.js";
import { ToolRegistry } from "./core/tool-registry.js";
import { screenshotTool } from "./tools/screenshot.tool.js";
import { findTextTool } from "./tools/find-text.tool.js";
import { clickTextTool } from "./tools/click-text.tool.js";
import { waitForTextTool } from "./tools/wait-for-text.tool.js";
import { listWindowsTool } from "./tools/list-windows.tool.js";
import { inspectAccessibilityTool } from "./tools/inspect-accessibility.tool.js";
import { setAccessibilityValueTool } from "./tools/set-accessibility-value.tool.js";
import { performAccessibilityActionTool } from "./tools/perform-accessibility-action.tool.js";
import { waitForAccessibilityTool } from "./tools/wait-for-accessibility.tool.js";
import { mouseClickTool } from "./tools/mouse-click.tool.js";
import { typeTextTool } from "./tools/type-text.tool.js";
import { pressKeyTool } from "./tools/press-key.tool.js";
import { scrollTool } from "./tools/scroll.tool.js";
import { launchAppTool } from "./tools/launch-app.tool.js";
import { getCapabilitiesTool } from "./tools/get-capabilities.tool.js";
import { getActiveAppTool } from "./tools/get-active-app.tool.js";
import { runAppleScriptTool } from "./tools/run-applescript.tool.js";

export function createToolRegistry(): ToolRegistry {
  const registry = new ToolRegistry();

  registry.register(screenshotTool);
  registry.register(findTextTool);
  registry.register(clickTextTool);
  registry.register(waitForTextTool);
  registry.register(listWindowsTool);
  registry.register(inspectAccessibilityTool);
  registry.register(setAccessibilityValueTool);
  registry.register(performAccessibilityActionTool);
  registry.register(waitForAccessibilityTool);
  registry.register(mouseClickTool);
  registry.register(typeTextTool);
  registry.register(pressKeyTool);
  registry.register(scrollTool);
  registry.register(launchAppTool);
  registry.register(getCapabilitiesTool);
  registry.register(getActiveAppTool);

  if (UNSAFE_MODE) {
    registry.register(runAppleScriptTool);
  }

  return registry;
}

export function createMcpServer(registry: ToolRegistry = createToolRegistry()): Server {
  const server = new Server(
    {
      name: "macos-computer-use",
      version: "2.5.0",
    },
    {
      capabilities: {
        tools: {},
      },
    }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: registry.listTools(),
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args = {} } = request.params;
    return await registry.invoke(name, args);
  });

  return server;
}

export async function startServer(): Promise<void> {
  const server = createMcpServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
