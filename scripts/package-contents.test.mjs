import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverDir = path.join(repoRoot, "server");

test("the npm package carries the Lightroom plug-in and the bundled skill, and declares the skill for pi", () => {
  execFileSync(process.execPath, [path.join(serverDir, "scripts", "stage-package.mjs")]);
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const [packed] = JSON.parse(execFileSync(npm, ["pack", "--dry-run", "--json", "--ignore-scripts"], { cwd: serverDir, encoding: "utf8", shell: process.platform === "win32" }));
  const files = new Set(packed.files.map((entry) => entry.path));
  const skillFiles = fs.readdirSync(path.join(repoRoot, "skills", "lightroom-agent"), { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.posix.join("skills/lightroom-agent", path.relative(path.join(repoRoot, "skills", "lightroom-agent"), path.join(entry.parentPath, entry.name)).split(path.sep).join("/")));

  assert.ok(files.has("LightroomAgent.lrplugin/Info.lua"));
  for (const file of skillFiles) assert.ok(files.has(file), `${file} is not in the package`);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(serverDir, "package.json"), "utf8")).pi, { skills: ["./skills"] });
});
