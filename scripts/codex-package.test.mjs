import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const codexRoot = path.join(repoRoot, "codex");
const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const marketplace = readJson(path.join(repoRoot, ".agents", "plugins", "marketplace.json"));
const entry = marketplace.plugins.find((plugin) => plugin.name === "lightroom-agent");

function entriesUnder(root) {
  return fs.readdirSync(root, { recursive: true, withFileTypes: true }).map((dirent) => ({
    dirent,
    relative: path.relative(root, path.join(dirent.parentPath, dirent.name)).split(path.sep).join("/"),
  }));
}

function filesUnder(root) {
  return new Map(
    entriesUnder(root)
      .filter(({ dirent }) => dirent.isFile())
      .map(({ relative }) => [relative, fs.readFileSync(path.join(root, relative))]),
  );
}

test("Codex installs lightroom-agent from the local codex/ folder", () => {
  assert.deepEqual(entry.source, { source: "local", path: "./codex" });
});

test("the Codex manifest names the marketplace entry's plugin", () => {
  assert.equal(readJson(path.join(codexRoot, ".codex-plugin", "plugin.json")).name, entry.name);
});

test("no Agent Plugins manifest is in the Codex package", () => {
  const files = entriesUnder(codexRoot)
    .filter(({ dirent }) => dirent.isFile())
    .map(({ relative }) => relative);
  assert.deepEqual(
    files.filter((file) => path.posix.basename(file) === "plugin.json"),
    [".codex-plugin/plugin.json"],
  );
  const agentPlugins = files
    .filter((file) => file.endsWith(".json"))
    .filter((file) =>
      String(readJson(path.join(codexRoot, file)).$schema ?? "").startsWith("https://agent-plugins.org/schemas/"),
    );
  assert.deepEqual(agentPlugins, []);
});

test("the Codex package holds no symlink", () => {
  assert.deepEqual(
    entriesUnder(codexRoot)
      .filter(({ dirent }) => dirent.isSymbolicLink())
      .map(({ relative }) => relative),
    [],
  );
});

test("the Codex package carries the bundled skill byte for byte", () => {
  const source = filesUnder(path.join(repoRoot, "skills", "lightroom-agent"));
  const mirror = filesUnder(path.join(codexRoot, "skills", "lightroom-agent"));
  assert.deepEqual([...mirror.keys()].sort(), [...source.keys()].sort());
  for (const [file, bytes] of source) assert.ok(bytes.equals(mirror.get(file)), file);
});
