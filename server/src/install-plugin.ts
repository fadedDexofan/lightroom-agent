import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { compareVersions, treeDigest, type BuildIdentity } from "./build-identity.js";
import { PairingLost, PLUGIN_FOLDER, validateBundle, type Paired } from "./plugin-pairing.js";

const CONFLICTING_PLUGIN_FOLDER = "LightroomMCP.lrplugin";

export type InstallResult =
  | { status: "installed" | "current" | "repaired"; destination: string }
  | { status: "replaced"; destination: string; from: BuildIdentity; to: BuildIdentity }
  | { status: "foreign"; destination: string; toolkitId: string | null }
  | { status: "conflict"; conflicting: string }
  | { status: "invalid"; source: string };

export type InstallPlan =
  | { kind: "conflict"; conflicting: string }
  | { kind: "foreign"; destination: string; toolkitId: string | null }
  | { kind: "absent"; destination: string }
  | { kind: "same-build" | "older" | "newer" | "unordered"; destination: string; installed: BuildIdentity };

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

function describeChange(from: BuildIdentity, to: BuildIdentity): string {
  if (from.version !== to.version) {
    const older = compareVersions(from.version, to.version) === 1 ? ", older" : "";
    return `version ${from.version ?? "unknown"} → ${to.version ?? "unknown"}${older}`;
  }
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
    case "repaired":
      return `repaired the installed plug-in's files in ${result.destination}; restart Lightroom to load them`;
    case "invalid":
      return `refused: the bundled plug-in ${result.source} does not validate against this server's build, so nothing was installed`;
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

function standing(installed: BuildIdentity, own: Paired["plugin"]): "same-build" | "older" | "newer" | "unordered" {
  if (installed.build === own.build) return "same-build";
  const order = compareVersions(installed.version, own.version);
  if (order === null || order === 0) return "unordered";
  return order < 0 ? "older" : "newer";
}

function planInstall(pairing: Paired, recovering: boolean): InstallPlan {
  const conflicting = installedBundle(CONFLICTING_PLUGIN_FOLDER);
  if (conflicting) return { kind: "conflict", conflicting };
  if (recovering) recoverInterruptedSwaps();
  const destination = installedBundle(PLUGIN_FOLDER) ?? path.join(lightroomModulesDir(), PLUGIN_FOLDER);
  if (!fs.existsSync(destination)) return { kind: "absent", destination };
  const { toolkitId, ...installed } = identityOf(destination);
  if (toolkitId !== identityOf(pairing.source).toolkitId) return { kind: "foreign", destination, toolkitId };
  return { kind: standing(installed, pairing.plugin), destination, installed };
}

function installedRefusal(plan: { kind: "newer" | "unordered"; installed: BuildIdentity }, own: Paired["plugin"]): string {
  const leaves = "so this server leaves it alone and does not connect to Lightroom.";
  if (plan.kind === "newer") {
    return `Lightroom's installed plug-in is version ${plan.installed.version}, newer than this server's version ${own.version}, `
      + `${leaves} Update lightroom-agent in this client, or remove an outdated server entry, then restart the client.`;
  }
  return `Lightroom's installed plug-in is another build (installed: version ${plan.installed.version ?? "unknown"}, `
    + `build ${plan.installed.build ?? "unknown"}; this server's: version ${own.version}, build ${own.build}), ${leaves} `
    + "To use this build, quit the other clients, run this build's install-plugin, restart Lightroom, then start the clients again.";
}

function performInstall(pairing: Paired, plan: InstallPlan): InstallResult {
  if (plan.kind === "conflict") return { status: "conflict", conflicting: plan.conflicting };
  if (plan.kind === "foreign") return { status: "foreign", destination: plan.destination, toolkitId: plan.toolkitId };
  const { destination } = plan;
  const staging = `${destination}.installing-${process.pid}-${Date.now()}`;
  try {
    copyDirRecursive(pairing.source, staging);
    if (!validateBundle(staging, pairing.plugin.build)) return { status: "invalid", source: pairing.source };
    if (plan.kind === "absent") {
      fs.renameSync(staging, destination);
      return { status: "installed", destination };
    }
    if (sameFiles(destination, staging)) return { status: "current", destination };
    swapIntoPlace(staging, destination);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
  if (plan.kind === "same-build") return { status: "repaired", destination };
  return { status: "replaced", destination, from: plan.installed, to: pairing.plugin };
}

export function installPlugin(pairing: Paired): InstallResult {
  return performInstall(pairing, planInstall(pairing, true));
}

function sameFiles(installed: string, staged: string): boolean {
  const lua = (file: string) => file.endsWith(".lua");
  return treeDigest(installed, lua) === treeDigest(staged, lua);
}

function swapIntoPlace(staging: string, destination: string): void {
  const aside = asideOf(destination);
  fs.renameSync(destination, aside);
  try {
    fs.renameSync(staging, destination);
  } catch (err) {
    try {
      fs.renameSync(aside, destination);
    } catch {
      throw new Error(`${(err as Error).message}; the previous bundle stays at ${aside}`);
    }
    throw err;
  }
  fs.rmSync(aside, { recursive: true, force: true });
}

export function admitLeader(pairing: Paired, install: boolean, log: (msg: string) => void): void {
  let plan: InstallPlan;
  try {
    plan = planInstall(pairing, install);
  } catch (err) {
    log(`[install-plugin] failed: ${(err as Error).message}`);
    return;
  }
  if (plan.kind === "newer" || plan.kind === "unordered") {
    throw new PairingLost(installedRefusal({ kind: plan.kind, installed: plan.installed }, pairing.plugin));
  }
  if (!install) return;
  try {
    const result = performInstall(pairing, plan);
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
