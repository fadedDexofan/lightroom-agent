import { PluginTimeoutError } from "./dispatcher.js";

export type QueueTurn<T> = { ran: true; value: T } | { ran: false; reason: string };

export class DevelopQueue {
  private tail: Promise<void> = Promise.resolve();
  private running: string | null = null;

  async run<T>(
    name: string,
    budgetMs: number,
    signal: AbortSignal | undefined,
    work: (remainingMs: number) => Promise<T>,
  ): Promise<QueueTurn<T>> {
    const startedAt = Date.now();
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => { release = resolve; });

    let timer: NodeJS.Timeout | undefined;
    let onAbort: (() => void) | undefined;
    const waited = await Promise.race([
      previous.then(() => "turn" as const),
      new Promise<"timeout">((resolve) => { timer = setTimeout(() => resolve("timeout"), budgetMs); }),
      new Promise<"aborted">((resolve) => {
        if (signal?.aborted) resolve("aborted");
        onAbort = () => resolve("aborted");
        signal?.addEventListener("abort", onAbort, { once: true });
      }),
    ]);
    clearTimeout(timer);
    if (onAbort) signal?.removeEventListener("abort", onAbort);

    const remainingMs = budgetMs - (Date.now() - startedAt);
    if (waited !== "turn") {
      const busy = this.running ?? "another Develop call";
      void previous.then(release);
      return {
        ran: false,
        reason: waited === "aborted"
          ? `Request cancelled while waiting for ${busy}; nothing was done.`
          : `Lightroom was busy with ${busy} for ${Math.round((Date.now() - startedAt) / 1000)} s; nothing was done.`,
      };
    }
    this.running = name;
    let finishing: Promise<void> | undefined;
    try {
      return { ran: true, value: await work(remainingMs) };
    } catch (error) {
      if (error instanceof PluginTimeoutError) finishing = error.settled;
      throw error;
    } finally {
      if (finishing) {
        this.running = `${name}, still finishing in Lightroom after it timed out`;
        void finishing.then(() => {
          this.running = null;
          release();
        });
      } else {
        this.running = null;
        release();
      }
    }
  }
}
