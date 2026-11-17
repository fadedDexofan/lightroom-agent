import { PluginNotSentError, PluginTimeoutError, type CallOptions, type Dispatcher } from "./dispatcher.js";
import { DevelopQueue } from "./develop-queue.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";
import { TIMEOUT_MS_BY_DURATION } from "./tool-durations.js";
import { finishLost, finishReply, refusedResponse, toolResponse, unknownToolResponse, type PluginReply, type ToolResponse } from "./tool-result.js";
import { validateToolArgs } from "./validate-args.js";

export interface ToolHandlerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
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

export function createCallToolHandler(deps: ToolHandlerDeps) {
  const queue = new DevelopQueue();
  return async (name: string, args: unknown, options?: CallOptions): Promise<ToolResponse> => {
    const contract = CONTRACTS.get(name);
    if (!contract) return unknownToolResponse(name);
    const invalid = validateToolArgs(name, args);
    if (invalid) return refusedResponse(invalid);

    await deps.settleReadiness?.();

    if (!deps.isReady()) return refusedResponse(deps.notReadyMessage?.() ?? NOT_CONNECTED_MESSAGE);

    const readOnly = contract.annotations.readOnlyHint === true;
    const { run } = contract;
    const budgetMs = TIMEOUT_MS_BY_DURATION[contract.duration ?? "quick"];
    const invoke = async (left: number): Promise<PluginReply> => "server" in run
      ? await run.server(args, deps.dispatcher, left, options)
      : await deps.dispatcher.call(name, args, left, options) as PluginReply;
    try {
      if (!contract.develop) return toolResponse(finishReply(readOnly, await invoke(budgetMs)));
      const turn = await queue.run(name, budgetMs, options?.signal, invoke);
      if (!turn.ran) return refusedResponse(turn.reason);
      return toolResponse(finishReply(readOnly, turn.value));
    } catch (error) {
      return toolResponse(finishLost(readOnly, failureText(name, readOnly, error), !(error instanceof PluginNotSentError)));
    }
  };
}

const CONTRACTS = new Map(TOOL_CONTRACTS.map((contract) => [contract.name, contract]));

function failureText(name: string, readOnly: boolean, error: unknown): string {
  if (error instanceof PluginTimeoutError && !readOnly) {
    return `Lightroom did not answer within ${error.timeoutMs / 1000}s, so the result of ${name} is unknown:`
      + " it may have been applied or may still be running. Read the current state before retrying.";
  }
  return error instanceof Error ? error.message : String(error);
}
