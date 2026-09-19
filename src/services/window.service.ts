import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { NativeBridge } from "../core/native-bridge.js";
import { targetError } from "../core/errors.js";
import type { WindowInfo, WindowTarget } from "../types/index.js";

const execFileAsync = promisify(execFile);

export function normalizeAppName(value: unknown): string {
  return String(value || "")
    .normalize("NFKC")
    .toLowerCase()
    .trim();
}

export class WindowService {
  static async findWindowByApp(appName: string): Promise<WindowTarget | null> {
    try {
      const parsed = await NativeBridge.call(["find_window", appName]);
      if (parsed.status === "ok") {
        return parsed as WindowTarget;
      }
    } catch {}
    return null;
  }

  static async getWindowBounds(windowId: number): Promise<WindowTarget | null> {
    try {
      const parsed = await NativeBridge.call(["get_window_bounds", String(windowId)]);
      if (parsed.status === "ok") {
        return parsed as WindowTarget;
      }
    } catch {}
    return null;
  }

  static async listAllWindows(appName: string | null = null): Promise<WindowInfo[]> {
    try {
      const args = ["list_windows"];
      if (appName) args.push(appName);
      return await NativeBridge.call(args);
    } catch {
      return [];
    }
  }

  static async findApplicationPath(appName: string): Promise<string | null> {
    if (path.isAbsolute(appName) && appName.endsWith(".app")) {
      await fs.access(appName);
      return appName;
    }

    const query = normalizeAppName(appName.replace(/\.app$/i, ""));
    const roots = ["/Applications", path.join(os.homedir(), "Applications"), "/System/Applications"];
    const candidates: string[] = [];

    for (const root of roots) {
      try {
        await fs.access(root);
        const { stdout } = await execFileAsync("/usr/bin/find", [
          root,
          "-maxdepth",
          "3",
          "-type",
          "d",
          "-name",
          "*.app",
        ]);
        candidates.push(...stdout.trim().split("\n").filter(Boolean));
      } catch {}
    }

    const exact = candidates.find(
      (candidate) => normalizeAppName(path.basename(candidate, ".app")) === query
    );
    if (exact) return exact;
    return (
      candidates.find((candidate) =>
        normalizeAppName(path.basename(candidate, ".app")).includes(query)
      ) || null
    );
  }

  static async launchApplication(appName: string, { activate = false } = {}) {
    const existing = await this.findWindowByApp(appName);
    if (existing && !activate) {
      return { status: "ok", activated: false, alreadyRunning: true, target: existing };
    }

    const applicationPath = await this.findApplicationPath(appName);
    const openArgs: string[] = [];
    if (!activate) openArgs.push("-g");
    if (applicationPath) openArgs.push(applicationPath);
    else openArgs.push("-a", appName);
    await execFileAsync("/usr/bin/open", openArgs);

    for (let attempt = 0; attempt < 30; attempt += 1) {
      const target = await this.findWindowByApp(appName);
      if (target) {
        return { status: "ok", activated: activate, alreadyRunning: Boolean(existing), target };
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw targetError("TARGET_NOT_FOUND", `application "${appName}" did not expose a window`);
  }

  static async resolveTarget(args: {
    appName?: string;
    targetApp?: string;
    windowId?: number;
  }): Promise<WindowTarget | null> {
    const appName = args.appName || args.targetApp;
    const windowId = typeof args.windowId === "number" ? args.windowId : null;

    if (windowId !== null) {
      const target = await this.getWindowBounds(windowId);
      if (!target) {
        throw targetError("TARGET_NOT_FOUND", `Window ID ${windowId} not found`);
      }
      if (appName) {
        const query = normalizeAppName(appName);
        const matched =
          normalizeAppName(target.appName).includes(query) ||
          normalizeAppName(target.title).includes(query);
        if (!matched) {
          throw targetError(
            "TARGET_MISMATCH",
            `Window ID ${windowId} does not belong to "${appName}"`
          );
        }
      }
      return target;
    }

    if (appName) {
      const target = await this.findWindowByApp(appName);
      if (!target) {
        throw targetError("TARGET_NOT_FOUND", `No window found matching "${appName}"`);
      }
      return target;
    }

    return null;
  }

  static async resolveRequiredTarget(args: {
    appName?: string;
    targetApp?: string;
    windowId?: number;
  }): Promise<WindowTarget> {
    const target = await this.resolveTarget(args);
    if (!target) {
      throw targetError(
        "BACKGROUND_TARGET_REQUIRED",
        "background operation requires appName or windowId"
      );
    }
    return target;
  }
}
