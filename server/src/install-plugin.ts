import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PLUGIN_FOLDER = "LightroomAgent.lrplugin";
const UPSTREAM_PLUGIN_FOLDER = "LightroomMCP.lrplugin";

export type InstallResult =
  | { status: "installed" | "current"; destination: string }
  | { status: "replaced"; destination: string; from: string | null; to: string | null }
  | { status: "foreign"; destination: string; toolkitId: string | null }
  | { status: "conflict"; conflicting: string };

const TOOLKIT_ID = /LrToolkitIdentifier\s*=\s*['"]([^'"]+)['"]/;
const CONTRACT_VERSION = /\n    VERSION = "([^"]+)",\n/;

export function lightroomModulesDir(): string {
  if (process.platform === "darwin") {
    return path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Adobe",
      "Lightroom",
      "Modules",
    );
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Modules");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Modules");
}

export function lightroomPluginsDir(): string {
  if (process.platform === "darwin") {
    return path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Adobe",
      "Lightroom",
      "Plugins",
    );
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Plugins");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Plugins");
}

function installedBundle(folder: string): string | null {
  const targets = [path.join(lightroomModulesDir(), folder), path.join(lightroomPluginsDir(), folder)];
  return targets.find((p) => {
    try {
      return fs.statSync(path.join(p, "Info.lua")).isFile();
    } catch {
      return false;
    }
  }) ?? null;
}

function readMatch(file: string, pattern: RegExp): string | null {
  try {
    return pattern.exec(fs.readFileSync(file, "utf8"))?.[1] ?? null;
  } catch {
    return null;
  }
}

function identityOf(bundle: string): { toolkitId: string | null; version: string | null } {
  return {
    toolkitId: readMatch(path.join(bundle, "Info.lua"), TOOLKIT_ID),
    version: readMatch(path.join(bundle, "Contract.lua"), CONTRACT_VERSION),
  };
}

export function describeInstall(result: InstallResult): string {
  switch (result.status) {
    case "installed":
      return `installed ${result.destination}; restart Lightroom to load it`;
    case "replaced":
      return `replaced ${result.destination} (version ${result.from ?? "unknown"} → ${result.to ?? "unknown"}); `
        + "restart Lightroom to load it";
    case "current":
      return `${result.destination} is already this version`;
    case "foreign":
      return `${result.destination} holds another plug-in (${result.toolkitId ?? "no toolkit id"}) and was left alone. `
        + "Remove it, then install again.";
    case "conflict":
      return `The installed ${result.conflicting} binds the same ports. Quit Lightroom, remove that folder, then install again.`;
  }
}

export function findBundledPlugin(startDir: string): string | null {
  const candidates = [
    path.join(startDir, PLUGIN_FOLDER),
    path.join(startDir, "..", PLUGIN_FOLDER),
    path.join(startDir, "..", "..", PLUGIN_FOLDER),
    path.join(startDir, "..", "..", "..", PLUGIN_FOLDER),
    path.join(startDir, "..", "plugin", PLUGIN_FOLDER),
    path.join(startDir, "..", "..", "plugin", PLUGIN_FOLDER),
    path.join(startDir, "..", "..", "..", "plugin", PLUGIN_FOLDER),
  ];
  return firstValidPlugin(candidates);
}

// Explicit `install-plugin` only: the cwd is attacker-influenced when an MCP
// host starts the server inside an arbitrary project, so never auto-install it.
export function findPluginInCwd(): string | null {
  return firstValidPlugin([path.join(process.cwd(), PLUGIN_FOLDER)]);
}

function firstValidPlugin(candidates: string[]): string | null {
  for (const c of candidates) {
    try {
      const st = fs.statSync(c);
      if (st.isDirectory() && fs.existsSync(path.join(c, "Info.lua"))) {
        return path.resolve(c);
      }
    } catch {
      // not present, keep looking
    }
  }
  return null;
}

export function installPlugin(opts: { source: string; destDir?: string }): InstallResult {
  const conflicting = installedBundle(UPSTREAM_PLUGIN_FOLDER);
  if (conflicting) return { status: "conflict", conflicting };
  const destination = opts.destDir !== undefined
    ? path.join(opts.destDir, PLUGIN_FOLDER)
    : installedBundle(PLUGIN_FOLDER) ?? path.join(lightroomModulesDir(), PLUGIN_FOLDER);
  if (!fs.existsSync(destination)) {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    copyDirRecursive(opts.source, destination);
    return { status: "installed", destination };
  }
  const installed = identityOf(destination);
  const bundled = identityOf(opts.source);
  if (installed.toolkitId !== bundled.toolkitId) return { status: "foreign", destination, toolkitId: installed.toolkitId };
  if (installed.version === bundled.version) return { status: "current", destination };
  fs.rmSync(destination, { recursive: true, force: true });
  copyDirRecursive(opts.source, destination);
  return { status: "replaced", destination, from: installed.version, to: bundled.version };
}

export function ensurePluginInstalled(startDir: string, log: (msg: string) => void): void {
  const source = findBundledPlugin(startDir);
  if (!source) return;
  try {
    const result = installPlugin({ source });
    if (result.status !== "current") log(`[install-plugin] ${describeInstall(result)}`);
  } catch (err) {
    log(`[install-plugin] failed: ${(err as Error).message}`);
  }
}

function copyDirRecursive(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDirRecursive(s, d);
    else if (entry.isSymbolicLink()) {
      const link = fs.readlinkSync(s);
      try {
        fs.symlinkSync(link, d);
      } catch {
        fs.copyFileSync(s, d);
      }
    } else fs.copyFileSync(s, d);
  }
}
