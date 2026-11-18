import type { Dispatcher } from "./dispatcher.js";
import { BUILD_FIELDS, identityIn, sameIdentity, type BuildIdentity } from "./build-identity.js";
import type { PluginIdentity } from "./contract-lua.js";

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
 *   incompatible a ping came back from a plug-in of another version or build
 *                than the server's bundled one. Tool calls fail immediately,
 *                naming both.
 */
export type PluginLivenessState = "unknown" | "responsive" | "unresponsive" | "incompatible";

export const HEARTBEAT_INTERVAL_SECONDS = 30;

export interface LivenessOptions {
  dispatcher: Pick<Dispatcher, "call">;
  connected: () => boolean;
  reporter: { report(): void; clear(): void };
  heartbeatIntervalMs: number;
  heartbeatTimeoutMs: number;
  probeTimeoutMs: number;
  recoveryIntervalMs: number;
  plugin: PluginIdentity;
}

type PingAnswer = { answered: false } | { answered: true; identity: BuildIdentity };

const INSTALL_FIX = "Lightroom has loaded a different plug-in build. If the intended build was installed or repaired, "
  + "restart Lightroom to load it. Otherwise quit the connected clients, run this build's install-plugin, check its result, "
  + "restart Lightroom, and reconnect.";

function pluginMismatch(plugin: BuildIdentity, expected: PluginIdentity): string {
  const loaded = plugin.version === null
    ? "an older build that reports no version"
    : `version ${plugin.version}, build ${plugin.build ?? "unknown"}`;
  return `${INSTALL_FIX} Loaded: ${loaded}; this server's: version ${expected.version}, build ${expected.build}.`;
}

export class PluginLiveness {
  private state: PluginLivenessState = "unknown";
  private plugin: BuildIdentity = { version: null, build: null };
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
    void this.ping(timeoutMs).then((answer) => this.settle(token, answer));
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
    return this.state !== "unresponsive" && this.state !== "incompatible";
  }

  incompatibility(): string | null {
    if (this.state !== "incompatible") return null;
    return pluginMismatch(this.plugin, this.opts.plugin);
  }

  private settle(token: number, answer: PingAnswer): void {
    if (token !== this.generation) return;
    if (!answer.answered && !this.opts.connected()) {
      this.reset();
      return;
    }
    this.release();
    if (answer.answered) {
      this.plugin = answer.identity;
      this.state = sameIdentity(answer.identity, this.opts.plugin) ? "responsive" : "incompatible";
      this.opts.reporter.clear();
      this.stopRecovery();
      return;
    }
    this.state = "unresponsive";
    this.opts.reporter.report();
    this.recovery ??= setInterval(() => this.check(), this.opts.recoveryIntervalMs);
  }

  private ping(timeoutMs: number): Promise<PingAnswer> {
    return this.opts.dispatcher.call("ping", {}, timeoutMs).then((reply) => {
      return { answered: true, identity: identityIn(reply.result?.data, BUILD_FIELDS) };
    }, () => ({ answered: false }));
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
