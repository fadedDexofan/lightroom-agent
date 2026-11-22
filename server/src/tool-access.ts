import type { ToolCaller } from "./broker.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";
import { listToolsHandler } from "./list-tools-handler.js";
import type { Toolset } from "./toolsets.js";
import { refusedResponse, unknownToolResponse } from "./tool-result.js";

export interface ToolAccessOptions {
  toolsets: readonly Toolset[];
  readOnly: boolean;
}

export type ToolAccess = ReturnType<typeof createToolAccess>;

export function createToolAccess({ toolsets, readOnly }: ToolAccessOptions) {
  const enabledToolsets = new Set<Toolset>(toolsets);
  const tools = listToolsHandler(enabledToolsets, readOnly);
  const allowedTools = new Set(tools.tools.map((tool) => tool.name));
  const hiddenTools = new Map(
    TOOL_CONTRACTS.filter((tool) => !enabledToolsets.has(tool.toolset)).map((tool) => [tool.name, tool.toolset]),
  );

  return {
    tools,
    summary: `Toolsets: ${[...enabledToolsets].join(", ")}; read-only mode: ${readOnly ? "on" : "off"}`,
    restrict(callTool: ToolCaller): ToolCaller {
      return async (name, args, options) => {
        if (readOnly && !allowedTools.has(name)) {
          return refusedResponse(
            `Tool "${name}" is unavailable with LIGHTROOM_AGENT_READ_ONLY enabled and the selected LIGHTROOM_AGENT_TOOLSETS. Only listed read tools can be called. Change the settings and restart the server to enable other tools.`,
          );
        }
        const toolset = hiddenTools.get(name);
        if (toolset) {
          return refusedResponse(
            `Tool "${name}" is disabled. Enable "${toolset}" in LIGHTROOM_AGENT_TOOLSETS and restart the server.`,
          );
        }
        if (!allowedTools.has(name)) return unknownToolResponse(name);
        return callTool(name, args, options);
      };
    },
  };
}
