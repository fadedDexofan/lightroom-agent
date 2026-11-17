import assert from "node:assert/strict";
import { test } from "node:test";
import { localKeys } from "../lib/develop-ranges.mjs";
import { describeMismatch, observedScales, probeValue, scaleFamilies, storedMismatch } from "../lib/local-scales.mjs";

const exposure = { name: "local_Exposure", range: [-4, 4], tolerance: 0.01, stored: "LocalExposure2012", scale: 4 };
const moire = { name: "local_Moire", range: [-100, 100], tolerance: 0.5, stored: "LocalMoire", scale: 100 };
const wheel = (name) => ({ name: `local_colorgrade${name}Hue`, range: [0, 360], tolerance: 0.5, stored: `LocalColorGrade${name}Hue`, scale: 1 });
const blending = { name: "local_colorgradeBlending", range: [0, 100], tolerance: 0.5, stored: "LocalColorGradeBlending", scale: 1, neutral: 50 };

test("keys that differ only by the colour-grading wheel are one family, every other slider is its own", () => {
  const families = scaleFamilies([exposure, wheel("Shadow"), moire, wheel("Midtone"), blending]);

  assert.deepEqual(families.map(({ key }) => key.name), ["local_Exposure", "local_colorgradeShadowHue", "local_Moire", "local_colorgradeBlending"]);
});

test("the same field name at another stored scale is another family", () => {
  const hue = { ...moire, name: "local_Hue", stored: "LocalHue" };

  assert.equal(scaleFamilies([hue, wheel("Global")]).length, 2);
});

test("the probe value is halfway from the slider's neutral to its top", () => {
  assert.equal(probeValue(exposure), 2);
  assert.equal(probeValue(wheel("Shadow")), 180);
  assert.equal(probeValue(blending), 75);
  assert.equal(probeValue(moire), 50);
});

test("a probe value can stand at another fraction of the way, rounded to a whole slider step", () => {
  assert.equal(probeValue(exposure, 0.25), 1);
  assert.equal(probeValue(blending, 0.25), 63);
  assert.equal(probeValue(wheel("Shadow"), 0.25), 90);
});

test("a stored field holding the written value at the table's scale passes within the slider tolerance", () => {
  assert.equal(storedMismatch(exposure, 2, { LocalExposure2012: 0.5 + 0.002 }), null);
  assert.equal(storedMismatch(moire, 50, { LocalMoire: 0.5 }), null);
  assert.equal(storedMismatch(wheel("Shadow"), 180, { LocalColorGradeShadowHue: 180.4 }), null);
});

test("a stored field at another scale fails and names the key, the written, the expected and the stored value", () => {
  assert.deepEqual(storedMismatch(moire, 50, { LocalMoire: 50 }), {
    key: "local_Moire", stored_field: "LocalMoire", written: 50, expected: 0.5, stored: 50,
  });
  assert.deepEqual(storedMismatch(exposure, 2, {}), {
    key: "local_Exposure", stored_field: "LocalExposure2012", written: 2, expected: 0.5, stored: null,
  });
});

test("every local slider of the server's table belongs to a family probed with a non-neutral value inside its range", async () => {
  const keys = await localKeys();
  const families = scaleFamilies(keys);
  const covered = new Set(families.map(({ family }) => family));

  assert.ok(keys.length > families.length);
  for (const key of keys) assert.ok(covered.has(scaleFamilies([key])[0].family), key.name);
  for (const { key } of families) {
    const value = probeValue(key);
    assert.ok(value >= key.range[0] && value <= key.range[1] && value !== (key.neutral ?? 0), key.name);
  }
  for (const name of ["local_Moire", "local_Defringe", "local_Sharpness", "local_LuminanceNoise", "local_glow"]) {
    assert.ok(families.some(({ key }) => key.name === name), name);
  }
});

test("a mismatch reads as the key, the written, the expected and the stored value", () => {
  assert.equal(describeMismatch(storedMismatch(moire, 50, { LocalMoire: 50 })), "local_Moire written 50: expected LocalMoire 0.5, stored 50");
});

test("Lightroom's own stored fields are compared for every key; a missing or unchanged field is not observed", () => {
  const values = { local_Exposure: 1, local_Moire: 25, local_colorgradeShadowHue: 90 };
  const entry = { LocalExposure2012: 0.25, LocalMoire: 25 };

  assert.deepEqual(observedScales([exposure, moire, wheel("Shadow")], values, entry, []), {
    mismatches: [{ key: "local_Moire", stored_field: "LocalMoire", written: 25, expected: 0.25, stored: 25 }],
    notObserved: ["local_colorgradeShadowHue"],
  });
  assert.deepEqual(observedScales([exposure], values, entry, ["local_Exposure"]), { mismatches: [], notObserved: ["local_Exposure"] });
});
