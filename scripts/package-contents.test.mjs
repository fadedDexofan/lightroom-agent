import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverDir = path.join(repoRoot, "server");

const npm = (...args) => execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", args, { cwd: serverDir, encoding: "utf8", shell: process.platform === "win32" });

test("the npm package carries the Lightroom plug-in and the bundled skill, declares the skill for pi, and leaves no staged copy behind", () => {
  npm("run", "prepack");
  try {
    const [packed] = JSON.parse(npm("pack", "--dry-run", "--json", "--ignore-scripts"));
    const files = new Set(packed.files.map((entry) => entry.path));
    const skillFiles = fs.readdirSync(path.join(repoRoot, "skills", "lightroom-agent"), { recursive: true, withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => path.posix.join("skills/lightroom-agent", path.relative(path.join(repoRoot, "skills", "lightroom-agent"), path.join(entry.parentPath, entry.name)).split(path.sep).join("/")));

    assert.ok(files.has("LightroomAgent.lrplugin/Info.lua"));
    for (const file of skillFiles) assert.ok(files.has(file), `${file} is not in the package`);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(serverDir, "package.json"), "utf8")).pi, { skills: ["./skills"] });
  } finally {
    npm("run", "postpack");
  }
  for (const staged of ["LightroomAgent.lrplugin", "skills"]) assert.equal(fs.existsSync(path.join(serverDir, staged)), false, `server/${staged} is left behind`);
});

test("a local pack regenerates the contract before staging, so the packed BUILD matches the packed Lua", async () => {
  const contract = path.join(repoRoot, "plugin", "LightroomAgent.lrplugin", "Contract.lua");
  const original = fs.readFileSync(contract, "utf8");
  fs.writeFileSync(contract, original.replace(/BUILD = "[0-9a-f]{16}"/, 'BUILD = "0000000000000000"'));
  try {
    npm("run", "prepack");
    const staged = path.join(serverDir, "LightroomAgent.lrplugin");
    const { expectedIdentity } = await import(new URL("../server/dist/contract-lua.js", import.meta.url).href);
    const build = /\n    BUILD = "([0-9a-f]{16})",\n/.exec(fs.readFileSync(path.join(staged, "Contract.lua"), "utf8"))?.[1];
    assert.equal(build, expectedIdentity(staged).build);
  } finally {
    npm("run", "postpack");
    fs.writeFileSync(contract, original);
  }
});
