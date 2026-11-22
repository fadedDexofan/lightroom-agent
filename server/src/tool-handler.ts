import { PluginNotSentError, PluginTimeoutError, type CallOptions, type Dispatcher } from "./dispatcher.js";
import { DevelopQueue, type DevelopTurn } from "./develop-queue.js";
import { developUseOf, type ToolArgs } from "./tool-contracts.js";
import { TIMEOUT_MS_BY_DURATION } from "./tool-durations.js";
import {
  finishLost,
  finishReply,
  refusedResponse,
  toolResponse,
  unknownToolResponse,
  type ToolResponse,
} from "./tool-result.js";
import { CHECKED_CONTRACTS, validateToolArgs } from "./validate-args.js";

export interface ToolHandlerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  admitted: () => number | null;
  notReadyMessage?: () => string;
  settleReadiness?: () => Promise<void>;
}

export const NOT_CONNECTED_MESSAGE =
  "Lightroom plugin not connected. Bring Lightroom to the front or click 'Start Server' in Plug-in Manager.";

export const NOT_CONNECTED_DETAILS =
  "Lightroom plugin not connected. If Lightroom is already open, bring its window to the front once: " +
  "Lightroom starts plug-ins only after its window is first activated, so a Lightroom launched hidden or " +
  "in the background has not started the server yet. Otherwise open Lightroom and click 'Start Server' " +
  "in Plug-in Manager.";

const CONNECTION_CHANGED_MESSAGE =
  "The Lightroom connection this call arrived on was lost or replaced, so nothing more " +
  "of it was sent. Read the state before calling again.";

export function createCallToolHandler(deps: ToolHandlerDeps) {
  const queue = new DevelopQueue();
  return async (name: string, args: unknown, options?: CallOptions): Promise<ToolResponse> => {
    const checked = CHECKED_CONTRACTS.get(name);
    if (!checked) return unknownToolResponse(name);
    const { contract } = checked;
    const values = (args ?? {}) as ToolArgs;
    const invalid = validateToolArgs(checked, values);
    if (invalid) return refusedResponse(invalid);

    await deps.settleReadiness?.();
    const notReady = () => deps.notReadyMessage?.() ?? NOT_CONNECTED_MESSAGE;
    const generation = deps.admitted();
    if (generation === null) return refusedResponse(notReady());
    const withdrawn = (): string | null => (deps.admitted() === generation ? null : CONNECTION_CHANGED_MESSAGE);
    let held: DevelopTurn | null = null;
    const sendWithin = (
      turn: DevelopTurn,
      action: string,
      params: unknown,
      timeoutMs: number,
      callOptions?: CallOptions,
    ) =>
      deps.dispatcher.call(action, params, timeoutMs, callOptions).catch((error: unknown) => {
        if (error instanceof PluginTimeoutError) turn.outlive(error.settled);
        throw error;
      });
    const fenced: Pick<Dispatcher, "call"> = {
      call: async (action, params, timeoutMs, callOptions) => {
        const reason = withdrawn();
        if (reason !== null) throw new PluginNotSentError(reason);
        if (held) return sendWithin(held, action, params, timeoutMs, callOptions);
        if (!developUseOf(action)) return deps.dispatcher.call(action, params, timeoutMs, callOptions);
        const turn = await queue.run(name, timeoutMs, callOptions?.signal, (own) => {
          const late = withdrawn();
          if (late !== null) throw new PluginNotSentError(late);
          return sendWithin(own, action, params, own.remainingMs, callOptions);
        });
        if (!turn.ran) throw new PluginNotSentError(turn.reason);
        return turn.value;
      },
    };

    const readOnly = contract.annotations.readOnlyHint === true;
    const { run } = contract;
    const budgetMs = TIMEOUT_MS_BY_DURATION[contract.duration ?? "quick"];
    try {
      if (!("server" in run))
        return toolResponse(finishReply(readOnly, await fenced.call(name, values, budgetMs, options)));
      if (!contract.develop)
        return toolResponse(finishReply(readOnly, await run.server(values, fenced, budgetMs, options)));
      const turn = await queue.run(name, budgetMs, options?.signal, async (own) => {
        const reason = withdrawn();
        if (reason !== null) return refusedResponse(reason);
        held = own;
        return toolResponse(finishReply(readOnly, await run.server(values, fenced, own.remainingMs, options)));
      });
      return turn.ran ? turn.value : refusedResponse(turn.reason);
    } catch (error) {
      return toolResponse(
        finishLost(readOnly, failureText(name, readOnly, error), !(error instanceof PluginNotSentError)),
      );
    }
  };
}

function failureText(name: string, readOnly: boolean, error: unknown): string {
  if (error instanceof PluginTimeoutError && !readOnly) {
    return (
      `Lightroom did not answer within ${error.timeoutMs / 1000}s, so the result of ${name} is unknown:` +
      " it may have been applied or may still be running. Read the current state before retrying."
    );
  }
  return error instanceof Error ? error.message : String(error);
}
