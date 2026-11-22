import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const EDITED_LUA = "PathForms.lua";
const EDIT = `\n-- packed edit ${process.pid}\n`;

const root = fs.mkdtempSync(path.join(os.tmpdir(), "package-contents-"));
const copy = path.join(root, "repo");
const unpacked = path.join(root, "unpacked");
let packed;

const npm = (cwd, ...args) =>
  execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", args, {
    cwd,
    encoding: "utf8",
    shell: process.platform === "win32",
  });

before(() => {
  const tracked = execFileSync("git", ["ls-files", "-z"], { cwd: repoRoot, encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
  for (const file of tracked) {
    const source = path.join(repoRoot, file);
    if (!fs.lstatSync(source, { throwIfNoEntry: false })?.isFile()) continue;
    fs.mkdirSync(path.dirname(path.join(copy, file)), { recursive: true });
    fs.copyFileSync(source, path.join(copy, file));
  }
  fs.symlinkSync(path.join(repoRoot, "server", "node_modules"), path.join(copy, "server", "node_modules"), "junction");
  fs.appendFileSync(path.join(copy, "plugin", "LightroomAgent.lrplugin", EDITED_LUA), EDIT);
  [packed] = JSON.parse(npm(path.join(copy, "server"), "pack", "--json", "--pack-destination", root));
  fs.mkdirSync(unpacked);
  execFileSync("tar", ["-xzf", path.join(root, packed.filename), "-C", unpacked]);
});

after(() => {
  fs.rmSync(root, { recursive: true, force: true });
});

test("the npm package carries the Lightroom plug-in and the bundled skill, declares the skill for pi, and leaves no staged copy behind", () => {
  const files = new Set(packed.files.map((entry) => entry.path));
  const skill = path.join(copy, "skills", "lightroom-agent");
  const skillFiles = fs
    .readdirSync(skill, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) =>
      path.posix.join(
        "skills/lightroom-agent",
        path.relative(skill, path.join(entry.parentPath, entry.name)).split(path.sep).join("/"),
      ),
    );

  assert.ok(files.has("LightroomAgent.lrplugin/Info.lua"));
  assert.ok(files.has("dist/plugin-build.json"));
  for (const file of skillFiles) assert.ok(files.has(file), `${file} is not in the package`);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(unpacked, "package", "package.json"), "utf8")).pi, {
    skills: ["./skills"],
  });
  for (const staged of ["LightroomAgent.lrplugin", "skills"]) {
    assert.equal(fs.existsSync(path.join(copy, "server", staged)), false, `server/${staged} is left behind`);
  }
});

test("the packed plug-in is the checkout's Lua with a contract and a build record rendered from it", async () => {
  const bundle = path.join(unpacked, "package", "LightroomAgent.lrplugin");
  const { expectedIdentity } = await import(pathToFileURL(path.join(copy, "server", "dist", "contract-lua.js")).href);
  const build = /\n    BUILD = "([0-9a-f]{16})",\n/.exec(
    fs.readFileSync(path.join(bundle, "Contract.lua"), "utf8"),
  )?.[1];
  const record = JSON.parse(fs.readFileSync(path.join(unpacked, "package", "dist", "plugin-build.json"), "utf8"));

  assert.ok(fs.readFileSync(path.join(bundle, EDITED_LUA), "utf8").endsWith(EDIT));
  assert.equal(build, expectedIdentity(bundle).build);
  assert.deepEqual(record, { build });
});
