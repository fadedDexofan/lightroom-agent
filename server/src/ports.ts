export const DEFAULT_REQUEST_PORT = 58763;
export const DEFAULT_RESPONSE_PORT = 58764;

const REQUEST_PORT_ENV = "LIGHTROOM_AGENT_REQUEST_PORT";
const RESPONSE_PORT_ENV = "LIGHTROOM_AGENT_RESPONSE_PORT";

type PortDefaults = { readonly request: number; readonly response: number };

type DesktopManifest = {
  server: { mcp_config: { env: Record<string, string> } };
  user_config: Record<string, { default?: unknown }>;
};

type RegistryEntry = { packages: { environmentVariables?: { name: string; default?: string }[] }[] };

function parsePort(raw: string | undefined, fallback: number, name: string): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const trimmed = raw.trim();
  if (!/^[0-9]+$/.test(trimmed)) {
    throw new Error(`${name} must be a positive integer 1-65535, got "${raw}"`);
  }
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`${name} must be a positive integer 1-65535, got "${raw}"`);
  }
  return n;
}

export function requestPort(): number {
  return parsePort(process.env[REQUEST_PORT_ENV], DEFAULT_REQUEST_PORT, REQUEST_PORT_ENV);
}

export function responsePort(): number {
  return parsePort(process.env[RESPONSE_PORT_ENV], DEFAULT_RESPONSE_PORT, RESPONSE_PORT_ENV);
}

export function writePortDefaults(
  manifest: DesktopManifest,
  registry: RegistryEntry,
  defaults: PortDefaults = { request: DEFAULT_REQUEST_PORT, response: DEFAULT_RESPONSE_PORT },
): void {
  for (const [env, port] of [
    [REQUEST_PORT_ENV, defaults.request],
    [RESPONSE_PORT_ENV, defaults.response],
  ] as const) {
    const setting = /^\$\{user_config\.(\w+)\}$/.exec(manifest.server.mcp_config.env[env] ?? "")?.[1];
    const option = setting === undefined ? undefined : manifest.user_config[setting];
    if (option === undefined) throw new Error(`mcpb/manifest.json maps no user setting to ${env}`);
    option.default = String(port);
    const variables = registry.packages
      .flatMap((entry) => entry.environmentVariables ?? [])
      .filter((v) => v.name === env);
    if (variables.length === 0) throw new Error(`server.json declares no ${env}`);
    for (const variable of variables) variable.default = String(port);
  }
}
