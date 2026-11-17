import type { Dispatcher } from "./dispatcher.js";

/**
 * Whether the plugin is actually answering, as opposed to merely accepting TCP
 * connections.
 *
 * The plugin serves one client per port. A second bridge still connects
 * successfully -- the kernel accepts, the plugin never reads -- so socket state
 * alone reports "ready" while every request sits unanswered until it times out
 * (issue 215). Pings settle that question, so readiness follows the pings:
 *
 *   unknown      no ping has settled yet. A tool call waits for the in-flight
 *                probe rather than racing it, so no call is ever dispatched
 *                into a connection nobody is reading.
 *   responsive   a ping came back.
 *   unresponsive a ping timed out. Tool calls fail immediately with an
 *                explanation instead of burning the full request timeout each.
 */
export type PluginLivenessState = "unknown" | "responsive" | "unresponsive";

export const HEARTBEAT_INTERVAL_SECONDS = 30;

export interface LivenessOptions {
  dispatcher: Pick<Dispatcher, "call">;
  connected: () => boolean;
  reporter: { report(): void; clear(): void };
  heartbeatIntervalMs: number;
  heartbeatTimeoutMs: number;
  probeTimeoutMs: number;
  recoveryIntervalMs: number;
}

export class PluginLiveness {
  private state: PluginLivenessState = "unknown";
  private pending: Promise<void> | null = null;
  private resolvePending: (() => void) | null = null;
  private generation = 0;
  private heartbeat: NodeJS.Timeout | null = null;
  private recovery: NodeJS.Timeout | null = null;

  constructor(private readonly opts: LivenessOptions) {}

  start(): void {
    this.heartbeat = setInterval(() => {
      if (this.opts.connected()) this.check(this.opts.heartbeatTimeoutMs);
    }, this.opts.heartbeatIntervalMs);
  }

  stop(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
    this.stopRecovery();
  }

  check(timeoutMs = this.opts.probeTimeoutMs): void {
    if (this.pending) return;
    this.pending = new Promise<void>((resolve) => {
      this.resolvePending = resolve;
    });
    const token = this.generation;
    void this.ping(timeoutMs).then((answered) => this.settle(token, answered));
  }

  reset(): void {
    this.state = "unknown";
    this.generation += 1;
    this.release();
    this.opts.reporter.clear();
    this.stopRecovery();
  }

  async settled(): Promise<void> {
    if (this.state !== "unknown" || !this.pending) return;
    await this.pending;
  }

  isUsable(): boolean {
    return this.state !== "unresponsive";
  }

  private settle(token: number, answered: boolean): void {
    if (token !== this.generation) return;
    if (!answered && !this.opts.connected()) {
      this.reset();
      return;
    }
    this.state = answered ? "responsive" : "unresponsive";
    this.release();
    if (answered) {
      this.opts.reporter.clear();
      this.stopRecovery();
      return;
    }
    this.opts.reporter.report();
    this.recovery ??= setInterval(() => this.check(), this.opts.recoveryIntervalMs);
  }

  private ping(timeoutMs: number): Promise<boolean> {
    return this.opts.dispatcher.call("ping", {}, timeoutMs).then(() => true, () => false);
  }

  private stopRecovery(): void {
    if (this.recovery) clearInterval(this.recovery);
    this.recovery = null;
  }

  private release(): void {
    const resolve = this.resolvePending;
    this.pending = null;
    this.resolvePending = null;
    resolve?.();
  }
}
