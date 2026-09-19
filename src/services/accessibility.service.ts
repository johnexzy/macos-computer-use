import { NativeBridge } from "../core/native-bridge.js";
import { targetError } from "../core/errors.js";
import type { WindowTarget, AXSelector, AXInspectOptions } from "../types/index.js";

export function normalizeSelector(selector: any): AXSelector {
  if (!selector || typeof selector !== "object" || Array.isArray(selector)) {
    throw targetError("INVALID_SELECTOR", "selector must be an object");
  }
  if (!["role", "identifier", "title", "description", "query"].some((key) => selector[key])) {
    throw targetError(
      "INVALID_SELECTOR",
      "selector requires role, identifier, title, description, or query"
    );
  }
  return selector as AXSelector;
}

export class AccessibilityService {
  static async assertTargetStayedBackground(
    before: { pid: number; appName: string },
    target: WindowTarget
  ) {
    const after = await NativeBridge.getFrontmostApplication();
    if (before.pid !== target.pid && after.pid === target.pid) {
      throw targetError(
        "FOREGROUND_CHANGED",
        `background operation activated "${target.appName}"`
      );
    }
    return after;
  }

  static async runBackgroundStep<T>(
    target: WindowTarget,
    operation: () => Promise<T>
  ): Promise<{
    result: T;
    foreground: {
      preserved: boolean;
      before: { pid: number; appName: string };
      after: { pid: number; appName: string };
    };
  }> {
    const before = await NativeBridge.getFrontmostApplication();
    let result: T;
    try {
      result = await operation();
    } catch (error) {
      await this.assertTargetStayedBackground(before, target);
      throw error;
    }
    const after = await this.assertTargetStayedBackground(before, target);
    return {
      result,
      foreground: {
        preserved: before.pid === after.pid,
        before: { pid: before.pid, appName: before.appName },
        after: { pid: after.pid, appName: after.appName },
      },
    };
  }

  static async inspectAccessibility(
    target: WindowTarget,
    options: Record<string, any> = {}
  ) {
    return await NativeBridge.call([
      "ax_inspect",
      String(target.pid),
      String(target.windowId),
      JSON.stringify(options),
    ]);
  }

  static async setAccessibilityValue(
    target: WindowTarget,
    selector: Record<string, any>,
    value: string
  ) {
    return await NativeBridge.call([
      "ax_set_value",
      String(target.pid),
      String(target.windowId),
      JSON.stringify(normalizeSelector(selector)),
      value,
    ]);
  }

  static async performAccessibilityAction(
    target: WindowTarget,
    selector: Record<string, any>,
    action: string
  ) {
    return await NativeBridge.call([
      "ax_perform",
      String(target.pid),
      String(target.windowId),
      JSON.stringify(normalizeSelector(selector)),
      action,
    ]);
  }

  static async postAccessibilityKey(
    target: WindowTarget,
    selector: Record<string, any>,
    key: string
  ) {
    return await NativeBridge.call([
      "ax_key",
      String(target.pid),
      String(target.windowId),
      JSON.stringify(normalizeSelector(selector)),
      key,
    ]);
  }

  static async typeTextIntoAccessibilityElement(
    target: WindowTarget,
    selector: Record<string, any>,
    text: string
  ) {
    return await NativeBridge.call([
      "ax_type",
      String(target.pid),
      String(target.windowId),
      JSON.stringify(normalizeSelector(selector)),
      text,
    ]);
  }

  static async waitForAccessibility(
    target: WindowTarget,
    selector: Record<string, any>,
    {
      minCount = 1,
      timeoutMs = 5000,
      roles = [],
      maxDepth = 30,
    }: {
      minCount?: number;
      timeoutMs?: number;
      roles?: string[];
      maxDepth?: number;
    } = {}
  ) {
    normalizeSelector(selector);
    const deadline = Date.now() + Math.max(100, timeoutMs);
    let lastInspection: any = null;

    while (Date.now() < deadline) {
      lastInspection = await this.inspectAccessibility(target, {
        selector,
        roles,
        maxDepth,
        maxResults: minCount,
      });

      if ((lastInspection.elements?.length || 0) >= minCount) {
        return {
          status: "ok",
          found: true,
          count: lastInspection.elements.length,
          elements: lastInspection.elements,
          target,
        };
      }

      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    throw targetError(
      "ACCESSIBILITY_WAIT_TIMEOUT",
      `fewer than ${minCount} Accessibility elements matched before timeout`,
      { lastInspection }
    );
  }
}
