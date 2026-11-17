import type { ToolCaller } from "./broker.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";
import { listToolsHandler } from "./list-tools-handler.js";
import { parseToolsets, type Toolset } from "./toolsets.js";
import { parseReadOnly } from "./read-only.js";
import { refusedResponse, unknownToolResponse } from "./tool-result.js";

export interface ToolAccessOptions {
  toolsets?: readonly Toolset[];
  readOnly?: boolean;
}

export function createToolAccess(options: ToolAccessOptions = {}) {
  const enabledToolsets = new Set<Toolset>(["core", ...(options.toolsets ?? parseToolsets())]);
  const readOnly = options.readOnly ?? parseReadOnly(process.env.LIGHTROOM_MCP_READ_ONLY);
  const tools = listToolsHandler(enabledToolsets, readOnly);
  const allowedTools = new Set(tools.tools.map((tool) => tool.name));
  const hiddenTools = new Map(TOOL_CONTRACTS.filter((tool) => !enabledToolsets.has(tool.toolset))
    .map((tool) => [tool.name, tool.toolset]));

  return {
    tools,
    restrict(callTool: ToolCaller): ToolCaller {
      return async (name, args, options) => {
        if (readOnly && !allowedTools.has(name)) {
          return refusedResponse(`Tool "${name}" is unavailable with LIGHTROOM_MCP_READ_ONLY enabled and the selected LIGHTROOM_MCP_TOOLSETS. Only listed read tools can be called. Change the settings and restart the server to enable other tools.`);
        }
        const toolset = hiddenTools.get(name);
        if (toolset) {
          return refusedResponse(`Tool "${name}" is disabled. Enable "${toolset}" in LIGHTROOM_MCP_TOOLSETS and restart the server.`);
        }
        if (!allowedTools.has(name)) return unknownToolResponse(name);
        return callTool(name, args, options);
      };
    },
  };
}
