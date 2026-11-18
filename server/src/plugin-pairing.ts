import fs from "node:fs";
import path from "node:path";
import { expectedIdentity, renderContractLua, type PluginIdentity } from "./contract-lua.js";
import { findBundledPlugin, isBundle, type BundleLayout } from "./install-plugin.js";
import { VERSION } from "./version.js";

export type Pairing =
  | { kind: "paired"; plugin: PluginIdentity; source: string; layout: BundleLayout }
  | { kind: "unpaired"; reason: string };

export type Paired = Extract<Pairing, { kind: "paired" }>;

export const PLUGIN_BUILD_RECORD = "plugin-build.json";

export const NO_BUNDLED_PLUGIN = "This server has no bundled Lightroom plug-in; reinstall lightroom-agent.";

const MISMATCH: Record<BundleLayout, string> = {
  checkout: "This server's build does not match its plug-in folder; rebuild it (npm --prefix server run build in the "
    + "checkout), then restart your client.",
  package: "This server's installation is damaged; reinstall lightroom-agent.",
};

export class PairingLost extends Error {}

export function validateBundle(dir: string, expectedBuild: string): boolean {
  if (!isBundle(dir)) return false;
  const contract = fs.readFileSync(path.join(dir, "Contract.lua"), "utf8").replace(/\r\n/g, "\n");
  const observed = expectedIdentity(dir);
  return observed.build === expectedBuild && contract === renderContractLua(observed);
}

function recordedBuild(distDir: string): string | null {
  try {
    const record: unknown = JSON.parse(fs.readFileSync(path.join(distDir, PLUGIN_BUILD_RECORD), "utf8"));
    const build = typeof record === "object" && record !== null ? (record as { build?: unknown }).build : undefined;
    return typeof build === "string" ? build : null;
  } catch {
    return null;
  }
}

function validates(source: string, build: string | null): build is string {
  try {
    return build !== null && validateBundle(source, build);
  } catch {
    return false;
  }
}

export function pairingOf(distDir: string): Pairing {
  const bundle = findBundledPlugin(distDir);
  if (bundle === null) return { kind: "unpaired", reason: NO_BUNDLED_PLUGIN };
  const build = recordedBuild(distDir);
  if (!validates(bundle.source, build)) return { kind: "unpaired", reason: MISMATCH[bundle.layout] };
  return { kind: "paired", plugin: { version: VERSION, build }, source: bundle.source, layout: bundle.layout };
}

export function confirmPairing(pairing: Paired): void {
  if (!validateBundle(pairing.source, pairing.plugin.build)) throw new PairingLost(MISMATCH[pairing.layout]);
}
