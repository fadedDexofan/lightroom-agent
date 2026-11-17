import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  assertThrowawayCatalog,
  isRealCatalog,
  isThrowawayCatalog,
  parseOpenCatalogs,
  lightroomPid,
} from "../lib/catalog-guard.mjs";
import { LIGHTROOM_PROCESS_NAME, THROWAWAY_CATALOG_ENV, THROWAWAY_MARKER_FILE } from "../lib/paths.mjs";

const HOME = path.resolve("/Users/tester");
const REAL = path.join(HOME, "Pictures", "Lightroom", "Lightroom Catalog.lrcat");
const THROWAWAY = path.join(HOME, "Documents", "lragent-live-1", "lragent-live-1.lrcat");
const markerFor = (catalog) => path.join(path.dirname(catalog), THROWAWAY_MARKER_FILE);
const options = (extra = {}) => ({ home: HOME, environment: {}, fileExists: () => false, ...extra });

test("the real catalog is recognised, also with different case and nested copies", () => {
  assert.equal(isRealCatalog(REAL, HOME), true);
  assert.equal(isRealCatalog(REAL.toUpperCase(), HOME), true);
  assert.equal(isRealCatalog(path.join(HOME, "Pictures", "Lightroom", "Backups", "x.lrcat"), HOME), true);
  assert.equal(isRealCatalog(THROWAWAY, HOME), false);
  assert.equal(isRealCatalog(path.join(HOME, "Pictures", "LightroomOther", "a.lrcat"), HOME), false);
});

test("relative segments cannot smuggle the real catalog past the check", () => {
  const sneaky = path.join(HOME, "Documents", "..", "Pictures", "Lightroom", "Lightroom Catalog.lrcat");
  assert.equal(isRealCatalog(sneaky, HOME), true);
});

test("open catalogs are parsed from lsof field output and sidecar files are ignored", () => {
  const output = [
    "p123",
    "fcwd",
    "n/",
    "f20",
    `n${THROWAWAY}`,
    `n${THROWAWAY}-wal`,
    `n${THROWAWAY}-shm`,
    `n${path.dirname(THROWAWAY)}/lragent-live-1.lrcat-data/LOG`,
    `n${THROWAWAY}`,
  ].join("\n");
  assert.deepEqual(parseOpenCatalogs(output), [THROWAWAY]);
});

test("a catalog is throwaway only with its marker file or an explicit environment declaration", () => {
  assert.equal(isThrowawayCatalog(THROWAWAY, options()), false);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ fileExists: (file) => file === markerFor(THROWAWAY) })), true);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ environment: { [THROWAWAY_CATALOG_ENV]: THROWAWAY } })), true);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ environment: { [THROWAWAY_CATALOG_ENV]: "/elsewhere.lrcat" } })), false);
});

test("a marker beside the real catalog never makes it throwaway", () => {
  const withMarker = options({ fileExists: () => true, environment: { [THROWAWAY_CATALOG_ENV]: REAL } });
  assert.equal(isThrowawayCatalog(REAL, withMarker), false);
});

test("the guard refuses the real catalog, an unmarked catalog, none and several", () => {
  assert.throws(() => assertThrowawayCatalog([REAL], options({ fileExists: () => true })), /real catalog/);
  assert.throws(() => assertThrowawayCatalog([THROWAWAY], options()), /not a throwaway catalog/);
  assert.throws(() => assertThrowawayCatalog([], options()), /exactly one/);
  assert.throws(() => assertThrowawayCatalog([THROWAWAY, REAL], options({ fileExists: () => true })), /exactly one/);
});

test("the guard returns the throwaway catalog path when it is marked", () => {
  assert.equal(assertThrowawayCatalog([THROWAWAY], options({ fileExists: () => true })), THROWAWAY);
});


test("Lightroom PID uses executable identity instead of AdobeIPCBroker launched-by arguments", () => {
  const pid = lightroomPid((command, args) => {
    assert.equal(command, "ps");
    assert.deepEqual(args, ["-axo", "pid=,comm="]);
    return [
      "81947 /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/Frameworks/AdobeIPCBroker.app/Contents/MacOS/AdobeIPCBroker",
      "84715 /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic",
    ].join("\n");
  });

  assert.equal(pid, 84715);
});

test("multiple Lightroom executables do not select an arbitrary catalog owner", () => {
  const pid = lightroomPid(() => [
    "100 /Applications/LrA.app/Contents/MacOS/Adobe Lightroom Classic",
    "200 /Applications/LrB.app/Contents/MacOS/Adobe Lightroom Classic",
  ].join("\n"));

  assert.equal(pid, null);
});

test("no Lightroom executable or process-query failure reports no catalog owner", () => {
  assert.equal(lightroomPid(() => "81947 /Applications/AdobeIPCBroker"), null);
  assert.equal(lightroomPid(() => { throw new Error("process query denied"); }), null);
});

test("the runner's mutating modes refuse before starting a server when the open catalog has no throwaway marker", () => {
  const runner = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "mcp-runner.mjs");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lragent-runner-guard-"));
  try {
    const bin = path.join(root, "bin");
    const catalog = path.join(root, "unmarked", "Unmarked.lrcat");
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, "ps"), `#!/bin/sh\necho "4242 /Applications/X.app/Contents/MacOS/${LIGHTROOM_PROCESS_NAME}"\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(bin, "lsof"), `#!/bin/sh\necho "p4242"\necho "n${catalog}"\n`, { mode: 0o755 });
    for (const mode of ["write", "develop", "export", "preset-roundtrip", "all"]) {
      const result = spawnSync(process.execPath, [runner, mode], {
        encoding: "utf8", timeout: 20_000, env: { PATH: bin, HOME: root, LIGHTROOM_AGENT_READ_ONLY: "true" },
      });
      assert.match(`${result.stdout}${result.stderr}`, /refusing to run: .*Unmarked\.lrcat is not a throwaway catalog/, mode);
      assert.notEqual(result.status, 0, mode);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
