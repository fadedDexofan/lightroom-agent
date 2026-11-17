import assert from "node:assert/strict";
import { test } from "node:test";
import { compareRanges } from "../lib/develop-ranges.mjs";

const DESCRIBED = [
  { key: "Exposure2012", kind: "number", range: [-5, 5], live: [-5, 5] },
  { key: "Contrast2012", kind: "number", range: [-100, 100], live: [-100, 150], differs: true },
  { key: "Highlights2012", kind: "number", range: [-100, 100], live: null },
  { key: "Temperature", kind: "number", range: "photo", live: [1500, 50000] },
  { key: "WhiteBalance", kind: "enum", values: ["As Shot"] },
  { key: "ToneCurveName2012", kind: "text" },
  { key: "local_Exposure", range: [-4, 4], live: [-4, 4] },
  { key: "local_glow", range: [-100, 100], live: [0, 100], differs: true },
];

test("takes describe_develop_keys' verdict for every global and local range it reports", () => {
  const ranges = compareRanges(DESCRIBED);

  assert.deepEqual(ranges.compared, ["Exposure2012", "Contrast2012", "local_Exposure", "local_glow"]);
  assert.deepEqual(ranges.stale_ranges, [
    { key: "Contrast2012", table: [-100, 100], live: [-100, 150] },
    { key: "local_glow", table: [-100, 100], live: [0, 100] },
  ]);
});

test("lists photo-dependent ranges and ranges Lightroom did not report as not compared, and skips keys without a range", () => {
  assert.deepEqual(compareRanges(DESCRIBED).not_compared, [
    { key: "Highlights2012", reason: "Lightroom reported no range", live: null },
    { key: "Temperature", reason: "range depends on the photo", live: [1500, 50000] },
  ]);
});
