export type ParsedCli =
  | { command: "stdio" | "install-plugin" | "help" | "version" }
  | { command: "tools"; name?: string }
  | { command: "call"; name: string; args: Record<string, unknown> };

const HELP = `lightroom-mcp — MCP bridge and CLI for Adobe Lightroom Classic

USAGE
  lightroom-mcp [stdio]            Run MCP over stdio (default)
  lightroom-mcp tools [name]       Print available tool schemas as JSON without connecting
  lightroom-mcp call <tool> [json] Call a tool with JSON object arguments (default {})
  lightroom-mcp install-plugin     Install bundled .lrplugin into Lightroom Modules folder
  lightroom-mcp --help | --version

ENV
  LIGHTROOM_MCP_REQUEST_PORT   plugin request port  (default 58763)
  LIGHTROOM_MCP_RESPONSE_PORT  plugin response port (default 58764)
  LIGHTROOM_MCP_TOOLSETS       core plus develop, masks, or all (default core)
  LIGHTROOM_MCP_READ_ONLY      hide and refuse writes: true/1 or false/0 (default false)
  LIGHTROOM_MCP_TOKEN_PATH     auth token file      (default ~/.config/lightroom-mcp/token)
`;

export function parseCli(argv: string[]): ParsedCli {
  const args = argv.slice(2);
  if (args.length === 0) return { command: "stdio" };

  const first = args[0];
  if (first === "--help" || first === "-h") return { command: "help" };
  if (first === "--version" || first === "-v") return { command: "version" };

  if (first === "stdio") return { command: "stdio" };
  if (first === "install-plugin") return { command: "install-plugin" };
  if (first === "tools") {
    if (args.length > 2) throw new Error("Usage: lightroom-mcp tools [name]");
    return args.length === 2 ? { command: "tools", name: args[1] } : { command: "tools" };
  }
  if (first === "call") {
    if (args.length > 3) throw new Error("Usage: lightroom-mcp call <tool> [json]");
    const name = args[1];
    if (!name?.trim()) throw new Error("A tool name is required. Usage: lightroom-mcp call <tool> [json]");
    let params: unknown;
    try {
      params = JSON.parse(args[2] ?? "{}");
    } catch {
      throw new Error("Tool arguments must be valid JSON.");
    }
    if (params === null || typeof params !== "object" || Array.isArray(params)) {
      throw new Error("Tool arguments must be a JSON object.");
    }
    return { command: "call", name, args: params as Record<string, unknown> };
  }

  throw new Error(`Unknown command: ${first}\n\n${HELP}`);
}

export function helpText(): string {
  return HELP;
}
