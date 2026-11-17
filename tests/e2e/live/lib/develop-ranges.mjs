import path from "node:path";
import { pathToFileURL } from "node:url";
import { REPO_ROOT } from "./paths.mjs";

const keyTable = () => import(pathToFileURL(path.join(REPO_ROOT, "server", "src", "develop-keys.ts")).href);

export async function localKeys() {
  return (await keyTable()).LOCAL_KEYS;
}

export function compareRanges(described) {
  const ranges = { compared: [], stale_ranges: [], not_compared: [] };
  for (const entry of described.filter((candidate) => "range" in candidate)) {
    if (!Array.isArray(entry.range)) {
      ranges.not_compared.push({ key: entry.key, reason: "range depends on the photo", live: entry.live });
    } else if (!entry.live) {
      ranges.not_compared.push({ key: entry.key, reason: "Lightroom reported no range", live: null });
    } else {
      ranges.compared.push(entry.key);
      if (entry.differs) ranges.stale_ranges.push({ key: entry.key, table: entry.range, live: entry.live });
    }
  }
  ranges.not_compared.sort((left, right) => left.key.localeCompare(right.key));
  return ranges;
}
