import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  buildCertificationRecord,
  certificationResult,
  clearMasks,
  evaluateStep,
  fixtureBaselineProblems,
  fixtureStateProblems,
  isRawFixture,
  fixturesNotProvenReset,
  uncertifiedFixtures,
  judgeRun,
  REGION_RENDERS,
  regionRender,
  maskCount,
  NOT_EXERCISED,
  renderPasses,
  THRESHOLDS,
  requireThrowaway,
  writeCertification,
} from "../lib/certification.mjs";
import { REPO_ROOT, THROWAWAY_MARKER_FILE } from "../lib/paths.mjs";
import { regionDeltas } from "../lib/preview.mjs";

const raw = (entries, processVersion = "15.4") => ({
  settings: {
    ProcessVersion: processVersion,
    ...(entries === undefined ? {} : { MaskGroupBasedCorrections: entries }),
  },
});
const admitted = (problems = []) => ({ photo: { schema_problems: problems } });
const answerOf = (envelope) => ({
  isError: envelope.outcome !== "done",
  text: JSON.stringify(envelope),
  envelope,
  outcome: envelope.outcome,
  data: envelope.data,
});
const ok = answerOf({ outcome: "done", data: { mask_id: "a" } });
const refused = answerOf({
  outcome: "failed",
  error: "Lightroom found no face_skin on any person in photo 2139; no mask was left on the photo",
});

test("a photo without the mask setting counts as zero masks", () => {
  assert.equal(maskCount(raw(undefined)), 0);
  assert.equal(maskCount(raw([])), 0);
  assert.equal(maskCount(raw([{}, {}])), 2);
});

test("a write passes when it succeeds, adds the expected masks and leaves every mask in the pinned format", () => {
  const step = evaluateStep({
    name: "linear create",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
  });

  assert.deepEqual(step, { name: "linear create", passed: true, rendered: false, process_version: "15.4" });
});

test("a write with a rendered check passes only when the rendered check passed", () => {
  const base = {
    name: "linear create",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
  };

  assert.equal(evaluateStep({ ...base, rendered: { check: "radial_iou", measured: { iou: 0.9 } } }).rendered, true);
  assert.match(
    evaluateStep({ ...base, rendered: { check: "radial_iou", measured: { iou: 0.5 } } }).problem,
    /rendered check radial_iou failed: \{"iou":0.5\}/,
  );
});

test("a rendered check is judged from its measured numbers against the thresholds it is given", () => {
  const measured = { darkened: 0.2, share_in_region: 0.65, brightened: 0 };
  const step = {
    name: "Background created",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    rendered: { check: "darkens_within", measured },
  };

  assert.match(evaluateStep(step).problem, /rendered check darkens_within failed/);
  assert.equal(evaluateStep(step, { ...THRESHOLDS, min_share_in_region: 0.6 }).passed, true);
  assert.match(
    evaluateStep({
      ...step,
      rendered: { check: "darkens_within", measured: { ...measured, share_in_region: 0.9, brightened: 0.01 } },
    }).problem,
    /darkens_within failed/,
  );
  assert.equal(
    evaluateStep({
      ...step,
      rendered: {
        check: "region_moves",
        measured: { deltas: { full: -0.06, beyond: 0.005 }, changed: "full", untouched: "beyond", direction: -1 },
      },
    }).passed,
    true,
  );
});

test("an AI mask's effect is kept when the mean change of its region and of the rest each stay within the limit, whatever the sampled maximum", () => {
  const step = {
    name: "a computed Sky kept by a guarded write",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
  };
  const kept = (region, rest) => ({
    ...step,
    rendered: {
      check: "region_means_kept",
      measured: {
        region_share: 0.25,
        region_mean_change: region,
        rest_mean_change: rest,
        sampled_max_luminance_difference: 0.0667,
      },
    },
  });

  assert.equal(evaluateStep(kept(-0.0003, -0.0028)).passed, true);
  assert.match(evaluateStep(kept(0.03, -0.0028)).problem, /region_means_kept failed/);
  assert.match(evaluateStep(kept(-0.0003, -0.012)).problem, /region_means_kept failed/);
  assert.equal(evaluateStep(kept(-0.0003, -0.012), { ...THRESHOLDS, max_region_mean_change: 0.02 }).passed, true);
});

test("a run file whose render check this kit no longer judges is a failed step that names the check", () => {
  const step = {
    name: "a computed Sky kept by a guarded write",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    rendered: { check: "unchanged", measured: { sampled_max_luminance_difference: 0.0667 } },
  };

  assert.equal(
    evaluateStep(step).problem,
    'rendered check unchanged is not one this kit judges: {"sampled_max_luminance_difference":0.0667}',
  );
});

test("a region contrast passes when the changed region moves at least the minimum and that many times the untouched one", () => {
  const step = { name: "sky batch", added: 1, answer: ok, before: raw([]), after: raw([{}]), admission: admitted() };
  const contrast = (sky, ground) => ({
    ...step,
    rendered: {
      check: "region_contrast",
      measured: { deltas: { sky, ground }, changed: "sky", untouched: "ground", direction: -1 },
    },
  });

  assert.equal(evaluateStep(contrast(-0.022, -0.0014)).passed, true);
  assert.equal(evaluateStep(contrast(-0.022, 0)).passed, true);
  assert.match(evaluateStep(contrast(-0.008, 0)).problem, /region_contrast failed/);
  assert.match(evaluateStep(contrast(-0.022, -0.005)).problem, /region_contrast failed/);
  assert.match(evaluateStep(contrast(0.022, 0)).problem, /region_contrast failed/);
  assert.equal(evaluateStep(contrast(-0.008, 0), { ...THRESHOLDS, min_contrast_change: 0.005 }).passed, true);
});

test("a render step whose expected change never landed within its cap is a miss that says so", () => {
  const step = {
    name: "Subject created",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    rendered: { check: "darkens", measured: { darkened: 0 } },
  };

  assert.match(
    evaluateStep({ ...step, landed_ms: null, render_cap_ms: 60000 }).problem,
    /the expected change never landed within 60 s; rendered check darkens failed/,
  );
  assert.match(
    evaluateStep({ ...step, landed_ms: 1200, render_cap_ms: 60000 }).problem,
    /^rendered check darkens failed/,
  );
  assert.equal(renderPasses({ check: "darkens", measured: { darkened: 0.2 } }), true);
  assert.equal(
    renderPasses({ check: "darkens", measured: { darkened: 0.2 } }, { ...THRESHOLDS, min_changed_share: 0.3 }),
    false,
  );
});

test("a step that could not run, or changed an entry it had to keep, is a failed step", () => {
  const kept = { CorrectionID: "sky", CorrectionAmount: 1 };
  const base = {
    name: "a computed Sky kept by a guarded write",
    added: 1,
    answer: ok,
    before: raw([kept]),
    admission: admitted(),
    unchangedEntry: "sky",
  };

  assert.equal(
    evaluateStep({ ...base, after: raw([kept, {}]), failure: "the step threw: busy" }).problem,
    "the step threw: busy",
  );
  assert.equal(
    evaluateStep({ ...base, after: raw([{ ...kept, CorrectionAmount: 0.5 }, {}]) }).problem,
    "entry sky changed",
  );
  assert.equal(evaluateStep({ ...base, after: raw([kept, {}]) }).passed, true);
});

test("a run is judged again from its evidence alone, depth coverage included", () => {
  const darkening = {
    name: "Background created",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    rendered: { check: "darkens_within", measured: { darkened: 0.2, share_in_region: 0.65, brightened: 0 } },
  };
  const noDepth = answerOf({ outcome: "failed", error: "Lightroom found no depth map on this photo" });
  const depth = {
    name: "depth range",
    added: 1,
    answer: noDepth,
    before: raw([]),
    after: raw([]),
    admission: admitted(),
  };
  const evidence = JSON.parse(JSON.stringify([darkening, depth]));

  assert.deepEqual(
    judgeRun(evidence).steps.map((step) => [step.name, step.passed]),
    [["Background created", false]],
  );
  const relaxed = judgeRun(evidence, { ...THRESHOLDS, min_share_in_region: 0.6 });
  assert.deepEqual(
    relaxed.steps.map((step) => [step.name, step.passed]),
    [["Background created", true]],
  );
  assert.deepEqual(relaxed.notExercised, ["depth range (Lightroom found no depth map in the supplied depth photo)"]);
});

test("the command refuses a catalog without the kit marker", () => {
  assert.throws(() => requireThrowaway({ throwaway_catalog: false }), /not the live kit's throwaway catalog/);
  assert.throws(() => requireThrowaway(undefined), /not the live kit's throwaway catalog/);
  assert.doesNotThrow(() => requireThrowaway({ throwaway_catalog: true }));
});

test("a write fails when the tool errs, the mask count is off or Lightroom's entries leave the pinned format", () => {
  const base = { name: "radial create", added: 1, before: raw([]), after: raw([{}]), admission: admitted() };

  assert.match(
    evaluateStep({ ...base, answer: answerOf({ outcome: "failed", error: "boom" }) }).problem,
    /tool failed: boom/,
  );
  assert.match(evaluateStep({ ...base, answer: ok, after: raw([]) }).problem, /expected 1 mask\(s\) added, found 0/);
  assert.match(
    evaluateStep({
      ...base,
      answer: ok,
      admission: admitted(["existing mask 1 component 1: unexpected field Spacing"]),
    }).problem,
    /pinned format: existing mask 1 component 1: unexpected field Spacing/,
  );
});

test("the pinned format is judged only on the masks the step added or changed", () => {
  const neighbour = { CorrectionID: "n", CorrectionMasks: [] };
  const created = { CorrectionID: "c", CorrectionMasks: [{ What: "Mask/Gradient" }] };
  const base = { name: "linear create", added: 1, answer: ok, before: raw([neighbour]) };

  assert.equal(
    evaluateStep({
      ...base,
      after: raw([neighbour, created]),
      admission: admitted(["existing mask 1: no mask components"]),
    }).passed,
    true,
  );
  assert.match(
    evaluateStep({
      ...base,
      after: raw([neighbour, created]),
      admission: admitted(["existing mask 2.CorrectionMasks[1]: unexpected field Spacing"]),
    }).problem,
    /pinned format: existing mask 2\.CorrectionMasks\[1\]: unexpected field Spacing/,
  );
  assert.match(
    evaluateStep({
      ...base,
      added: 0,
      after: raw([{ ...neighbour, CorrectionActive: false }]),
      admission: admitted(["existing mask 1: no mask components"]),
    }).problem,
    /pinned format: existing mask 1: no mask components/,
  );
});

test("a batch step accepts a nothing-found failure only for the photos it names", () => {
  const partial = (failed) => answerOf({ outcome: "partial", failed, data: { created: 1 } });
  const nothing = {
    photo_id: "14",
    reason: "Lightroom found nothing for Sky on photo 14 (ErrorReason 1); the new masks were removed",
  };
  const base = {
    name: "sky batch",
    added: 1,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    nothingFoundAllowed: ["14"],
  };

  assert.equal(evaluateStep({ ...base, answer: partial([nothing]) }).passed, true);
  assert.match(evaluateStep({ ...base, answer: partial([{ ...nothing, photo_id: "12" }]) }).problem, /tool failed/);
  assert.match(
    evaluateStep({ ...base, answer: partial([{ ...nothing, reason: "the catalog stayed busy" }]) }).problem,
    /tool failed/,
  );
  assert.match(
    evaluateStep({ ...base, nothingFoundAllowed: undefined, answer: partial([nothing]) }).problem,
    /tool failed/,
  );
});

test("an expected refusal passes only when the tool refused and left the photo's masks as they were", () => {
  const base = { name: "people refused with cleanup", added: 0, expectRefusal: true, admission: admitted() };

  assert.equal(evaluateStep({ ...base, answer: refused, before: raw(undefined), after: raw([]) }).passed, true);
  assert.match(evaluateStep({ ...base, answer: ok, before: raw([]), after: raw([]) }).problem, /expected a refusal/);
  assert.match(
    evaluateStep({ ...base, answer: refused, before: raw([]), after: raw([{}]) }).problem,
    /expected 0 mask\(s\) added, found 1/,
  );
});

test("only Lightroom finding nothing counts as the expected refusal, never a refusal before the call reached it", () => {
  const base = { name: "people refused with cleanup", added: 0, expectRefusal: true, admission: admitted() };
  for (const error of [
    'Invalid arguments for create_mask: unknown property "photo_id": use photo_ids',
    'Unknown tool "create_maks". Only listed tools can be called.',
    'Tool "create_mask" is disabled. Enable "masks" in LIGHTROOM_AGENT_TOOLSETS and restart the server.',
    "Lightroom Classic plugin is not connected.",
    "The server refused the call: create_mask is unavailable in read-only mode",
  ]) {
    const step = evaluateStep({
      ...base,
      answer: answerOf({ outcome: "failed", error }),
      before: raw([]),
      after: raw([]),
    });
    assert.equal(step.passed, false);
    assert.match(step.problem, /refused for another reason/);
  }
});

test("masks read back with their keys in another order count as the same masks", () => {
  const before = [{ CorrectionID: "a", CorrectionAmount: 1, CorrectionMasks: [{ What: "Mask/Image", MaskValue: 1 }] }];
  const after = [{ CorrectionMasks: [{ MaskValue: 1, What: "Mask/Image" }], CorrectionAmount: 1, CorrectionID: "a" }];

  assert.equal(
    evaluateStep({
      name: "people refused with cleanup",
      added: 0,
      expectRefusal: true,
      admission: admitted(),
      answer: refused,
      before: raw(before),
      after: raw(after),
    }).passed,
    true,
  );
});

test("a nothing-found refusal passes as failed or as unknown naming Update AI Settings, only with the masks back exactly, and says which", () => {
  const kept = [{ CorrectionID: "a", CorrectionAmount: 1 }];
  const base = {
    name: "nothing found refused with nothing left",
    added: 0,
    expectRefusal: true,
    admission: admitted(),
    before: raw(kept),
    after: raw(kept),
  };
  const voided = answerOf({
    outcome: "unknown",
    error:
      "Lightroom found nothing for Subject on photo 9; the new masks were removed; Update AI Settings changed FilterList",
  });

  assert.deepEqual(
    [evaluateStep({ ...base, answer: refused }).passed, evaluateStep({ ...base, answer: refused }).refusal],
    [true, "failed"],
  );
  assert.deepEqual(
    [evaluateStep({ ...base, answer: voided }).passed, evaluateStep({ ...base, answer: voided }).refusal],
    [true, "unknown"],
  );
  assert.match(
    evaluateStep({ ...base, answer: voided, after: raw([{ CorrectionID: "a", CorrectionAmount: 0.5 }]) }).problem,
    /masks are not back exactly/,
  );
  const record = buildCertificationRecord(status, [evaluateStep({ ...base, answer: voided })], new Date());
  assert.deepEqual(record.refusals, { "nothing found refused with nothing left": "unknown" });
});

test("a batch accepts a named photo's nothing-found answer in unknown when it names Update AI Settings", () => {
  const partial = answerOf({
    outcome: "partial",
    failed: [],
    unknown: [
      {
        photo_id: "14",
        reason:
          "Lightroom found nothing for Sky on photo 14; the new masks were removed; Update AI Settings changed Look",
      },
    ],
  });
  const base = {
    name: "sky batch",
    added: 1,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    nothingFoundAllowed: ["14"],
  };

  assert.equal(evaluateStep({ ...base, answer: partial }).passed, true);
  assert.match(evaluateStep({ ...base, nothingFoundAllowed: [], answer: partial }).problem, /tool failed/);
});

test("an expected refusal fails when the tool answered unknown without naming Update AI Settings", () => {
  const unknown = answerOf({ outcome: "unknown", error: "Lightroom may have changed the photo" });
  const step = evaluateStep({
    name: "people refused with cleanup",
    added: 0,
    expectRefusal: true,
    admission: admitted(),
    answer: unknown,
    before: raw([]),
    after: raw([]),
  });

  assert.equal(
    step.problem,
    "expected a refusal with nothing changed (outcome failed, or unknown naming Update AI Settings), got unknown: Lightroom may have changed the photo",
  );
});

const versionTable = { major: 16, minor: 0, revision: 0, build: 1234567 };
const status = { running: { version: "16.0", build: "16.0.0 build 1234567", version_table: versionTable } };

test("depth range counts as exercised only when a depth photo was supplied and Lightroom read its depth map", () => {
  const depthStep = (answer, after = raw([{}])) => ({
    name: "depth range",
    added: 1,
    answer,
    before: raw([]),
    after,
    admission: admitted(),
  });
  const noDepth = answerOf({
    outcome: "failed",
    error:
      "Lightroom found no depth map on this photo, so a depth range would select nothing; depth range needs device depth such as an iPhone Portrait HEIC",
  });
  const judged = (evidence) => {
    const { steps, notExercised } = judgeRun(evidence);
    return { steps: steps.map((step) => [step.name, step.passed]), notExercised };
  };

  assert.deepEqual(judged([]), { steps: [], notExercised: NOT_EXERCISED });
  assert.deepEqual(judged([depthStep(ok)]), { steps: [["depth range", true]], notExercised: [] });
  assert.deepEqual(judged([depthStep(ok, raw([]))]), { steps: [["depth range", false]], notExercised: [] });
  assert.deepEqual(judged([depthStep(noDepth, raw([]))]), {
    steps: [],
    notExercised: ["depth range (Lightroom found no depth map in the supplied depth photo)"],
  });
  assert.deepEqual(
    judged([depthStep(answerOf({ outcome: "unknown", error: "Lightroom found no depth map on this photo" }), raw([]))]),
    { steps: [["depth range", false]], notExercised: [] },
  );
});

test("the record names the running build, the exercised process versions, the time, the checks and what it does not exercise", () => {
  const steps = [
    { name: "linear create", passed: true, rendered: true, process_version: "15.4" },
    { name: "sky batch", passed: true, rendered: false, process_version: "15.4" },
  ];

  assert.deepEqual(
    buildCertificationRecord(status, steps, new Date("2026-11-12T10:00:00Z"), { kitCommit: "abc1234" }),
    {
      lightroom: { version: "16.0", build: "16.0.0 build 1234567", version_table: versionTable },
      process_versions: ["15.4"],
      certified_at: "2026-11-12T10:00:00.000Z",
      checks: ["linear create", "sky batch"],
      rendered_checks: ["linear create"],
      not_exercised: [
        "local slider stored scales (written and checked through the plug-in's own LOCAL_KEYS formula, so not observed independently)",
        ...NOT_EXERCISED,
      ],
      kit_commit: "abc1234",
      thresholds: THRESHOLDS,
    },
  );
  assert.equal(
    buildCertificationRecord(status, steps, new Date(), { judgedFrom: "/runs/a.json" }).judged_from,
    "/runs/a.json",
  );
});

test("a stale static range keeps the mask record and fails the run, naming the key with both ranges", () => {
  const steps = [{ name: "linear create", passed: true, rendered: true, process_version: "15.4" }];
  const ranges = {
    compared: ["Contrast2012"],
    stale_ranges: [{ key: "Contrast2012", table: [-100, 100], live: [-100, 150] }],
    not_compared: [{ key: "Temperature", reason: "range depends on the photo", live: [1500, 50000] }],
  };

  const result = certificationResult(status, steps, new Date("2026-11-12T10:00:00Z"), { kitCommit: "abc1234", ranges });

  assert.deepEqual(result.record.checks, ["linear create"]);
  assert.deepEqual(result.record.ranges, { build: "16.0.0 build 1234567", ...ranges });
  assert.equal(result.exitCode, 1);
  assert.match(result.lines.join("\n"), /Contrast2012: table \[-100,100\], Lightroom \[-100,150\]/);
});

test("a run whose compared ranges all match exits cleanly", () => {
  const steps = [{ name: "linear create", passed: true, rendered: true, process_version: "15.4" }];

  const result = certificationResult(status, steps, new Date(), {
    ranges: { compared: ["Exposure2012"], stale_ranges: [], not_compared: [] },
  });

  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.lines, []);
});

test("no record is built when any check failed or none ran", () => {
  const steps = [
    { name: "linear create", passed: true, process_version: "15.4" },
    { name: "sky batch", passed: false, problem: "tool failed: x" },
  ];

  assert.throws(() => buildCertificationRecord(status, steps, new Date()), /sky batch: tool failed: x/);
  assert.throws(() => buildCertificationRecord(status, [], new Date()), /no checks ran/);
  assert.throws(
    () => buildCertificationRecord({ running: { version: "16.0", build: null } }, steps.slice(0, 1), new Date()),
    /reports no build number/,
  );
});

test("--rejudge writes the record from a run file alone, with a corrected threshold, without Lightroom", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lragent-rejudge-"));
  const certificationFile = path.join(directory, "mask-certification.json");
  const runFile = path.join(directory, "run.json");
  const step = {
    name: "Background created",
    added: 1,
    answer: ok,
    before: raw([]),
    after: raw([{}]),
    admission: admitted(),
    rendered: { check: "darkens_within", measured: { darkened: 0.2, share_in_region: 0.65, brightened: 0 } },
  };
  fs.writeFileSync(
    runFile,
    JSON.stringify({
      status: { ...status, certification_file: certificationFile },
      kit_commit: "abc1234",
      thresholds: THRESHOLDS,
      steps: [step],
      ranges: { compared: [], stale_ranges: [], not_compared: [] },
    }),
  );
  const script = path.join(REPO_ROOT, "tests", "e2e", "live", "certify-mask-writes.mjs");
  try {
    assert.equal(spawnSync(process.execPath, [script, "--rejudge", runFile], { encoding: "utf8" }).status, 1);
    assert.equal(fs.existsSync(certificationFile), false);

    const relaxed = spawnSync(
      process.execPath,
      [script, "--rejudge", runFile, "--threshold", "min_share_in_region=0.6"],
      { encoding: "utf8" },
    );
    assert.equal(relaxed.status, 0, relaxed.stderr);
    const record = JSON.parse(fs.readFileSync(certificationFile, "utf8"));
    assert.deepEqual(
      [record.checks, record.thresholds.min_share_in_region, record.judged_from, record.kit_commit],
      [["Background created"], 0.6, runFile, "abc1234"],
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("the record replaces the file whole and leaves no temporary file", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lragent-cert-"));
  const file = path.join(directory, "nested", "mask-certification.json");
  try {
    writeCertification(file, { a: 1 });
    writeCertification(file, { a: 2 });

    assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { a: 2 });
    assert.deepEqual(fs.readdirSync(path.dirname(file)), ["mask-certification.json"]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("the plug-in admits the catalog the kit marks, by the same marker file name", () => {
  const admission = fs.readFileSync(
    path.join(REPO_ROOT, "plugin", "LightroomAgent.lrplugin", "MaskWriteAdmission.lua"),
    "utf8",
  );

  assert.equal(admission.match(/THROWAWAY_MARKER_FILE = "([^"]+)"/)?.[1], THROWAWAY_MARKER_FILE);
});

const fixtureSettings = (overrides = {}) => ({
  MaskGroupBasedCorrections: [],
  RetouchAreas: [],
  FilterList: { Filters: [] },
  CropLeft: 0,
  CropTop: 0,
  CropRight: 1,
  CropBottom: 1,
  CropAngle: 0,
  Exposure2012: 0,
  Contrast2012: 0,
  Highlights2012: 0,
  Shadows2012: 0,
  Whites2012: 0,
  Blacks2012: 0,
  Texture: 0,
  Clarity2012: 0,
  Dehaze: 0,
  Vibrance: 0,
  Saturation: 0,
  WhiteBalance: "As Shot",
  ...overrides,
});

test("a fixture in the certified state, read with its lists and keys or with them absent, has no problems", () => {
  assert.deepEqual(fixtureStateProblems(fixtureSettings()), []);
  assert.deepEqual(fixtureStateProblems({}), []);
});

test("a fixture's baseline adds its profile: a raw on Adobe Standard with the Adobe Color Look, a non-raw with no Look", () => {
  const raw = fixtureSettings({ CameraProfile: "Adobe Standard", Look: { Name: "Adobe Color" } });
  assert.deepEqual(fixtureBaselineProblems(raw, true), []);
  assert.deepEqual(
    fixtureBaselineProblems({ ...raw, ConvertToGrayscale: true, Look: { Name: "Adobe Monochrome" } }, true),
    ["ConvertToGrayscale", "Look"],
  );
  assert.deepEqual(fixtureBaselineProblems({ ...raw, CameraProfile: "Camera Standard" }, true), ["CameraProfile"]);
  assert.deepEqual(fixtureBaselineProblems(fixtureSettings({ CameraProfile: "Embedded" }), false), []);
  assert.deepEqual(fixtureBaselineProblems(fixtureSettings({ Look: { Name: "Adobe Color" } }), false), ["Look"]);
  assert.deepEqual(
    [isRawFixture("_DSC0009.ARW"), isRawFixture("IMG_1.cr3"), isRawFixture("wide_plain.jpg"), isRawFixture(undefined)],
    [true, true, false, false],
  );
});

const editedFixtures = [
  ["a mask", { MaskGroupBasedCorrections: [{ CorrectionID: "A" }] }, ["MaskGroupBasedCorrections"]],
  ["a spot", { RetouchAreas: [{}] }, ["RetouchAreas"]],
  ["an Enhance filter", { FilterList: { Filters: [{}] } }, ["FilterList"]],
  ["a crop", { CropRight: 0.8, CropAngle: 2 }, ["CropRight", "CropAngle"]],
  ["a slider", { Exposure2012: 0.5 }, ["Exposure2012"]],
  ["a white balance", { WhiteBalance: "Custom" }, ["WhiteBalance"]],
  ["black and white", { ConvertToGrayscale: true }, ["ConvertToGrayscale"]],
  [
    "a Transform",
    { PerspectiveVertical: 10, PerspectiveScale: 90, PerspectiveUpright: 1 },
    ["PerspectiveVertical", "PerspectiveScale", "PerspectiveUpright"],
  ],
  [
    "an HSL adjustment",
    { HueAdjustmentRed: 5, LuminanceAdjustmentBlue: -20 },
    ["HueAdjustmentRed", "LuminanceAdjustmentBlue"],
  ],
];
for (const [what, overrides, keys] of editedFixtures) {
  test(`a fixture that still carries ${what} names the keys that differ`, () => {
    assert.deepEqual(fixtureStateProblems(fixtureSettings(overrides)), keys);
  });
}

test("only fixtures the reset answered as reset are proven; unknown and missing ones need a read", () => {
  const answer = {
    data: {
      results: [
        { photo_id: "1", status: "reset" },
        { photo_id: "2", status: "unknown" },
      ],
    },
    envelope: { unknown: [{ photo_id: "3" }] },
  };
  assert.deepEqual(fixturesNotProvenReset(answer, ["1", "2", "3", "4"]), ["2", "3", "4"]);
  assert.deepEqual(fixturesNotProvenReset({ data: { results: [{ photo_id: "1", status: "reset" }] } }, ["1"]), []);
});

test("a fixture the state read did not return, or returned edited, keeps certification from running", () => {
  const read = {
    photos: [
      { photo_id: "2", settings: fixtureSettings() },
      { photo_id: "3", settings: fixtureSettings({ Exposure2012: 1 }) },
    ],
  };
  assert.deepEqual(uncertifiedFixtures(read, ["2", "3", "4"]), [
    { photo_id: "3", keys: ["Exposure2012"] },
    { photo_id: "4", keys: ["not returned by the read"] },
  ]);
  assert.deepEqual(uncertifiedFixtures(read, ["2"]), []);
});

const W = 200,
  H = 120;
const frame = (luminance) => {
  const L = new Float64Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) L[y * W + x] = luminance(x / W, y / H);
  return { w: W, h: H, L };
};
const sceneLuminance = (fx, fy) => (fy < 0.3 ? 0.9 : fy > 0.88 ? 0.85 : 0.4);
const skyStep = REGION_RENDERS["sky batch"];
const judgeSky = (after) =>
  renderPasses(regionRender(skyStep, regionDeltas(frame(sceneLuminance), frame(after), skyStep.regions)));

test("the sky batch passes a Sky that darkens the sky and also bright non-sky surfaces near the bottom", () => {
  assert.equal(
    judgeSky((fx, fy) => sceneLuminance(fx, fy) - (fy < 0.3 || fy > 0.88 ? 0.05 : 0)),
    true,
  );
});

test("the sky batch fails a darkening of the whole frame and an unchanged frame", () => {
  assert.equal(
    judgeSky((fx, fy) => sceneLuminance(fx, fy) - 0.1),
    false,
  );
  assert.equal(judgeSky(sceneLuminance), false);
});

test("clearMasks deletes the masks of each photo that holds some and names those photos", async () => {
  const counts = { 1: 3, 2: 0, 3: 1 };
  const calls = [];
  const toolData = async (name, args) => {
    calls.push([name, args]);
    return name === "list_masks" ? { count: counts[args.photo_ids[0]] } : {};
  };

  const cleared = await clearMasks(toolData, ["1", "2", "3"]);

  assert.deepEqual(cleared, ["1", "3"]);
  assert.deepEqual(
    calls.filter(([name]) => name === "delete_masks"),
    [
      ["delete_masks", { photo_ids: ["1"], all: true }],
      ["delete_masks", { photo_ids: ["3"], all: true }],
    ],
  );
});
