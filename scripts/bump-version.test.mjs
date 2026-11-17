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

const editText = (root, file, change) => fs.writeFileSync(path.join(root, file), change(fs.readFileSync(path.join(root, file), "utf8")));

const drifts = [
  ["a manifest version", ".claude-plugin/plugin.json", (root, file) => editJson(root, file, (json) => { json.version = "9.9.9"; })],
  ["the Agent Plugins manifest version", "plugin.json", (root, file) => editJson(root, file, (json) => { json.version = "9.9.9"; })],
  ["a package version in the registry entry", "server.json", (root, file) => editJson(root, file, (json) => { json.packages[0].version = "9.9.9"; })],
  ["the root package version in the lock file", "server/package-lock.json", (root, file) => editJson(root, file, (json) => { json.packages[""].version = "9.9.9"; })],
  ["the plug-in contract version", "plugin/LightroomAgent.lrplugin/Contract.lua", (root, file) => editText(root, file, (text) => text.replace(/\n    VERSION = "[^"]+",\n/, '\n    VERSION = "9.9.9",\n'))],
  ["the pinned package in mcp.json", "mcp.json", (root, file) => editJson(root, file, (json) => { json.mcpServers.lightroom.args = ["-y", "lightroom-agent@9.9.9"]; })],
  ["the launch environment in the Claude Code manifest", ".claude-plugin/plugin.json", (root, file) => editJson(root, file, (json) => { json.mcpServers.lightroom.env = {}; })],
  ["the launch command in the Claude Code manifest", ".claude-plugin/plugin.json", (root, file) => editJson(root, file, (json) => { json.mcpServers.lightroom.command = "node"; })],
  ["a version on a marketplace entry", ".agents/plugins/marketplace.json", (root, file) => editJson(root, file, (json) => { json.plugins[0].version = "9.9.9"; })],
  ["the Agent Plugins manifest description", "plugin.json", (root, file) => editJson(root, file, (json) => { json.description = "stale"; })],
  ["the Claude Desktop bundle description", "mcpb/manifest.json", (root, file) => editJson(root, file, (json) => { json.description = "stale"; })],
  ["the Claude marketplace description", ".claude-plugin/marketplace.json", (root, file) => editJson(root, file, (json) => { json.description = "stale"; })],
  ["the Claude marketplace entry description", ".claude-plugin/marketplace.json", (root, file) => editJson(root, file, (json) => { json.plugins[0].description = "stale"; })],
  ["the Claude Code manifest author", ".claude-plugin/plugin.json", (root, file) => editJson(root, file, (json) => { json.author = { name: "Marcin Skalski" }; })],
  ["the Claude Desktop bundle author", "mcpb/manifest.json", (root, file) => editJson(root, file, (json) => { json.author = { name: "Marcin Skalski" }; })],
];
for (const [what, file, change] of drifts) {
  test(`--check fails naming ${file} when ${what} differs`, () => {
    const root = copyOfRepo();
    change(root, file);
    const result = run(root, "--check");
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(file.replaceAll(".", "\\.")));
  });
}

test("a bump writes the version, the package's description and author, and the plug-in's numeric core to every source", () => {
  const root = copyOfRepo();
  editJson(root, "server/package.json", (json) => { json.description = "A new description."; json.author = "someone-new"; });
  const bumped = run(root, "9.8.7-rc.1");
  assert.equal(bumped.status, 0, bumped.stderr);
  assert.equal(run(root, "--check").status, 0);
  for (const file of ["server/package.json", "server.json", "server/package-lock.json", "plugin.json", ".claude-plugin/plugin.json", "mcpb/manifest.json"]) {
    assert.equal(readJson(root, file).version, "9.8.7-rc.1", file);
  }
  assert.deepEqual(readJson(root, "server.json").packages.map((pkg) => pkg.version), ["9.8.7-rc.1"]);
  assert.equal(readJson(root, "server/package-lock.json").packages[""].version, "9.8.7-rc.1");
  for (const file of ["mcp.json", ".claude-plugin/plugin.json"]) {
    assert.deepEqual(readJson(root, file).mcpServers.lightroom.args, ["-y", "lightroom-agent@9.8.7-rc.1"], file);
  }
  assert.match(fs.readFileSync(path.join(root, "server/src/version.ts"), "utf8"), /export const VERSION = "9\.8\.7-rc\.1";/);
  assert.match(fs.readFileSync(path.join(root, "plugin/LightroomAgent.lrplugin/Info.lua"), "utf8"), /VERSION = \{ major=9, minor=8, revision=7, build=0 \}/);
  assert.match(fs.readFileSync(path.join(root, "plugin/LightroomAgent.lrplugin/Contract.lua"), "utf8"), /\n    VERSION = "9\.8\.7-rc\.1",\n/);
  for (const file of ["plugin.json", ".claude-plugin/plugin.json", "mcpb/manifest.json", ".claude-plugin/marketplace.json"]) {
    assert.equal(readJson(root, file).description, "A new description.", file);
  }
  assert.equal(readJson(root, ".claude-plugin/marketplace.json").plugins[0].description, "A new description.");
  for (const file of ["plugin.json", ".claude-plugin/plugin.json", "mcpb/manifest.json"]) {
    assert.deepEqual(readJson(root, file).author, { name: "someone-new" }, file);
  }
});

test("a level bump from a prerelease is refused", () => {
  const root = copyOfRepo();
  run(root, "9.8.7-rc.1");
  const result = run(root, "--bump=minor");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /prerelease/);
});
