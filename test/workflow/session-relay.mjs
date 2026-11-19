// The CLI owns only this byte relay. The campaign owns the MCP backend and ledger.
import { createConnection } from "node:net";

const socket = createConnection(process.argv[2]);
socket.on("error", () => { process.exitCode = 1; });
socket.on("close", () => process.stdin.pause());
process.stdin.pipe(socket);
socket.pipe(process.stdout);
