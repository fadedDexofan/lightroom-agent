import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const VERSIONED_FILES = [
  "scripts/bump-version.mjs",
  "server/package.json",
  "server/package-lock.json",
  "server/src/version.ts",
  "server.json",
  "mcpb/manifest.json",
  "plugin.json",
  "mcp.json",
  ".claude-plugin/plugin.json",
  ".claude-plugin/marketplace.json",
  ".agents/plugins/marketplace.json",
  "gemini-extension.json",
  "plugin/LightroomAgent.lrplugin/Info.lua",
  "plugin/LightroomAgent.lrplugin/Contract.lua",
];

function copyOfRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bump-version-"));
  for (const file of VERSIONED_FILES) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.copyFileSync(path.join(repoRoot, file), path.join(root, file));
  }
  return root;
}

const run = (root, ...args) => spawnSync(process.execPath, [path.join(root, "scripts", "bump-version.mjs"), ...args], { encoding: "utf8" });
const readJson = (root, file) => JSON.parse(fs.readFileSync(path.join(root, file), "utf8"));
const editJson = (root, file, change) => {
  const json = readJson(root, file);
  change(json);
  fs.writeFileSync(path.join(root, file), JSON.stringify(json, null, 2) + "\n");
};

test("the repository's version sources and launch lines agree", () => {
  const result = run(copyOfRepo(), "--check");
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

const drifts = [
  ["a manifest version", ".claude-plugin/plugin.json", (json) => { json.version = "9.9.9"; }],
  ["the Agent Plugins manifest version", "plugin.json", (json) => { json.version = "9.9.9"; }],
  ["the pinned package in mcp.json", "mcp.json", (json) => { json.mcpServers.lightroom.args = ["-y", "lightroom-agent@9.9.9"]; }],
  ["the launch environment in gemini-extension.json", "gemini-extension.json", (json) => { json.mcpServers.lightroom.env = {}; }],
  ["the launch command in the Claude Code manifest", ".claude-plugin/plugin.json", (json) => { json.mcpServers.lightroom.command = "node"; }],
  ["a version on a marketplace entry", ".agents/plugins/marketplace.json", (json) => { json.plugins[0].version = "9.9.9"; }],
];
for (const [what, file, change] of drifts) {
  test(`--check fails naming ${file} when ${what} differs`, () => {
    const root = copyOfRepo();
    editJson(root, file, change);
    const result = run(root, "--check");
    assert.equal(result.status, 1);
    assert.match(result.stdout + result.stderr, new RegExp(file.replaceAll(".", "\\.")));
  });
}

test("a prerelease version is written to every source and the plug-in gets its numeric core", () => {
  const root = copyOfRepo();
  const bumped = run(root, "0.1.0-rc.0");
  assert.equal(bumped.status, 0, bumped.stderr);
  assert.equal(run(root, "--check").status, 0);
  for (const file of ["server/package.json", "plugin.json", ".claude-plugin/plugin.json", "gemini-extension.json", "mcpb/manifest.json"]) {
    assert.equal(readJson(root, file).version, "0.1.0-rc.0", file);
  }
  assert.deepEqual(readJson(root, "mcp.json").mcpServers.lightroom.args, ["-y", "lightroom-agent@0.1.0-rc.0"]);
  assert.match(fs.readFileSync(path.join(root, "plugin/LightroomAgent.lrplugin/Info.lua"), "utf8"), /VERSION = \{ major=0, minor=1, revision=0, build=0 \}/);
});

test("the plug-in's generated contract carries the full version, written and checked like the rest", () => {
  const root = copyOfRepo();
  assert.equal(run(root, "0.2.0-rc.1").status, 0);
  const contract = path.join(root, "plugin/LightroomAgent.lrplugin/Contract.lua");
  assert.match(fs.readFileSync(contract, "utf8"), /\n    VERSION = "0\.2\.0-rc\.1",\n/);
  fs.writeFileSync(contract, fs.readFileSync(contract, "utf8").replace('VERSION = "0.2.0-rc.1"', 'VERSION = "9.9.9"'));
  const result = run(root, "--check");
  assert.equal(result.status, 1);
  assert.match(result.stdout + result.stderr, /Contract\.lua/);
});

test("a level bump from a prerelease is refused", () => {
  const root = copyOfRepo();
  run(root, "0.1.0-rc.0");
  const result = run(root, "--bump=minor");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /prerelease/);
});
