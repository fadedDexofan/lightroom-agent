import type { PluginReply } from "./tool-result.js";

export interface ToolProgress {
  progress: number;
  total?: number;
  message?: string;
}

export interface CallOptions {
  signal?: AbortSignal;
  onProgress?: (progress: ToolProgress) => void;
}

export type PluginResponse = PluginReply & { id: string };

export class PluginNotSentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PluginNotSentError";
  }
}

const MIN_CALL_MS = 1_000;

export const LATE_REPLY_GRACE_MS = 60_000;

export class PluginTimeoutError extends Error {
  constructor(
    readonly timeoutMs: number,
    readonly settled: Promise<void> = Promise.resolve(),
  ) {
    super(`Plugin response timeout (${timeoutMs / 1000}s)`);
    this.name = "PluginTimeoutError";
  }
}

interface PendingResponse {
  resolve: (resp: PluginResponse) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
  onProgress?: (progress: ToolProgress) => void;
  cleanup: () => void;
}

export interface DispatcherOptions {
  send: (line: string) => boolean;
  getToken: () => string;
  connectionGeneration: () => number;
  log?: (msg: string) => void;
  lateReplyGraceMs?: number;
}

export class Dispatcher {
  private pending = new Map<string, PendingResponse>();
  private idCounter = 0;
  private readonly send: (line: string) => boolean;
  private readonly getToken: () => string;
  private readonly connectionGeneration: () => number;
  private readonly log: (msg: string) => void;
  private readonly lateReplyGraceMs: number;
  private readonly lingering = new Map<string, () => void>();

  constructor(opts: DispatcherOptions) {
    this.send = opts.send;
    this.getToken = opts.getToken;
    this.connectionGeneration = opts.connectionGeneration;
    this.log = opts.log ?? ((msg: string) => console.error(msg));
    this.lateReplyGraceMs = opts.lateReplyGraceMs ?? LATE_REPLY_GRACE_MS;
  }

  handleResponseLine(line: string): void {
    let resp: PluginResponse;
    try {
      resp = JSON.parse(line) as PluginResponse;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      this.log(`Bad JSON from plugin (${msg}): ${line}`);
      return;
    }
    if (typeof resp !== "object" || resp === null || Array.isArray(resp)) {
      this.log(`Non-object JSON from plugin: ${line}`);
      return;
    }
    const event = resp as unknown as { progressFor?: string; progress?: ToolProgress };
    if (event.progressFor && event.progress) {
      this.pending.get(event.progressFor)?.onProgress?.(event.progress);
      return;
    }
    const p = this.pending.get(resp.id);
    if (!p) {
      const finish = this.lingering.get(resp.id);
      if (finish) {
        this.log(`Late response for timed-out id: ${resp.id}`);
        finish();
        return;
      }
      this.log(`Response for unknown id: ${resp.id}`);
      return;
    }
    clearTimeout(p.timer);
    p.cleanup();
    this.pending.delete(resp.id);
    p.resolve(resp);
  }

  async call(action: string, params: unknown, timeoutMs: number, options?: CallOptions): Promise<PluginResponse> {
    const id = `req_${Date.now()}_${this.idCounter++}`;

    if (options?.signal?.aborted) throw new PluginNotSentError("Request cancelled");
    if (timeoutMs < MIN_CALL_MS) {
      throw new PluginNotSentError(
        `Only ${Math.max(0, Math.round(timeoutMs))} ms of the time budget were left, so ${action} was not sent`,
      );
    }
    const generation = this.connectionGeneration();
    const cancel = () => {
      if (this.pending.has(id) && this.connectionGeneration() === generation) {
        this.send(JSON.stringify({ hello: this.getToken(), action: "cancel", params: { request_id: id } }));
      }
    };
    const responsePromise = new Promise<PluginResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        options?.signal?.removeEventListener("abort", cancel);
        cancel();
        this.pending.delete(id);
        reject(new PluginTimeoutError(timeoutMs, this.lingerFor(id)));
      }, timeoutMs);
      this.pending.set(id, {
        resolve,
        reject,
        timer,
        onProgress: options?.onProgress,
        cleanup: () => options?.signal?.removeEventListener("abort", cancel),
      });
      options?.signal?.addEventListener("abort", cancel, { once: true });
    });

    const cleanup = () => {
      const p = this.pending.get(id);
      if (p) {
        clearTimeout(p.timer);
        p.cleanup();
      }
      this.pending.delete(id);
    };

    let payload: string;
    try {
      payload = JSON.stringify({
        hello: this.getToken(),
        id,
        action,
        params,
        reportProgress: Boolean(options?.onProgress),
        budget_ms: timeoutMs,
      });
    } catch (err) {
      cleanup();
      throw err;
    }

    if (!this.send(payload)) {
      cleanup();
      throw new PluginNotSentError("Failed to send request to plugin (socket dropped)");
    }

    return responsePromise;
  }

  private lingerFor(id: string): Promise<void> {
    return new Promise<void>((resolve) => {
      const finish = () => {
        clearTimeout(grace);
        this.lingering.delete(id);
        resolve();
      };
      const grace = setTimeout(finish, this.lateReplyGraceMs);
      grace.unref?.();
      this.lingering.set(id, finish);
    });
  }

  rejectPending(reason: string): void {
    for (const finish of [...this.lingering.values()]) finish();
    for (const [id, p] of this.pending) {
      clearTimeout(p.timer);
      p.cleanup();
      this.pending.delete(id);
      p.reject(new Error(reason));
    }
  }
}
