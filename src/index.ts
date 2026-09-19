#!/usr/bin/env node

import { startServer } from "./server.js";

startServer().catch((error) => {
  console.error("Fatal error starting macos-computer-use server:", error);
  process.exit(1);
});
