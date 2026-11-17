import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function tree({ version, notes }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "release-"));
  fs.mkdirSync(path.join(root, "scripts"));
  fs.mkdirSync(path.join(root, "server"));
  fs.copyFileSync(path.join(repoRoot, "scripts", "release.mjs"), path.join(root, "scripts", "release.mjs"));
  fs.writeFileSync(path.join(root, "server", "package.json"), JSON.stringify({ name: "lightroom-agent", version }));
  fs.writeFileSync(path.join(root, "RELEASE_NOTES.md"), notes);
  return root;
}

const run = (root, ...args) => spawnSync(process.execPath, [path.join(root, "scripts", "release.mjs"), ...args], { encoding: "utf8" });

const NOTES = [
  "# lightroom-agent 0.2.0",
  "",
  "- Later change.",
  "",
  "# lightroom-agent 0.1.0",
  "",
  "- First release.",
  "  Details on a second line.",
  "",
  "# Upstream history",
  "",
  "- Not ours.",
  "",
].join("\n");

test("info names the version, whether it is a prerelease and its npm dist-tag", () => {
  assert.equal(run(tree({ version: "0.1.0", notes: NOTES }), "info").stdout, "version=0.1.0\ntag=v0.1.0\nprerelease=false\nnpm_tag=latest\n");
  assert.equal(run(tree({ version: "0.1.0-rc.1", notes: NOTES }), "info").stdout, "version=0.1.0-rc.1\ntag=v0.1.0-rc.1\nprerelease=true\nnpm_tag=next\n");
});

test("info refuses a tag that is not v and the package version", () => {
  const root = tree({ version: "0.1.0", notes: NOTES });
  assert.equal(run(root, "info", "--tag", "v0.1.0").status, 0);
  const mismatched = run(root, "info", "--tag", "v0.1.1");
  assert.equal(mismatched.status, 1);
  assert.match(mismatched.stderr, /tag v0\.1\.1 does not match the package version 0\.1\.0/);
  assert.equal(run(root, "info", "--tag", "0.1.0").status, 1);
});

test("notes prints the version's section without its heading", () => {
  const notes = run(tree({ version: "0.1.0", notes: NOTES }), "notes", "0.1.0");
  assert.equal(notes.status, 0, notes.stderr);
  assert.equal(notes.stdout, "- First release.\n  Details on a second line.\n");
});

test("notes refuses a version without a section, and falls back to the unreleased one only when allowed", () => {
  const root = tree({ version: "0.3.0", notes: `# lightroom-agent (unreleased)\n\n- Pending.\n\n${NOTES}` });
  const missing = run(root, "notes", "0.3.0");
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /no section "# lightroom-agent 0\.3\.0"/);
  const fallback = run(root, "notes", "0.3.0", "--allow-unreleased");
  assert.equal(fallback.status, 0);
  assert.equal(fallback.stdout, "- Pending.\n");
  assert.match(fallback.stderr, /# lightroom-agent \(unreleased\)/);
});
