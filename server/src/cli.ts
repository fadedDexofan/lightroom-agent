export type ParsedCli =
  | { command: "stdio" | "install-plugin" | "help" | "version" }
  | { command: "tools"; name?: string }
  | { command: "call"; name: string; args: Record<string, unknown> };

const HELP = `lightroom-agent — MCP bridge and CLI for Adobe Lightroom Classic

USAGE
  lightroom-agent [stdio]            Run MCP over stdio (default)
  lightroom-agent tools [name]       Print available tool schemas as JSON without connecting
  lightroom-agent call <tool> [json] Call a tool with JSON object arguments (default {})
  lightroom-agent install-plugin     Install or replace the bundled plug-in where Lightroom has it (else Modules)
  lightroom-agent --help | --version

ENV
  LIGHTROOM_AGENT_REQUEST_PORT   plugin request port  (default 58763)
  LIGHTROOM_AGENT_RESPONSE_PORT  plugin response port (default 58764)
  LIGHTROOM_AGENT_TOOLSETS       core plus develop, masks, or all (default core)
  LIGHTROOM_AGENT_READ_ONLY      hide and refuse writes: true/1 or false/0 (default false)
  LIGHTROOM_AGENT_TOKEN_PATH     auth token file      (default ~/.config/lightroom-agent/token)
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
    if (args.length > 2) throw new Error("Usage: lightroom-agent tools [name]");
    return args.length === 2 ? { command: "tools", name: args[1] } : { command: "tools" };
  }
  if (first === "call") {
    if (args.length > 3) throw new Error("Usage: lightroom-agent call <tool> [json]");
    const name = args[1];
    if (!name?.trim()) throw new Error("A tool name is required. Usage: lightroom-agent call <tool> [json]");
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
