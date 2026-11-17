#!/usr/bin/env node
import { reopenWithCatalog } from "./lib/ax.mjs";

const catalogPath = process.argv[2];
if (!catalogPath) {
  console.error("usage: reopen-catalog.mjs <path to the .lrcat file>");
  process.exit(2);
}
await reopenWithCatalog(catalogPath);
console.log(`Lightroom reopened with ${catalogPath}`);
