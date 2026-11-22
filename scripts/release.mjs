#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const NOTES_TITLE = "lightroom-agent";
const UNRELEASED = `# ${NOTES_TITLE} (unreleased)`;

function fail(message) {
  console.error(`[release] ${message}`);
  process.exit(1);
}

function info(tag) {
  const { version } = JSON.parse(fs.readFileSync(path.join(repoRoot, "server", "package.json"), "utf8"));
  if (tag !== undefined && tag !== `v${version}`) fail(`tag ${tag} does not match the package version ${version}`);
  const prerelease = version.includes("-");
  process.stdout.write(
    `version=${version}\ntag=v${version}\nprerelease=${prerelease}\nnpm_tag=${prerelease ? "next" : "latest"}\n`,
  );
}

function section(lines, heading) {
  const start = lines.indexOf(heading);
  if (start === -1) return null;
  const end = lines.findIndex((line, index) => index > start && line.startsWith("# "));
  return lines
    .slice(start + 1, end === -1 ? lines.length : end)
    .join("\n")
    .trim();
}

function notes(version, allowUnreleased) {
  if (!version) fail("usage: release.mjs notes <version> [--allow-unreleased]");
  const lines = fs.readFileSync(path.join(repoRoot, "RELEASE_NOTES.md"), "utf8").replace(/\r\n/g, "\n").split("\n");
  const heading = `# ${NOTES_TITLE} ${version}`;
  let body = section(lines, heading);
  if (body === null && allowUnreleased) {
    body = section(lines, UNRELEASED);
    if (body !== null) console.error(`[release] no section "${heading}"; using "${UNRELEASED}" for a dry run`);
  }
  if (body === null) fail(`RELEASE_NOTES.md has no section "${heading}"`);
  process.stdout.write(`${body}\n`);
}

const [command, ...rest] = process.argv.slice(2);
const option = (name) => {
  const at = rest.indexOf(name);
  return at === -1 ? undefined : rest[at + 1];
};

if (command === "info") info(option("--tag"));
else if (command === "notes")
  notes(
    rest.find((arg) => !arg.startsWith("--")),
    rest.includes("--allow-unreleased"),
  );
else fail("usage: release.mjs info [--tag <tag>] | notes <version> [--allow-unreleased]");
