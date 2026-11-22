import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "ci-changes.mjs");

const classify = (...files) =>
  spawnSync(process.execPath, [script], { input: files.join("\n"), encoding: "utf8" }).stdout;

test("a change made only of documentation needs no build or test", () => {
  assert.equal(
    classify(
      "README.md",
      "README.ru.md",
      "RELEASE_NOTES.md",
      "CLAUDE.md",
      "GLOSSARY.md",
      "docs/reference.md",
      "docs/adr/0001-one-result-envelope.md",
      "docs/assets/demo-after.jpg",
      ".github/ISSUE_TEMPLATE/bug.yml",
      ".github/pull_request_template.md",
    ),
    "code=false\n",
  );
});

test("any file outside the documentation needs the build and tests", () => {
  for (const file of [
    "skills/lightroom-agent/SKILL.md",
    "server/README.md",
    "plugin/LightroomAgent.lrplugin/Info.lua",
    "codex/skills/lightroom-agent/SKILL.md",
    ".github/workflows/ci.yml",
    "scripts/ci-changes.mjs",
    ".mise.toml",
    "LICENSE",
  ]) {
    assert.equal(classify("README.md", file), "code=true\n", file);
  }
});

test("a file renamed into the documentation still counts under its old path", () => {
  assert.equal(classify("docs/moved.md", "server/src/moved.ts"), "code=true\n");
});

test("an empty or unreadable file list needs the build and tests", () => {
  assert.equal(classify(), "code=true\n");
  assert.equal(classify("", "  "), "code=true\n");
});
