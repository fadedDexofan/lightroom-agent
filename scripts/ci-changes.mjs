#!/usr/bin/env node
import fs from "node:fs";

const isDocs = (file) =>
  file.startsWith("docs/") ||
  (!file.includes("/") && file.endsWith(".md")) ||
  file.startsWith(".github/ISSUE_TEMPLATE/") ||
  file === ".github/pull_request_template.md";

const files = fs
  .readFileSync(0, "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line !== "");

process.stdout.write(`code=${files.length === 0 || !files.every(isDocs)}\n`);
