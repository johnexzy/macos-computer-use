import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveNativeHelper(): string {
  const candidates = [
    path.resolve(__dirname, "../../native_helper"),
    path.resolve(__dirname, "../native_helper"),
    path.resolve(process.cwd(), "native_helper"),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return path.resolve(__dirname, "../../native_helper");
}

export const NATIVE_HELPER = resolveNativeHelper();
export const PROJECT_ROOT = path.dirname(NATIVE_HELPER);

export const UNSAFE_MODE = process.env.MACOS_COMPUTER_USE_UNSAFE === "1";
export const RESULT_CONTRACT_VERSION = 1;

export const DEFAULT_MAX_WIDTH = 1440;
export const DEFAULT_TIMEOUT_SECONDS = 5.0;

export const READ_ONLY_ANNOTATIONS = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};

export const MUTATING_ANNOTATIONS = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: true,
};

export const NAVIGATION_ANNOTATIONS = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
};

export const LAUNCH_ANNOTATIONS = {
  ...NAVIGATION_ANNOTATIONS,
  idempotentHint: true,
};
