import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { compareVersions, treeDigest, type BuildIdentity } from "./build-identity.js";
import { ADOBE_RAW_PROFILES, PROFILE_PRESET_GROUP } from "./lightroom-tables.js";
import { PairingLost, PLUGIN_FOLDER, validateBundle, type Paired } from "./plugin-pairing.js";

const CONFLICTING_PLUGIN_FOLDER = "LightroomMCP.lrplugin";

type Presets = { presets?: readonly string[]; foreignPresets?: readonly string[]; presetsError?: string };

export type InstallResult =
  | ({ status: "installed" | "current" | "repaired"; destination: string } & Presets)
  | ({ status: "replaced"; destination: string; from: BuildIdentity; to: BuildIdentity } & Presets)
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
    return path.join(os.homedir(), "Library", "Application Support", "Adobe", "Lightroom", "Modules");
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Modules");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Modules");
}

export function lightroomPluginsDir(): string {
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "Adobe", "Lightroom", "Plugins");
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Plugins");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Plugins");
}

export function profilePresetsDir(): string {
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "Adobe", "CameraRaw", "Settings");
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "CameraRaw", "Settings");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "CameraRaw", "Settings");
}

function xml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

function alt(tag: string, text: string): string {
  const item = text ? `<rdf:li xml:lang="x-default">${xml(text)}</rdf:li>` : `<rdf:li xml:lang="x-default"/>`;
  return `   <crs:${tag}>\n    <rdf:Alt>\n     ${item}\n    </rdf:Alt>\n   </crs:${tag}>\n`;
}

function profilePreset(profile: (typeof ADOBE_RAW_PROFILES)[number]): string {
  return (
    `<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.6-c140 79.160451, 2017/05/06-01:08:21        ">\n` +
    ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
    `  <rdf:Description rdf:about=""\n` +
    `    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"\n` +
    `   crs:PresetType="Normal"\n` +
    `   crs:Cluster=""\n` +
    `   crs:UUID="${profile.preset_uuid}"\n` +
    `   crs:SupportsAmount="False"\n` +
    `   crs:SupportsColor="True"\n` +
    `   crs:SupportsMonochrome="True"\n` +
    `   crs:SupportsHighDynamicRange="True"\n` +
    `   crs:SupportsNormalDynamicRange="True"\n` +
    `   crs:SupportsSceneReferred="True"\n` +
    `   crs:SupportsOutputReferred="True"\n` +
    `   crs:CameraModelRestriction=""\n` +
    `   crs:Copyright=""\n` +
    `   crs:ContactInfo=""\n` +
    `   crs:Version="12.3"\n` +
    `   crs:CameraProfile="${xml(profile.camera_profile)}"\n` +
    `   crs:HasSettings="True">\n` +
    alt("Name", profile.preset_name) +
    alt("ShortName", "") +
    alt("SortName", profile.preset_name) +
    alt("Group", PROFILE_PRESET_GROUP) +
    alt("Description", "") +
    `   <crs:Look>\n` +
    `    <rdf:Description\n` +
    `     crs:Name="${xml(profile.name)}"\n` +
    `     crs:Amount="1.000000"\n` +
    `     crs:UUID="${profile.look_uuid}"\n` +
    `     crs:SupportsAmount="false"\n` +
    `     crs:SupportsMonochrome="false"\n` +
    `     crs:SupportsOutputReferred="false"\n` +
    `     crs:Copyright="${xml(profile.copyright)}"\n` +
    `     crs:Stubbed="true">\n` +
    `    <crs:Group>\n     <rdf:Alt>\n      <rdf:li xml:lang="x-default">Profiles</rdf:li>\n     </rdf:Alt>\n    </crs:Group>\n` +
    `    </rdf:Description>\n` +
    `   </crs:Look>\n` +
    `  </rdf:Description>\n` +
    ` </rdf:RDF>\n` +
    `</x:xmpmeta>\n`
  );
}

type PresetPlan = { file: string; text: string; state: "current" | "write" | "foreign" };

function planPreset(file: string, text: string, marker: string): PresetPlan {
  let stat: fs.Stats;
  try {
    stat = fs.lstatSync(file);
  } catch {
    return { file, text, state: "write" };
  }
  if (!stat.isFile()) return { file, text, state: "foreign" };
  const existing = fs.readFileSync(file, "utf8");
  if (existing === text) return { file, text, state: "current" };
  return { file, text, state: existing.includes(marker) ? "write" : "foreign" };
}

function installProfilePresets(): Presets {
  const dir = profilePresetsDir();
  fs.mkdirSync(dir, { recursive: true });
  const plans = ADOBE_RAW_PROFILES.map((profile) =>
    planPreset(
      path.join(dir, `${profile.preset_name}.xmp`),
      profilePreset(profile),
      `crs:UUID="${profile.preset_uuid}"`,
    ),
  );
  const written: string[] = [];
  let presetsError: string | undefined;
  for (const plan of plans.filter((plan) => plan.state === "write")) {
    const staged = `${plan.file}.installing-${process.pid}-${Date.now()}`;
    try {
      fs.writeFileSync(staged, plan.text, { flag: "wx" });
      fs.renameSync(staged, plan.file);
      written.push(plan.file);
    } catch (err) {
      fs.rmSync(staged, { force: true });
      presetsError = `${path.basename(plan.file)}: ${(err as Error).message}`;
      break;
    }
  }
  const foreign = plans.filter((plan) => plan.state === "foreign").map((plan) => plan.file);
  return {
    ...(written.length > 0 ? { presets: written } : {}),
    ...(foreign.length > 0 ? { foreignPresets: foreign } : {}),
    ...(presetsError ? { presetsError } : {}),
  };
}

function withPresets<T extends InstallResult>(result: T): T {
  if (!["installed", "current", "repaired", "replaced"].includes(result.status)) return result;
  try {
    return { ...result, ...installProfilePresets() };
  } catch (err) {
    return { ...result, presetsError: (err as Error).message };
  }
}

function installedBundle(folder: string): string | null {
  const targets = [path.join(lightroomModulesDir(), folder), path.join(lightroomPluginsDir(), folder)];
  return (
    targets.find((p) => {
      try {
        return fs.statSync(path.join(p, "Info.lua")).isFile();
      } catch {
        return false;
      }
    }) ?? null
  );
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

function describePresets(result: InstallResult): string {
  if (!("status" in result) || !["installed", "current", "repaired", "replaced"].includes(result.status)) return "";
  const { presets, foreignPresets, presetsError } = result as Presets;
  const parts = [
    ...(presets?.length
      ? [
          `wrote the profile presets ${presets.map((file) => path.basename(file, ".xmp")).join(", ")}, which Lightroom registers when it starts`,
        ]
      : []),
    ...(foreignPresets ?? []).map(
      (file) => `left ${file}, which lightroom-agent did not write, so set_profile cannot use that profile`,
    ),
    ...(presetsError ? [`could not write the profile presets: ${presetsError}`] : []),
  ];
  return parts.map((part) => `; ${part}`).join("");
}

export function presetsIncomplete(result: InstallResult): boolean {
  const { presetsError, foreignPresets } = result as Presets;
  return presetsError !== undefined || (foreignPresets?.length ?? 0) > 0;
}

export function describeInstall(result: InstallResult): string {
  return describePlugin(result) + describePresets(result);
}

function describePlugin(result: InstallResult): string {
  switch (result.status) {
    case "installed":
      return `installed ${result.destination}; restart Lightroom to load it`;
    case "replaced":
      return `replaced ${result.destination} (${describeChange(result.from, result.to)}); restart Lightroom to load it`;
    case "current":
      return `${result.destination} is already this build`;
    case "foreign":
      return (
        `${result.destination} holds another plug-in (${result.toolkitId ?? "no toolkit id"}) and was left alone. ` +
        "Remove it, then install again."
      );
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

function installedRefusal(
  plan: { kind: "newer" | "unordered"; installed: BuildIdentity },
  own: Paired["plugin"],
): string {
  const leaves = "so this server leaves it alone and does not connect to Lightroom.";
  if (plan.kind === "newer") {
    return (
      `Lightroom's installed plug-in is version ${plan.installed.version}, newer than this server's version ${own.version}, ` +
      `${leaves} Update lightroom-agent in this client, or remove an outdated server entry, then restart the client.`
    );
  }
  return (
    `Lightroom's installed plug-in is another build (installed: version ${plan.installed.version ?? "unknown"}, ` +
    `build ${plan.installed.build ?? "unknown"}; this server's: version ${own.version}, build ${own.build}), ${leaves} ` +
    "To use this build, quit the other clients, run this build's install-plugin, restart Lightroom, then start the clients again."
  );
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
  return withPresets(performInstall(pairing, planInstall(pairing, true)));
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
    const result = withPresets(performInstall(pairing, plan));
    if (result.status !== "current" || describePresets(result) !== "")
      log(`[install-plugin] ${describeInstall(result)}`);
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
