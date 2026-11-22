#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  certificationResult,
  evaluateStep,
  FIXTURE_STATE_KEYS,
  fixturesNotProvenReset,
  judgeRun,
  REGION_RENDERS,
  regionRender,
  renderPasses,
  requireThrowaway,
  THRESHOLDS,
  uncertifiedFixtures,
  writeCertification,
} from "./lib/certification.mjs";
import { compareRanges } from "./lib/develop-ranges.mjs";
import { fixtureIdOrNull, openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { REPO_ROOT } from "./lib/paths.mjs";
import {
  changedShare,
  changedWhere,
  decodeJpegBase64,
  detailLevel,
  ellipseInside,
  intersectionOverUnion,
  measureChange,
  regionDeltas,
  regionMeanChanges,
  sampledMaxLuminanceDifference,
} from "./lib/preview.mjs";

const AI_TIMEOUT_MS = 240_000;
const RENDER_WAIT_CAP_MS = 60_000;
const AI_AMOUNT = { local_Exposure: -1 };
const SETTLED = { minDetailRatio: 0.5, tries: 20 };
const WHOLE_FRAME = { shape: "radial", center: { x: 0.5, y: 0.5 }, width: 2, height: 2, rotation: 0, feather: 0 };

function writeResult(status, steps, { notExercised, ranges, kitCommit, thresholds, judgedFrom, runFile }) {
  for (const step of steps)
    console.log(
      `${step.passed ? "pass" : "FAIL"} ${step.name}${step.problem ? `: ${step.problem}` : ""}${step.refusal ? ` (answered ${step.refusal})` : ""}`,
    );
  try {
    const { record, exitCode, lines } = certificationResult(status, steps, new Date(), {
      kitCommit,
      notExercised,
      ranges,
      thresholds,
      judgedFrom,
    });
    writeCertification(status.certification_file, record);
    console.log(
      `certified ${record.lightroom.build}, process versions ${record.process_versions.join(", ")}; record ${status.certification_file}; run ${runFile}`,
    );
    for (const line of lines) console.error(line);
    return exitCode;
  } catch (error) {
    console.error(`${error.message}; the previous record is unchanged; run ${runFile}`);
    return 1;
  }
}

const rejudgeAt = process.argv.indexOf("--rejudge");
if (rejudgeAt !== -1) {
  const runFile = path.resolve(process.argv[rejudgeAt + 1] ?? "");
  const run = JSON.parse(fs.readFileSync(runFile, "utf8"));
  const thresholds = { ...THRESHOLDS, ...run.thresholds };
  for (let at = process.argv.indexOf("--threshold"); at !== -1; at = process.argv.indexOf("--threshold", at + 1)) {
    const [key, value] = (process.argv[at + 1] ?? "").split("=");
    if (!(key in THRESHOLDS) || !Number.isFinite(Number(value)))
      throw new Error(`--threshold takes one of ${Object.keys(THRESHOLDS).join(", ")}=<number>`);
    thresholds[key] = Number(value);
  }
  const previews = runFile.replace(/\.json$/, "-previews");
  for (const step of run.steps) {
    const spec = REGION_RENDERS[step.name];
    if (!spec || !step.previews?.before || !step.previews?.after) continue;
    const [before, after] = [step.previews.before, step.previews.after].map(({ file }) =>
      decodeJpegBase64(fs.readFileSync(path.join(previews, file)).toString("base64")),
    );
    step.rendered = regionRender(spec, regionDeltas(before, after, spec.regions));
    console.log(
      `${step.name}: measured again from its saved previews with the kit's regions: ${JSON.stringify(step.rendered.measured.deltas)}`,
    );
  }
  const { steps, notExercised } = judgeRun(run.steps, thresholds);
  console.log(notExercised.length ? `not exercised: ${notExercised.join("; ")}` : "every step exercised");
  process.exit(
    writeResult(run.status, steps, {
      notExercised,
      ranges: run.ranges,
      kitCommit: run.kit_commit,
      thresholds,
      judgedFrom: runFile,
      runFile,
    }),
  );
}

const startedAt = new Date();
const { session, marker, catalogPath } = await openLiveSession();
const id = (key) => String(requireFixtureId(marker, key));
const ids = {
  wide: id("wide_plain"),
  ramp: id("ramp256"),
  chart: id("chart80"),
  arw14: id("arw_14bit"),
  arw12: id("arw_12bit"),
  orient1: id("orient_1"),
  pano: id("pano"),
  flat: id("flat_gray"),
  people: id("people_photo"),
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
const resetAnswer = await session.tool(
  "reset_develop_adjustments",
  { photo_ids: certified, confirm: true },
  { timeoutMs: AI_TIMEOUT_MS },
);
const unproven = fixturesNotProvenReset(resetAnswer, certified);
if (unproven.length > 0) {
  const read = await toolData("get_develop_settings", { photo_ids: unproven, keys: FIXTURE_STATE_KEYS });
  const edited = uncertifiedFixtures(read, unproven);
  if (edited.length > 0) {
    throw new Error(
      `the reset did not clear these fixtures; nothing certified: ${edited.map((photo) => `${photo.photo_id} (${photo.keys.join(", ")})`).join("; ")}`,
    );
  }
  console.log(
    `fixtures already in their certified state (the reset saw nothing to clear): ${unproven.join(", ")}; edits outside ${FIXTURE_STATE_KEYS.join(", ")} are not checked on them`,
  );
}

const runStem = path.join(
  path.dirname(catalogPath),
  "certification-runs",
  startedAt.toISOString().replaceAll(":", "-"),
);
const runFile = `${runStem}.json`;
const partialFile = `${runStem}.partial.json`;
const previewsDirectory = `${runStem}-previews`;
fs.mkdirSync(previewsDirectory, { recursive: true });

const readRaw = async (photoId) =>
  (
    await toolData("get_develop_settings", {
      photo_ids: [photoId],
      keys: ["MaskGroupBasedCorrections", "ProcessVersion"],
    })
  ).photos[0];
const evidence = [];

function savePreview(index, side, pixels) {
  const bytes = Buffer.from(pixels.jpeg, "base64");
  const file = `${String(index).padStart(2, "0")}-${side}.jpg`;
  fs.writeFileSync(path.join(previewsDirectory, file), bytes);
  return { file, sha256: createHash("sha256").update(bytes).digest("hex") };
}

const copies = [];
async function cleanCopy(master, role) {
  const copy = String(
    (await toolData("create_virtual_copies", { photo_ids: [master], copy_name: `LRAGENT certification ${role}` }))
      .copies[0].copy_photo_id,
  );
  copies.push(copy);
  if ((await toolData("list_masks", { photo_id: copy })).count > 0)
    await toolData("delete_masks", { photo_id: copy, all: true });
  return copy;
}

async function check({
  name,
  photoId,
  added,
  expectRefusal = false,
  prepare,
  call,
  render,
  expectsChange = true,
  unchangedEntry,
  nothingFoundAllowed,
}) {
  const entry = { name, photo_id: photoId, added, expectRefusal, nothingFoundAllowed };
  try {
    const prepared = prepare ? await prepare() : undefined;
    if (unchangedEntry) entry.unchangedEntry = unchangedEntry(prepared);
    if (prepared?.landed_ms !== undefined) entry.prepared_landed_ms = prepared.landed_ms;
    entry.before = await readRaw(photoId);
    let answer;
    if (render) {
      const waited = Date.now();
      const shows = expectsChange ? (before, current) => renderPasses(render(before, current)) : () => true;
      const pixels = await measureChange(
        session,
        photoId,
        async () => {
          answer = await call();
        },
        { settleMs: RENDER_WAIT_CAP_MS, shows, ...SETTLED },
      );
      entry.render_wait_ms = Date.now() - waited;
      entry.detail_ratio = detailLevel(pixels.after) / detailLevel(pixels.before);
      if (expectsChange) Object.assign(entry, { landed_ms: pixels.landedMs, render_cap_ms: RENDER_WAIT_CAP_MS });
      entry.previews = {
        before: savePreview(evidence.length, "before", pixels.before),
        after: savePreview(evidence.length, "after", pixels.after),
        ...(prepared?.reference ? { reference: savePreview(evidence.length, "reference", prepared.reference) } : {}),
      };
      entry.rendered = render(pixels.before, pixels.after, prepared);
    } else {
      answer = await call();
    }
    entry.answer = { isError: answer.isError, outcome: answer.outcome, text: answer.text, envelope: answer.envelope };
    entry.data = answer.data;
    entry.after = await readRaw(photoId);
    entry.admission = await toolData("get_mask_write_admission", { photo_id: photoId });
  } catch (error) {
    entry.failure = `the step threw: ${error.message}`;
  }
  evidence.push(entry);
  fs.writeFileSync(partialFile, `${JSON.stringify(evidence)}\n`);
  const step = evaluateStep(entry);
  console.log(
    `${step.passed ? "pass" : "FAIL"} ${name}${step.problem ? `: ${step.problem}` : ""}${step.refusal ? ` (answered ${step.refusal})` : ""}`,
  );
  return entry.data;
}

const tool = (name, args, options) => () => session.tool(name, args, options);

const regionsChange =
  (regions, changed, untouched, direction = 1, check = "region_moves") =>
  (before, after) => ({
    check,
    measured: { deltas: regionDeltas(before, after, regions), changed, untouched, direction },
  });

const radialGeometry = { center: { x: 0.5, y: 0.5 }, width: 0.4, height: 0.3, rotation: 30, feather: 0 };
const radial = await check({
  name: "radial create",
  photoId: ids.wide,
  added: 1,
  call: tool("create_gradient_mask", {
    photo_id: ids.wide,
    shape: "radial",
    ...radialGeometry,
    adjustments: { local_Exposure: 2 },
  }),
  render: (before, after) => ({
    check: "radial_iou",
    measured: {
      iou: intersectionOverUnion(
        before,
        after,
        ellipseInside({ ...radialGeometry, rotationDegrees: radialGeometry.rotation }),
      ),
    },
  }),
});
await check({
  name: "radial update",
  photoId: ids.wide,
  added: 0,
  call: tool("update_gradient_mask", { photo_id: ids.wide, tool_id: radial?.tool_id ?? "missing", rotation: -30 }),
});
const linear = await check({
  name: "linear create",
  photoId: ids.wide,
  added: 1,
  call: tool("create_gradient_mask", {
    photo_id: ids.wide,
    shape: "linear",
    start: { x: 0.2, y: 0.3 },
    end: { x: 0.6, y: 0.3 },
    adjustments: { local_Exposure: 1 },
  }),
  render: regionsChange(
    [
      { name: "full", x0: 0, y0: 0, x1: 0.15, y1: 1 },
      { name: "beyond", x0: 0.7, y0: 0, x1: 1, y1: 1 },
    ],
    "full",
    "beyond",
  ),
});
await check({
  name: "linear update",
  photoId: ids.wide,
  added: 0,
  call: tool("update_gradient_mask", {
    photo_id: ids.wide,
    tool_id: linear?.tool_id ?? "missing",
    end: { x: 0.7, y: 0.4 },
  }),
});
const brush = await check({
  name: "brush create",
  photoId: ids.wide,
  added: 1,
  call: tool("create_brush_mask", {
    photo_id: ids.wide,
    strokes: [
      {
        points: [
          { x: 0.1, y: 0.85 },
          { x: 0.4, y: 0.85 },
        ],
        radius: 0.05,
      },
    ],
    adjustments: { local_Exposure: 0.7 },
  }),
  render: regionsChange(
    [
      { name: "stroke", x0: 0.15, y0: 0.82, x1: 0.35, y1: 0.88 },
      { name: "far", x0: 0.75, y0: 0.05, x1: 0.95, y1: 0.25 },
    ],
    "stroke",
    "far",
  ),
});
await check({
  name: "brush erase stroke",
  photoId: ids.wide,
  added: 0,
  call: tool("add_brush_strokes", {
    photo_id: ids.wide,
    tool_id: brush?.tool_id ?? "missing",
    strokes: [{ points: [{ x: 0.3, y: 0.85 }], radius: 0.04, erase: true }],
  }),
});
await check({
  name: "luminance range",
  photoId: ids.ramp,
  added: 1,
  call: tool("create_range_mask", {
    photo_id: ids.ramp,
    type: "luminance",
    luminance: { min: 0.6, max: 1 },
    adjustments: { local_Exposure: -1 },
  }),
  render: regionsChange(
    [
      { name: "bright", x0: 0.5, y0: 0.88, x1: 1, y1: 1 },
      { name: "dark", x0: 0, y0: 0, x1: 1, y1: 0.12 },
    ],
    "bright",
    "dark",
    -1,
  ),
});
await check({
  name: "colour range",
  photoId: ids.chart,
  added: 1,
  call: tool("create_range_mask", {
    photo_id: ids.chart,
    type: "color",
    color: { sample: { x: 0.048726, y: 0.060942, l: 0.570123, a: 0.961792, b: 0.817275 }, amount: 0.494949 },
    adjustments: { local_Exposure: -1 },
  }),
  render: regionsChange(
    [
      { name: "red", x0: 0.01, y0: 0.01, x1: 0.09, y1: 0.115 },
      { name: "grey", x0: 0.21, y0: 0.885, x1: 0.29, y1: 0.99 },
    ],
    "red",
    "grey",
    -1,
  ),
});
if (depthPhoto !== null) {
  await check({
    name: "depth range",
    photoId: String(depthPhoto),
    added: 1,
    call: tool("create_range_mask", {
      photo_id: String(depthPhoto),
      type: "depth",
      depth: { min: 0, max: 0.3 },
      adjustments: { local_Exposure: -1 },
    }),
    render: regionsChange(
      [
        { name: "near", x0: 0.55, y0: 0.88, x1: 0.95, y1: 0.98 },
        { name: "far", x0: 0.2, y0: 0.06, x1: 0.8, y1: 0.22 },
      ],
      "near",
      "far",
      -1,
    ),
  });
}
await check({
  name: "copy settings with masks",
  photoId: ids.orient1,
  added: 3,
  call: tool("copy_develop_settings", { source_id: ids.wide, target_ids: [ids.orient1] }),
});

const skyKept = await cleanCopy(ids.arw14, "sky kept");
await check({
  name: "a computed Sky kept by a guarded write",
  photoId: skyKept,
  added: 1,
  prepare: async () => {
    await toolData("create_gradient_mask", {
      photo_id: skyKept,
      shape: "linear",
      start: { x: 0.5, y: 0.6 },
      end: { x: 0.5, y: 0.5 },
    });
    let sky;
    const darkens = (before, current) =>
      changedShare(before, current, () => true, { direction: "darker" }).changed >= THRESHOLDS.min_changed_share;
    const landing = await measureChange(
      session,
      skyKept,
      async () => {
        sky = await toolData(
          "create_mask",
          { photo_id: skyKept, type: "sky", adjustments: AI_AMOUNT },
          { timeoutMs: AI_TIMEOUT_MS },
        );
      },
      { settleMs: RENDER_WAIT_CAP_MS, shows: darkens, ...SETTLED },
    );
    return { ...sky, landed_ms: landing.landedMs, reference: landing.before };
  },
  unchangedEntry: (sky) => sky.mask_id,
  call: tool("create_gradient_mask", {
    photo_id: skyKept,
    shape: "linear",
    start: { x: 0.5, y: 0.9 },
    end: { x: 0.5, y: 0.7 },
  }),
  expectsChange: false,
  render: (before, after, sky) => ({
    check: "region_means_kept",
    measured: {
      ...regionMeanChanges(sky.reference, before, after),
      sampled_max_luminance_difference: sampledMaxLuminanceDifference(before, after),
    },
  }),
});
const landscape = await cleanCopy(ids.arw14, "landscape");
await check({
  name: "landscape",
  photoId: landscape,
  added: 2,
  call: tool(
    "create_mask",
    { photo_id: landscape, type: "landscape", categories: ["sky", "vegetation"] },
    { timeoutMs: AI_TIMEOUT_MS },
  ),
});
const noPerson = await cleanCopy(ids.arw12, "no person");
await check({
  name: "people refused with cleanup",
  photoId: noPerson,
  added: 0,
  expectRefusal: true,
  call: tool("create_mask", { photo_id: noPerson, type: "people", parts: ["face_skin"] }, { timeoutMs: AI_TIMEOUT_MS }),
});
const batchJudged = await cleanCopy(ids.arw12, "sky batch");
const batchOther = await cleanCopy(ids.arw14, "sky batch");
await check({
  name: "sky batch",
  photoId: batchJudged,
  added: 1,
  nothingFoundAllowed: [batchOther],
  call: tool(
    "create_mask_batch",
    { photo_ids: [batchJudged, batchOther], type: "sky", adjustments: AI_AMOUNT },
    { timeoutMs: AI_TIMEOUT_MS },
  ),
  render: (before, after) =>
    regionRender(REGION_RENDERS["sky batch"], regionDeltas(before, after, REGION_RENDERS["sky batch"].regions)),
});

let subject = null;
const subjectCopy = await cleanCopy(ids.people, "subject");
await check({
  name: "Subject created in the saved settings",
  photoId: subjectCopy,
  added: 1,
  call: tool(
    "create_mask",
    { photo_id: subjectCopy, type: "subject", adjustments: AI_AMOUNT },
    { timeoutMs: AI_TIMEOUT_MS },
  ),
  render: (before, after) => {
    subject = changedWhere(before, after, { direction: "darker" });
    return {
      check: "darkens",
      measured: { darkened: changedShare(before, after, () => true, { direction: "darker" }).changed },
    };
  },
});
const inSubject = (fx, fy) => subject(fx, fy);
const outsideSubject = (fx, fy) => !subject(fx, fy);

function darkensWithin(inside) {
  return (before, after) => {
    if (!subject) throw new Error("the Subject step left no subject region to compare with");
    const darkened = changedShare(before, after, inside, { direction: "darker" });
    const brightened = changedShare(before, after, () => true, { direction: "brighter" });
    return {
      check: "darkens_within",
      measured: { darkened: darkened.changed, share_in_region: darkened.inside, brightened: brightened.changed },
    };
  };
}

const TOP_STRIP = { shape: "linear", start: { x: 0.5, y: 0.02 }, end: { x: 0.5, y: 0.1 } };
const combineSteps = [
  { operation: "add", target: TOP_STRIP, darkens: (fx, fy) => fy < 0.1 || inSubject(fx, fy) },
  { operation: "subtract", target: WHOLE_FRAME, darkens: outsideSubject },
  { operation: "intersect", target: WHOLE_FRAME, darkens: inSubject },
];
for (const { operation, target, darkens } of combineSteps) {
  const combined = await cleanCopy(ids.people, `combine ${operation}`);
  await check({
    name: `a mask made and Subject combined into it (${operation}) in the saved settings`,
    photoId: combined,
    added: 1,
    call: async () => {
      const maskId = (await toolData("create_gradient_mask", { photo_id: combined, ...target, adjustments: AI_AMOUNT }))
        .mask_id;
      return session.tool(
        "combine_mask",
        { photo_id: combined, mask_id: String(maskId), operation, type: "subject" },
        { timeoutMs: AI_TIMEOUT_MS },
      );
    },
    render: darkensWithin(darkens),
  });
}
const background = await cleanCopy(ids.people, "background");
await check({
  name: "Background created in the saved settings",
  photoId: background,
  added: 1,
  call: tool(
    "create_mask",
    { photo_id: background, type: "background", adjustments: AI_AMOUNT },
    { timeoutMs: AI_TIMEOUT_MS },
  ),
  render: darkensWithin(outsideSubject),
});
const nothing = await cleanCopy(ids.flat, "nothing found");
await check({
  name: "nothing found refused with nothing left",
  photoId: nothing,
  added: 0,
  expectRefusal: true,
  call: tool("create_mask", { photo_id: nothing, type: "subject" }, { timeoutMs: AI_TIMEOUT_MS }),
});

let ranges;
try {
  const localRangesMask = (
    await toolData("create_gradient_mask", {
      photo_id: ids.pano,
      shape: "linear",
      start: { x: 0.5, y: 0.9 },
      end: { x: 0.5, y: 0.7 },
    })
  ).mask_id;
  const global = await toolData("describe_develop_keys", { photo_id: ids.arw12 });
  const local = await toolData("describe_develop_keys", { photo_id: ids.pano, mask_id: localRangesMask });
  ranges = compareRanges([...global.keys, ...local.local]);
} catch (error) {
  ranges = { error: error.message, compared: [], stale_ranges: [], not_compared: [] };
  console.error(`ranges not compared: ${error.message}`);
}

const kitCommit = execFileSync("git", ["-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
fs.writeFileSync(
  runFile,
  `${JSON.stringify(
    {
      status,
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      kit_commit: kitCommit,
      thresholds: THRESHOLDS,
      steps: evidence,
      ranges,
    },
    null,
    2,
  )}\n`,
);
fs.rmSync(partialFile, { force: true });
if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
await session.stop();

const { steps, notExercised } = judgeRun(evidence);
console.log(notExercised.length ? `not exercised: ${notExercised.join("; ")}` : "every step exercised");
process.exit(writeResult(status, steps, { notExercised, ranges, kitCommit, thresholds: THRESHOLDS, runFile }));
