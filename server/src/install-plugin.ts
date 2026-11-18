import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sameIdentity, type BuildIdentity } from "./build-identity.js";

const PLUGIN_FOLDER = "LightroomAgent.lrplugin";
const UPSTREAM_PLUGIN_FOLDER = "LightroomMCP.lrplugin";

export type InstallResult =
  | { status: "installed" | "current" | "busy"; destination: string }
  | { status: "replaced"; destination: string; from: BuildIdentity; to: BuildIdentity }
  | { status: "foreign"; destination: string; toolkitId: string | null }
  | { status: "conflict"; conflicting: string };

const TOOLKIT_ID = /LrToolkitIdentifier\s*=\s*['"]([^'"]+)['"]/;
const CONTRACT_VERSION = /\n    VERSION = "([^"]+)",\n/;
const CONTRACT_BUILD = /\n    BUILD = "([^"]+)",\n/;

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
    return pattern.exec(fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n"))?.[1] ?? null;
  } catch {
    return null;
  }
}

function identityOf(bundle: string): BuildIdentity & { toolkitId: string | null } {
  return {
    toolkitId: readMatch(path.join(bundle, "Info.lua"), TOOLKIT_ID),
    version: readMatch(path.join(bundle, "Contract.lua"), CONTRACT_VERSION),
    build: readMatch(path.join(bundle, "Contract.lua"), CONTRACT_BUILD),
  };
}

function bundleIdentity(bundle: string): BuildIdentity {
  const { version, build } = identityOf(bundle);
  return { version, build };
}

function describeChange(from: BuildIdentity, to: BuildIdentity): string {
  if (from.version !== to.version) return `version ${from.version ?? "unknown"} → ${to.version ?? "unknown"}`;
  return `version ${to.version ?? "unknown"}, build ${from.build ?? "unknown"} → ${to.build ?? "unknown"}`;
}

export function describeInstall(result: InstallResult): string {
  switch (result.status) {
    case "installed":
      return `installed ${result.destination}; restart Lightroom to load it`;
    case "replaced":
      return `replaced ${result.destination} (${describeChange(result.from, result.to)}); restart Lightroom to load it`;
    case "current":
      return `${result.destination} is already this build`;
    case "foreign":
      return `${result.destination} holds another plug-in (${result.toolkitId ?? "no toolkit id"}) and was left alone. `
        + "Remove it, then install again.";
    case "conflict":
      return `The installed ${result.conflicting} binds the same ports. Quit Lightroom, remove that folder, then install again.`;
    case "busy":
      return `Another lightroom-agent server is installing ${result.destination} right now; it was left to that server.`;
  }
}

export type BundleLayout = "checkout" | "package";

function isRegularFile(file: string): boolean {
  try {
    return fs.lstatSync(file).isFile();
  } catch {
    return false;
  }
}

export function isBundle(dir: string): boolean {
  return isRegularFile(path.join(dir, "Info.lua")) && isRegularFile(path.join(dir, "Contract.lua"));
}

export function findBundledPlugin(distDir: string): { source: string; layout: BundleLayout } | null {
  const candidates: Array<[string, BundleLayout]> = [
    [path.join(distDir, "..", "..", "plugin", PLUGIN_FOLDER), "checkout"],
    [path.join(distDir, "..", PLUGIN_FOLDER), "package"],
    [path.join(distDir, "..", "..", PLUGIN_FOLDER), "package"],
  ];
  const found = candidates.find(([dir]) => isBundle(dir));
  return found ? { source: path.resolve(found[0]), layout: found[1] } : null;
}

const STALE_LOCK_MS = 5 * 60 * 1000;

function lockOf(): string {
  return path.join(lightroomModulesDir(), `${PLUGIN_FOLDER}.lock`);
}

function takeLock(lock: string): boolean {
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  try {
    fs.mkdirSync(lock);
    return true;
  } catch {
    if (Date.now() - fs.statSync(lock).mtimeMs < STALE_LOCK_MS) return false;
    fs.rmSync(lock, { recursive: true, force: true });
    return takeLock(lock);
  }
}

function asideOf(destination: string): string {
  return `${destination}.replaced`;
}

function recoverInterruptedSwaps(): void {
  for (const dir of [lightroomModulesDir(), lightroomPluginsDir()]) {
    const destination = path.join(dir, PLUGIN_FOLDER);
    if (!fs.existsSync(destination) && fs.existsSync(path.join(asideOf(destination), "Info.lua"))) {
      fs.renameSync(asideOf(destination), destination);
    }
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      if (name.startsWith(`${PLUGIN_FOLDER}.installing-`) || name === `${PLUGIN_FOLDER}.replaced`) {
        fs.rmSync(path.join(dir, name), { recursive: true, force: true });
      }
    }
  }
}

export function installPlugin(opts: { source: string }): InstallResult {
  const conflicting = installedBundle(UPSTREAM_PLUGIN_FOLDER);
  if (conflicting) return { status: "conflict", conflicting };
  const lock = lockOf();
  if (!takeLock(lock)) {
    return { status: "busy", destination: installedBundle(PLUGIN_FOLDER) ?? path.join(lightroomModulesDir(), PLUGIN_FOLDER) };
  }
  try {
    recoverInterruptedSwaps();
    return installLocked(opts.source);
  } finally {
    fs.rmSync(lock, { recursive: true, force: true });
  }
}

function installLocked(source: string): InstallResult {
  const destination = installedBundle(PLUGIN_FOLDER) ?? path.join(lightroomModulesDir(), PLUGIN_FOLDER);
  if (!fs.existsSync(destination)) {
    copyIntoPlace(source, destination);
    return { status: "installed", destination };
  }
  const installed = identityOf(destination);
  const bundled = identityOf(source);
  if (installed.toolkitId !== bundled.toolkitId) return { status: "foreign", destination, toolkitId: installed.toolkitId };
  if (sameIdentity(bundleIdentity(destination), bundleIdentity(source))) return { status: "current", destination };
  copyIntoPlace(source, destination);
  return {
    status: "replaced",
    destination,
    from: { version: installed.version, build: installed.build },
    to: { version: bundled.version, build: bundled.build },
  };
}

function copyIntoPlace(source: string, destination: string): void {
  const staging = `${destination}.installing-${process.pid}-${Date.now()}`;
  try {
    copyDirRecursive(source, staging);
  } catch (err) {
    fs.rmSync(staging, { recursive: true, force: true });
    throw err;
  }
  const replacing = fs.existsSync(destination);
  if (replacing) fs.renameSync(destination, asideOf(destination));
  fs.renameSync(staging, destination);
  if (replacing) fs.rmSync(asideOf(destination), { recursive: true, force: true });
}

export function ensurePluginInstalled(startDir: string, log: (msg: string) => void): void {
  const source = findBundledPlugin(startDir)?.source;
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
    else if (entry.isFile()) fs.copyFileSync(s, d);
  }
}
