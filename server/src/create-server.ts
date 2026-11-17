import { Server } from "@modelcontextprotocol/server";
import type { ToolCaller } from "./broker.js";
import { createCallToolHandler, type ToolHandlerDeps } from "./tool-handler.js";
import { createToolAccess, type ToolAccessOptions } from "./tool-access.js";
import { VERSION } from "./version.js";
import { SKILL_PROMPT } from "./skill-content.js";
import { getSkillPrompt } from "./skill-prompt.js";
import { SERVER_INSTRUCTIONS } from "./server-instructions.js";

export type ServerDeps = ToolHandlerDeps | { callTool: ToolCaller };

export function createMcpServer(deps: ServerDeps, options: ToolAccessOptions = {}): Server {
  const access = createToolAccess(options);
  const server = new Server(
    { name: "lightroom-mcp-server", version: VERSION },
    { capabilities: { tools: {}, prompts: {} }, instructions: SERVER_INSTRUCTIONS },
  );

  server.setRequestHandler("tools/list", async () =>
    access.tools,
  );
  server.setRequestHandler("prompts/list", async () => ({ prompts: [SKILL_PROMPT] }));
  server.setRequestHandler("prompts/get", async (request) => getSkillPrompt(request.params.name));

  const callTool = access.restrict("callTool" in deps ? deps.callTool : createCallToolHandler(deps));
  server.setRequestHandler("tools/call", async (request, ctx) => {
    const { name, arguments: args } = request.params;
    const progressToken = request.params._meta?.progressToken;
    return callTool(name, args, {
      signal: ctx.mcpReq.signal,
      onProgress: progressToken === undefined ? undefined : (progress) => {
        void ctx.mcpReq.notify({ method: "notifications/progress", params: { progressToken, ...progress } }).catch(() => {});
      },
    });
  });

  return server;
}
