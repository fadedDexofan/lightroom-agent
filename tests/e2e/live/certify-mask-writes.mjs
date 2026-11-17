#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { dismissBlockingModals } from "./lib/ax.mjs";
import { buildCertificationRecord, evaluateStep, requireThrowaway, writeCertification } from "./lib/certification.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { REPO_ROOT } from "./lib/paths.mjs";
import {
  ellipseInside,
  intersectionOverUnion,
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
  arw14: id("arw_14bit"), arw12: id("arw_12bit"), orient1: id("orient_1"),
};

async function toolData(name, args, options) {
  const answer = await session.tool(name, args, options);
  if (answer.isError) throw new Error(`${name} failed: ${answer.text}`);
  return answer.data;
}

const status = await toolData("get_mask_write_admission", {});
requireThrowaway(status);
console.log(`certifying ${status.running.build} on ${catalogPath}`);

await toolData("reset_develop_adjustments", { photo_ids: Object.values(ids), confirm: true }, { timeoutMs: AI_TIMEOUT_MS });

const readRaw = (photoId) => toolData("get_raw_develop_settings", { photo_id: photoId, keys: ["MaskGroupBasedCorrections", "ProcessVersion"] });
const steps = [];
const evidence = [];

async function check({ name, photoId, added, expectRefusal = false, call, render }) {
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
  const step = evaluateStep({ name, added, expectRefusal, answer, before, after, admission, rendered });
  steps.push(step);
  evidence.push({ ...step, photo_id: photoId, answer: answer.data, rendered_detail: rendered?.detail, before, after, admission: admission.photo });
  console.log(`${step.passed ? "pass" : "FAIL"} ${name}${step.problem ? `: ${step.problem}` : ""}`);
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
  call: tool("create_gradient_mask", { photo_id: ids.wide, shape: "radial", ...radialGeometry, adjustments: { exposure: 2 } }),
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
  call: tool("create_gradient_mask", { photo_id: ids.wide, shape: "linear", start: { x: 0.2, y: 0.3 }, end: { x: 0.6, y: 0.3 }, adjustments: { exposure: 1 } }),
  render: regionsChange([{ name: "full", x0: 0, y0: 0, x1: 0.15, y1: 1 }, { name: "beyond", x0: 0.7, y0: 0, x1: 1, y1: 1 }], "full", "beyond"),
});
await check({
  name: "linear update", photoId: ids.wide, added: 0,
  call: tool("update_gradient_mask", { photo_id: ids.wide, tool_id: linear.answer?.tool_id ?? "missing", end: { x: 0.7, y: 0.4 } }),
});
const brush = await check({
  name: "brush create", photoId: ids.wide, added: 1,
  call: tool("create_brush_mask", { photo_id: ids.wide, strokes: [{ points: [{ x: 0.1, y: 0.85 }, { x: 0.4, y: 0.85 }], radius: 0.05 }], adjustments: { exposure: 0.7 } }),
  render: regionsChange([{ name: "stroke", x0: 0.15, y0: 0.82, x1: 0.35, y1: 0.88 }, { name: "far", x0: 0.75, y0: 0.05, x1: 0.95, y1: 0.25 }], "stroke", "far"),
});
await check({
  name: "brush erase stroke", photoId: ids.wide, added: 0,
  call: tool("add_brush_strokes", { photo_id: ids.wide, tool_id: brush.answer?.tool_id ?? "missing", strokes: [{ points: [{ x: 0.3, y: 0.85 }], radius: 0.04, erase: true }] }),
});
await check({
  name: "luminance range", photoId: ids.ramp, added: 1,
  call: tool("create_range_mask", { photo_id: ids.ramp, type: "luminance", luminance: { min: 0.6, max: 1 }, adjustments: { exposure: -1 } }),
  render: regionsChange([{ name: "bright", x0: 0.5, y0: 0.88, x1: 1, y1: 1 }, { name: "dark", x0: 0, y0: 0, x1: 1, y1: 0.12 }], "bright", "dark", -1),
});
await check({
  name: "colour range", photoId: ids.chart, added: 1,
  call: tool("create_range_mask", {
    photo_id: ids.chart, type: "color",
    color: { sample: { x: 0.048726, y: 0.060942, l: 0.570123, a: 0.961792, b: 0.817275 }, amount: 0.494949 },
    adjustments: { exposure: -1 },
  }),
  render: regionsChange([{ name: "red", x0: 0.01, y0: 0.01, x1: 0.09, y1: 0.115 }, { name: "grey", x0: 0.21, y0: 0.885, x1: 0.29, y1: 0.99 }], "red", "grey", -1),
});
await check({
  name: "copy settings with masks", photoId: ids.orient1, added: 3,
  call: tool("copy_develop_settings", { source_id: ids.wide, target_ids: [ids.orient1] }),
});

const sky = await toolData("create_mask", { photo_id: ids.arw14, type: "sky", adjustments: { exposure: -0.5 } }, { timeoutMs: AI_TIMEOUT_MS });
const skyEntry = (rawAnswer) => (rawAnswer.settings.MaskGroupBasedCorrections ?? []).find((entry) => entry.CorrectionID === sky.mask_id);
await check({
  name: "Lightroom-authored AI mask kept by a guarded write", photoId: ids.arw14, added: 1,
  call: tool("create_gradient_mask", { photo_id: ids.arw14, shape: "linear", start: { x: 0.5, y: 0.9 }, end: { x: 0.5, y: 0.7 } }),
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
  call: tool("create_mask_batch", { photo_ids: [ids.arw12, ids.orient1], type: "sky", adjustments: { exposure: -0.5 } }, { timeoutMs: AI_TIMEOUT_MS }),
});

const runsDirectory = path.join(path.dirname(catalogPath), "certification-runs");
fs.mkdirSync(runsDirectory, { recursive: true });
const runFile = path.join(runsDirectory, `${new Date().toISOString().replaceAll(":", "-")}.json`);
fs.writeFileSync(runFile, `${JSON.stringify({ status, steps: evidence }, null, 2)}\n`);

try {
  const kitCommit = execFileSync("git", ["-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
  const record = buildCertificationRecord(status, steps, new Date(), { kitCommit });
  writeCertification(status.certification_file, record);
  console.log(`certified ${record.lightroom.build}, process versions ${record.process_versions.join(", ")}; record ${status.certification_file}; run ${runFile}`);
  process.exit(0);
} catch (error) {
  console.error(`${error.message}; the previous record is unchanged; run ${runFile}`);
  process.exit(1);
}
