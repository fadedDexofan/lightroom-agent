import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const CONTRACT = [
  "return {",
  '    VERSION = "0.0.0",',
  "    DEFAULT_REQUEST_PORT = 1,",
  "    DEFAULT_RESPONSE_PORT = 2,",
  "}",
  "",
];

function probe(lineEnding) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "manual-test-"));
  const bundle = path.join(root, "plugin", "LightroomAgent.lrplugin");
  fs.mkdirSync(bundle, { recursive: true });
  fs.copyFileSync(path.join(repoRoot, "manual-test.mjs"), path.join(root, "manual-test.mjs"));
  fs.writeFileSync(path.join(bundle, "Contract.lua"), CONTRACT.join(lineEnding));
  const env = { ...process.env, LIGHTROOM_AGENT_TOKEN_PATH: path.join(root, "absent-token") };
  delete env.LIGHTROOM_AGENT_REQUEST_PORT;
  delete env.LIGHTROOM_AGENT_RESPONSE_PORT;
  try {
    return spawnSync(process.execPath, [path.join(root, "manual-test.mjs")], { encoding: "utf8", env });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

for (const [name, lineEnding] of [
  ["LF", "\n"],
  ["CRLF", "\r\n"],
]) {
  test(`reads the default ports from a ${name} Contract.lua before it needs the token`, () => {
    const result = probe(lineEnding);
    assert.equal(result.status, 1);
    assert.doesNotMatch(result.stderr, /has no DEFAULT_/);
    assert.match(result.stderr, /token read failed/);
  });
}
