import { RESULT_CONTRACT_VERSION, UNSAFE_MODE } from "./config.js";

export interface ExecutionMetadataOptions {
  method?: string | null;
  verification?: string;
  foregroundPreserved?: boolean | null;
  target?: unknown;
}

export function executionMetadata({
  method = null,
  verification = "api_acknowledged",
  foregroundPreserved = null,
  target = null,
}: ExecutionMetadataOptions = {}) {
  return {
    contractVersion: RESULT_CONTRACT_VERSION,
    accepted: true,
    verification,
    method: method || null,
    foregroundPreserved,
    target,
  };
}

export function failedExecutionMetadata() {
  return {
    contractVersion: RESULT_CONTRACT_VERSION,
    accepted: false,
    verification: "none",
  };
}

export class McpDomainError extends Error {
  public readonly code: string;
  public readonly details?: unknown;

  constructor(code: string, message: string, details?: unknown) {
    super(`${code}: ${message}`);
    this.name = "McpDomainError";
    this.code = code;
    this.details = details;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

export function targetError(code: string, message: string, details?: unknown): McpDomainError {
  return new McpDomainError(code, message, details);
}

export function requireUnsafeMode(toolName: string): void {
  if (UNSAFE_MODE) return;
  throw targetError(
    "UNSAFE_MODE_REQUIRED",
    `${toolName} requires explicit opt-in with MACOS_COMPUTER_USE_UNSAFE=1`
  );
}
