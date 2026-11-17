import { Server } from "@modelcontextprotocol/server";
import type { ToolCaller } from "./broker.js";
import type { ToolAccess } from "./tool-access.js";
import { VERSION } from "./version.js";
import { SKILL_PROMPT } from "./skill-content.js";
import { getSkillPrompt } from "./skill-prompt.js";
import { SERVER_INSTRUCTIONS } from "./server-instructions.js";

export function createMcpServer(callTool: ToolCaller, access: ToolAccess): Server {
  const server = new Server(
    { name: "lightroom-mcp-server", version: VERSION },
    { capabilities: { tools: {}, prompts: {} }, instructions: SERVER_INSTRUCTIONS },
  );

  server.setRequestHandler("tools/list", async () =>
    access.tools,
  );
  server.setRequestHandler("prompts/list", async () => ({ prompts: [SKILL_PROMPT] }));
  server.setRequestHandler("prompts/get", async (request) => getSkillPrompt(request.params.name));

  const restricted = access.restrict(callTool);
  server.setRequestHandler("tools/call", async (request, ctx) => {
    const { name, arguments: args } = request.params;
    const progressToken = request.params._meta?.progressToken;
    return restricted(name, args, {
      signal: ctx.mcpReq.signal,
      onProgress: progressToken === undefined ? undefined : (progress) => {
        void ctx.mcpReq.notify({ method: "notifications/progress", params: { progressToken, ...progress } }).catch(() => {});
      },
    });
  });

  return server;
}
