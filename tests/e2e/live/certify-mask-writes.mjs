#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { dismissBlockingModals } from "./lib/ax.mjs";
import { certificationResult, depthCoverage, evaluateStep, requireThrowaway, writeCertification } from "./lib/certification.mjs";
import { compareRanges, localKeys } from "./lib/develop-ranges.mjs";
import { fixtureIdOrNull, openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { probeValue, scaleFamilies } from "./lib/local-scales.mjs";
import { REPO_ROOT } from "./lib/paths.mjs";
import {
  ellipseInside,
  intersectionOverUnion,
  maxLuminanceDifference,
  measureChange,
  regionDeltas,
} from "./lib/preview.mjs";

const AI_TIMEOUT_MS = 240_000;
const MIN_CHANGE = 0.05;
const MAX_UNTOUCHED_CHANGE = 0.01;
const MIN_RADIAL_IOU = 0.8;

const { session, marker, catalogPath } = await openLiveSession();
const id = (key) => String(requireFixtureId(marker, key));
const ids = {
  wide: id("wide_plain"), ramp: id("ramp256"), chart: id("chart80"),
  arw14: id("arw_14bit"), arw12: id("arw_12bit"), orient1: id("orient_1"), pano: id("pano"),
};

async function toolData(name, args, options) {
  const answer = await session.tool(name, args, options);
  if (answer.isError) throw new Error(`${name} failed: ${answer.text}`);
  return answer.data;
}

const status = await toolData("get_mask_write_admission", {});
requireThrowaway(status);
console.log(`certifying ${status.running.build} on ${catalogPath}`);

const depthPhoto = fixtureIdOrNull(marker, "depth_heic");
const certified = depthPhoto === null ? Object.values(ids) : [...Object.values(ids), String(depthPhoto)];
await toolData("reset_develop_adjustments", { photo_ids: certified, confirm: true }, { timeoutMs: AI_TIMEOUT_MS });

const readRaw = async (photoId) =>
  (await toolData("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections", "ProcessVersion"] })).photos[0];
const steps = [];
const evidence = [];

async function runStep({ name, photoId, added, expectRefusal = false, call, render, slider, observed }) {
  const before = await readRaw(photoId);
  let answer;
  let rendered;
  if (render) {
    const pixels = await measureChange(session, photoId, async () => { answer = await call(); });
    rendered = render(pixels.before, pixels.after);
  } else {
    answer = await call();
  }
  if (answer.isError) await dismissBlockingModals();
  const after = await readRaw(photoId);
  const admission = await toolData("get_mask_write_admission", { photo_id: photoId });
  const step = evaluateStep({ name, added, expectRefusal, answer, before, after, admission, rendered, slider, observed });
  evidence.push({ ...step, photo_id: photoId, answer: answer.envelope, rendered_detail: rendered?.detail, before, after, admission: admission.photo });
  return { step, answer, before, after };
}

const report = (step) => console.log(`${step.passed ? "pass" : "FAIL"} ${step.name}${step.problem ? `: ${step.problem}` : ""}`);

async function check(spec) {
  const { step, answer, before, after } = await runStep(spec);
  steps.push(step);
  report(step);
  return { answer: answer.data, before, after };
}

const tool = (name, args, options) => () => session.tool(name, args, options);
const changed = (deltas, region, direction) => (direction > 0 ? deltas[region] >= MIN_CHANGE : deltas[region] <= -MIN_CHANGE);
const untouched = (deltas, region) => Math.abs(deltas[region]) < MAX_UNTOUCHED_CHANGE;

function regionsChange(regions, expectChanged, expectUntouched, direction = 1) {
  return (before, after) => {
    const deltas = regionDeltas(before, after, regions);
    return { passed: changed(deltas, expectChanged, direction) && untouched(deltas, expectUntouched), detail: deltas };
  };
}

const radialGeometry = { center: { x: 0.5, y: 0.5 }, width: 0.4, height: 0.3, rotation: 30, feather: 0 };
const radial = await check({
  name: "radial create", photoId: ids.wide, added: 1,
  call: tool("create_gradient_mask", { photo_id: ids.wide, shape: "radial", ...radialGeometry, adjustments: { local_Exposure: 2 } }),
  render: (before, after) => {
    const iou = intersectionOverUnion(before, after, ellipseInside({ ...radialGeometry, rotationDegrees: radialGeometry.rotation }));
    return { passed: iou >= MIN_RADIAL_IOU, detail: { iou } };
  },
});
await check({
  name: "radial update", photoId: ids.wide, added: 0,
  call: tool("update_gradient_mask", { photo_id: ids.wide, tool_id: radial.answer?.tool_id ?? "missing", rotation: -30 }),
});
const linear = await check({
  name: "linear create", photoId: ids.wide, added: 1,
  call: tool("create_gradient_mask", { photo_id: ids.wide, shape: "linear", start: { x: 0.2, y: 0.3 }, end: { x: 0.6, y: 0.3 }, adjustments: { local_Exposure: 1 } }),
  render: regionsChange([{ name: "full", x0: 0, y0: 0, x1: 0.15, y1: 1 }, { name: "beyond", x0: 0.7, y0: 0, x1: 1, y1: 1 }], "full", "beyond"),
});
await check({
  name: "linear update", photoId: ids.wide, added: 0,
  call: tool("update_gradient_mask", { photo_id: ids.wide, tool_id: linear.answer?.tool_id ?? "missing", end: { x: 0.7, y: 0.4 } }),
});
const brush = await check({
  name: "brush create", photoId: ids.wide, added: 1,
  call: tool("create_brush_mask", { photo_id: ids.wide, strokes: [{ points: [{ x: 0.1, y: 0.85 }, { x: 0.4, y: 0.85 }], radius: 0.05 }], adjustments: { local_Exposure: 0.7 } }),
  render: regionsChange([{ name: "stroke", x0: 0.15, y0: 0.82, x1: 0.35, y1: 0.88 }, { name: "far", x0: 0.75, y0: 0.05, x1: 0.95, y1: 0.25 }], "stroke", "far"),
});
await check({
  name: "brush erase stroke", photoId: ids.wide, added: 0,
  call: tool("add_brush_strokes", { photo_id: ids.wide, tool_id: brush.answer?.tool_id ?? "missing", strokes: [{ points: [{ x: 0.3, y: 0.85 }], radius: 0.04, erase: true }] }),
});
await check({
  name: "luminance range", photoId: ids.ramp, added: 1,
  call: tool("create_range_mask", { photo_id: ids.ramp, type: "luminance", luminance: { min: 0.6, max: 1 }, adjustments: { local_Exposure: -1 } }),
  render: regionsChange([{ name: "bright", x0: 0.5, y0: 0.88, x1: 1, y1: 1 }, { name: "dark", x0: 0, y0: 0, x1: 1, y1: 0.12 }], "bright", "dark", -1),
});
await check({
  name: "colour range", photoId: ids.chart, added: 1,
  call: tool("create_range_mask", {
    photo_id: ids.chart, type: "color",
    color: { sample: { x: 0.048726, y: 0.060942, l: 0.570123, a: 0.961792, b: 0.817275 }, amount: 0.494949 },
    adjustments: { local_Exposure: -1 },
  }),
  render: regionsChange([{ name: "red", x0: 0.01, y0: 0.01, x1: 0.09, y1: 0.115 }, { name: "grey", x0: 0.21, y0: 0.885, x1: 0.29, y1: 0.99 }], "red", "grey", -1),
});
const depth = depthCoverage(depthPhoto === null ? null : await runStep({
  name: "depth range", photoId: String(depthPhoto), added: 1,
  call: tool("create_range_mask", { photo_id: String(depthPhoto), type: "depth", depth: { min: 0, max: 0.3 }, adjustments: { local_Exposure: -1 } }),
  render: regionsChange([{ name: "near", x0: 0.55, y0: 0.88, x1: 0.95, y1: 0.98 }, { name: "far", x0: 0.2, y0: 0.06, x1: 0.8, y1: 0.22 }], "near", "far", -1),
}));
if (depth.step) {
  steps.push(depth.step);
  report(depth.step);
} else {
  console.log(`not exercised: ${depth.notExercised.join("; ")}`);
}
await check({
  name: "copy settings with masks", photoId: ids.orient1, added: 3,
  call: tool("copy_develop_settings", { source_id: ids.wide, target_ids: [ids.orient1] }),
});

const sky = await toolData("create_mask", { photo_id: ids.arw14, type: "sky", adjustments: { local_Exposure: -0.5 } }, { timeoutMs: AI_TIMEOUT_MS });
const skyEntry = (rawAnswer) => (rawAnswer.settings.MaskGroupBasedCorrections ?? []).find((entry) => entry.CorrectionID === sky.mask_id);
await check({
  name: "Lightroom-authored AI mask kept by a guarded write", photoId: ids.arw14, added: 1,
  call: tool("create_gradient_mask", { photo_id: ids.arw14, shape: "linear", start: { x: 0.5, y: 0.9 }, end: { x: 0.5, y: 0.7 } }),
  render: (before, after) => ({ passed: maxLuminanceDifference(before, after) < MAX_UNTOUCHED_CHANGE, detail: { max_luminance_difference: maxLuminanceDifference(before, after) } }),
}).then(({ before, after }) => {
  const step = steps.at(-1);
  if (step.passed && JSON.stringify(skyEntry(before)) !== JSON.stringify(skyEntry(after))) {
    Object.assign(step, { passed: false, problem: "the Lightroom-authored sky entry changed" });
    console.log(`FAIL ${step.name}: ${step.problem}`);
  }
});
await check({
  name: "landscape", photoId: ids.arw14, added: 2,
  call: tool("create_mask", { photo_id: ids.arw14, type: "landscape", categories: ["sky", "vegetation"] }, { timeoutMs: AI_TIMEOUT_MS }),
});
await check({
  name: "people refused with cleanup", photoId: ids.arw12, added: 0, expectRefusal: true,
  call: tool("create_mask", { photo_id: ids.arw12, type: "people", parts: ["face_skin"] }, { timeoutMs: AI_TIMEOUT_MS }),
});
await check({
  name: "sky batch", photoId: ids.arw12, added: 1,
  call: tool("create_mask_batch", { photo_ids: [ids.arw12, ids.orient1], type: "sky", adjustments: { local_Exposure: -0.5 } }, { timeoutMs: AI_TIMEOUT_MS }),
  render: regionsChange([{ name: "sky", x0: 0.3, y0: 0.02, x1: 0.7, y1: 0.12 }, { name: "ground", x0: 0.3, y0: 0.9, x1: 0.7, y1: 0.98 }], "sky", "ground", -1),
});

const keys = await localKeys();
let familyMask;
for (const { family, key } of scaleFamilies(keys)) {
  const value = probeValue(key);
  const created = await check({
    name: `local scale ${family} (${key.name})`, photoId: ids.pano, added: 1, slider: { key, value },
    call: tool("create_gradient_mask", { photo_id: ids.pano, shape: "linear", start: { x: 0.5, y: 0.9 }, end: { x: 0.5, y: 0.7 }, adjustments: { [key.name]: value } }),
  });
  familyMask ??= created.answer?.mask_id;
}

const observedValues = Object.fromEntries(keys.map((key) => [key.name, probeValue(key, 0.25)]));
await check({
  name: "Lightroom's stored scale of every local slider", photoId: ids.pano, added: 0, observed: { keys, values: observedValues },
  call: tool("set_mask_adjustments", { photo_id: ids.pano, mask_id: familyMask ?? "missing", adjustments: observedValues }),
});
const notObserved = steps.flatMap((step) => step.not_observed ?? [])
  .map((key) => `${key} stored scale (Lightroom stored no field for it on a linear gradient)`);

const global = await toolData("describe_develop_keys", { photo_id: ids.arw12 });
const local = await toolData("describe_develop_keys", { photo_id: ids.pano, mask_id: familyMask ?? "missing" });
const ranges = compareRanges([...global.keys, ...local.local]);

const runsDirectory = path.join(path.dirname(catalogPath), "certification-runs");
fs.mkdirSync(runsDirectory, { recursive: true });
const runFile = path.join(runsDirectory, `${new Date().toISOString().replaceAll(":", "-")}.json`);
fs.writeFileSync(runFile, `${JSON.stringify({ status, steps: evidence, ranges }, null, 2)}\n`);

try {
  const kitCommit = execFileSync("git", ["-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
  const { record, exitCode, lines } = certificationResult(status, steps, new Date(),
    { kitCommit, notExercised: [...depth.notExercised, ...notObserved], ranges });
  writeCertification(status.certification_file, record);
  console.log(`certified ${record.lightroom.build}, process versions ${record.process_versions.join(", ")}; record ${status.certification_file}; run ${runFile}`);
  for (const line of lines) console.error(line);
  process.exit(exitCode);
} catch (error) {
  console.error(`${error.message}; the previous record is unchanged; run ${runFile}`);
  process.exit(1);
}
