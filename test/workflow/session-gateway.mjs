import { once } from "node:events";
import { mkdtemp, rmdir } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { laneName } from "./session-lane.mjs";

const relay = fileURLToPath(new URL("./session-relay.mjs", import.meta.url));

export async function openGateway(lane) {
  // mkdtemp creates a private directory. A short path avoids AF_UNIX length limits.
  const directory = await mkdtemp("/tmp/cua-session-");
  const socketPath = path.join(directory, "mcp.sock");
  let connection, server, accepted = false, refusedConnections = 0;
  const listener = createServer((socket) => {
    if (accepted) {
      refusedConnections++;
      socket.destroy();
      return;
    }
    accepted = true;
    connection = socket;
    socket.on("error", () => socket.destroy());
    server = new Server({ name: laneName, version: "1" }, { capabilities: { tools: {} } });
    server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: lane.tools }));
    server.setRequestHandler(CallToolRequestSchema, async ({ params }) => lane.call(params.name, params.arguments));
    const transport = new StdioServerTransport(socket, socket, { maxBufferSize: 1024 * 1024 });
    socket.once("close", () => { void server.close().catch(() => {}); });
    void server.connect(transport).catch(() => socket.destroy());
  });
  try {
    listener.listen(socketPath);
    await once(listener, "listening");
  } catch (error) {
    await rmdir(directory);
    throw error;
  }
  return {
    config: { mcpServers: { [laneName]: { type: "stdio", command: process.execPath, args: [relay, socketPath] } } },
    connectionState: () => ({ accepted, refusedConnections }),
    async close() {
      lane.stopped = true;
      connection?.destroy();
      const closed = once(listener, "close");
      listener.close();
      await closed;
      await rmdir(directory);
    },
  };
}
