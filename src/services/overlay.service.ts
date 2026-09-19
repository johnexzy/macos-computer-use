import { spawn, type ChildProcess } from "node:child_process";
import { createInterface, type Interface } from "node:readline";
import { NATIVE_HELPER } from "../core/config.js";
import { targetError } from "../core/errors.js";
import { NativeBridge } from "../core/native-bridge.js";

export class AgentCursorOverlay {
  private child: ChildProcess | null = null;
  private reader: Interface | null = null;
  private readyPromise: Promise<any> | null = null;
  private resolveReady: ((value: any) => void) | null = null;
  private rejectReady: ((reason?: any) => void) | null = null;
  private readyTimer: NodeJS.Timeout | null = null;
  private pending = new Map<string, { resolve: (val: any) => void; timer: NodeJS.Timeout }>();
  private nextId = 1;
  private lastError = "";

  async start(): Promise<any> {
    if (this.child && this.readyPromise) {
      return this.readyPromise;
    }

    this.lastError = "";
    this.readyPromise = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });

    const child = spawn(NATIVE_HELPER, ["cursor_overlay"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    this.reader = createInterface({ input: child.stdout! });
    this.reader.on("line", (line) => this.handleLine(line));

    child.stderr?.on("data", (chunk) => {
      this.lastError = `${this.lastError}${chunk}`.slice(-1000);
    });

    child.stdin?.on("error", (error) => this.handleExit(child, error));
    child.once("error", (error) => this.handleExit(child, error));
    child.once("exit", (code, signal) => {
      this.handleExit(
        child,
        new Error(
          this.lastError.trim() ||
            `cursor overlay exited${signal ? ` from ${signal}` : ` with code ${code}`}`
        )
      );
    });

    this.readyTimer = setTimeout(() => {
      this.rejectReady?.(new Error("cursor overlay did not become ready"));
      this.stop();
    }, 2000);

    return this.readyPromise;
  }

  private handleLine(line: string) {
    let message: any;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }

    if (message.status === "ready") {
      if (this.readyTimer) clearTimeout(this.readyTimer);
      this.readyTimer = null;
      this.resolveReady?.(message);
      this.resolveReady = null;
      this.rejectReady = null;
      return;
    }

    const request = this.pending.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    this.pending.delete(message.id);
    request.resolve(message);
  }

  private handleExit(child: ChildProcess, error: Error) {
    if (this.child !== child) return;
    if (this.readyTimer) clearTimeout(this.readyTimer);
    this.readyTimer = null;
    this.rejectReady?.(error);
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.resolve({ status: "unavailable", error: error.message });
    }
    this.pending.clear();
    this.reader?.close();
    this.reader = null;
    this.child = null;
    this.readyPromise = null;
    this.resolveReady = null;
    this.rejectReady = null;
  }

  async send(command: Record<string, any>): Promise<any> {
    try {
      await this.start();
      if (!this.child?.stdin?.writable) {
        throw new Error("cursor overlay input is unavailable");
      }

      const id = String(this.nextId++);
      const response = new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          resolve({ status: "unavailable", error: "cursor overlay command timed out" });
        }, 2500);
        this.pending.set(id, { resolve, timer });
      });
      this.child.stdin.write(`${JSON.stringify({ id, ...command })}\n`);
      return await response;
    } catch (error: any) {
      return { status: "unavailable", error: error.message };
    }
  }

  stop() {
    if (this.readyTimer) clearTimeout(this.readyTimer);
    this.readyTimer = null;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.resolve({ status: "unavailable", error: "cursor overlay stopped" });
    }
    this.pending.clear();
    this.reader?.close();
    this.reader = null;
    this.child?.kill();
    this.child = null;
    this.readyPromise = null;
  }
}

export const agentCursor = new AgentCursorOverlay();

process.once("exit", () => agentCursor.stop());
process.stdin.once("end", () => agentCursor.stop());

export async function runPointAction(
  x: number,
  y: number,
  helperArgs: string[],
  successFeedback: string
) {
  const cursorOverlay = await agentCursor.send({
    action: "move",
    x,
    y,
    durationMs: 160,
  });

  try {
    const action = await NativeBridge.call(helperArgs);
    if (action.status !== "ok") {
      throw targetError(action.code || "ACTION_FAILED", action.error || "action could not be delivered");
    }
    await agentCursor.send({ action: successFeedback });
    return { action, cursorOverlay };
  } catch (error) {
    await agentCursor.send({ action: "error" });
    throw error;
  }
}
