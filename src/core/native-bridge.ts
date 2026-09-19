import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { NATIVE_HELPER } from "./config.js";
import { targetError } from "./errors.js";

const execFileAsync = promisify(execFile);

export class NativeBridge {
  static async call<T = any>(args: string[]): Promise<T> {
    try {
      const { stdout } = await execFileAsync(NATIVE_HELPER, args, { maxBuffer: 10 * 1024 * 1024 });
      const trimmed = stdout.trim();
      if (!trimmed) {
        return {} as T;
      }
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed === "object" && parsed.status === "error") {
        throw targetError(
          parsed.code || "NATIVE_HELPER_FAILED",
          parsed.error || "native operation failed",
          parsed
        );
      }
      return parsed as T;
    } catch (error: any) {
      if (error.code && typeof error.code === "string" && !error.cmd) {
        throw error; // Already a targetError
      }
      // Stderr or process spawn error
      const message = error.stderr?.trim() || error.message || "Failed to execute native helper";
      throw targetError("NATIVE_EXEC_FAILED", message, { originalError: error.message });
    }
  }

  static async getDisplayInfo() {
    try {
      return await this.call(["size"]);
    } catch {
      return { width: 1800, height: 1169, scale: 2, pixelWidth: 3600, pixelHeight: 2338 };
    }
  }

  static async getFrontmostApplication() {
    return await this.call(["frontmost_app"]);
  }

  static async getCapabilities() {
    return await this.call(["capabilities"]);
  }

  static async requireInputPostingAccess(toolName: string): Promise<void> {
    const caps = await this.getCapabilities();
    if (caps.permissions?.inputPosting) return;
    throw targetError(
      "INPUT_POSTING_PERMISSION_REQUIRED",
      `${toolName} requires macOS event-synthesizing access. Inspect get_capabilities before retrying.`
    );
  }
}
