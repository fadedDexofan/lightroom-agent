import fs from "node:fs";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";

const entriesOf = (rawAnswer) => {
  const entries = rawAnswer?.settings?.MaskGroupBasedCorrections;
  return Array.isArray(entries) ? entries : [];
};

export function maskCount(rawAnswer) {
  return entriesOf(rawAnswer).length;
}

const errorOf = (answer) => answer.envelope?.error ?? answer.text;

export const DEPTH_STEP = "depth range";
export const NOT_EXERCISED = ["depth range (needs a photo with device depth)"];
const LOCAL_SCALES_NOT_EXERCISED = "local slider stored scales (written and checked through the plug-in's own LOCAL_KEYS formula, so not observed independently)";
const NO_DEPTH_MAP_READ = ["depth range (Lightroom found no depth map in the supplied depth photo)"];

function depthCoverage(step, answer) {
  if (answer?.outcome === "failed" && /found no depth map/.test(errorOf(answer))) return { step: null, notExercised: NO_DEPTH_MAP_READ };
  return { step, notExercised: [] };
}

export function requireThrowaway(status) {
  if (status?.throwaway_catalog !== true) {
    throw new Error("the open catalog is not the live kit's throwaway catalog; nothing certified");
  }
}

const problemPosition = (problem) => {
  const match = /^existing mask (\d+)\b/.exec(problem);
  return match ? Number(match[1]) : null;
};

function writtenBy(before, after) {
  const held = new Map(entriesOf(before).map((entry) => [String(entry.CorrectionID), entry]));
  const positions = new Set();
  entriesOf(after).forEach((entry, index) => {
    if (!isDeepStrictEqual(held.get(String(entry.CorrectionID)), entry)) positions.add(index + 1);
  });
  return positions;
}

export const THRESHOLDS = {
  min_change: 0.05,
  max_untouched_change: 0.01,
  min_radial_iou: 0.8,
  min_changed_share: 0.005,
  min_share_in_region: 0.7,
  min_contrast_change: 0.01,
  min_contrast_ratio: 5,
  max_region_mean_change: 0.01,
};

const RENDER_CHECKS = {
  radial_iou: ({ iou }, t) => iou >= t.min_radial_iou,
  region_moves: ({ deltas, changed, untouched, direction }, t) =>
    (direction > 0 ? deltas[changed] >= t.min_change : deltas[changed] <= -t.min_change) && Math.abs(deltas[untouched]) < t.max_untouched_change,
  region_contrast: ({ deltas, changed, untouched, direction }, t) =>
    direction * deltas[changed] >= t.min_contrast_change && Math.abs(deltas[changed]) >= t.min_contrast_ratio * Math.abs(deltas[untouched]),
  region_means_kept: ({ region_mean_change, rest_mean_change }, t) =>
    Math.abs(region_mean_change) <= t.max_region_mean_change && Math.abs(rest_mean_change) <= t.max_region_mean_change,
  darkens: ({ darkened }, t) => darkened >= t.min_changed_share,
  darkens_within: ({ darkened, share_in_region, brightened }, t) =>
    darkened >= t.min_changed_share && share_in_region >= t.min_share_in_region && brightened < t.min_changed_share,
};

export function renderPasses(rendered, thresholds = THRESHOLDS) {
  return RENDER_CHECKS[rendered.check](rendered.measured, thresholds);
}

const entryOf = (rawAnswer, id) => entriesOf(rawAnswer).find((entry) => String(entry.CorrectionID) === String(id));

const NOTHING_FOUND = /Lightroom found nothing/;
const VOIDED_BY_AI_UPDATE = /Update AI Settings/;

function refusalClass(answer) {
  if (answer.outcome === "failed") return "failed";
  if (answer.outcome === "unknown" && VOIDED_BY_AI_UPDATE.test(errorOf(answer) ?? "")) return "unknown";
  return null;
}

function onlyNothingFound(answer, allowed = []) {
  const stopped = [
    ...(answer.envelope?.failed ?? []).map((entry) => ({ ...entry, voided: false })),
    ...(answer.envelope?.unknown ?? []).map((entry) => ({ ...entry, voided: true })),
  ];
  return answer.outcome === "partial" && stopped.length > 0
    && stopped.every((entry) => allowed.includes(String(entry.photo_id)) && NOTHING_FOUND.test(entry.reason ?? "")
      && (!entry.voided || VOIDED_BY_AI_UPDATE.test(entry.reason)));
}

function problemOf({ failure, added, expectRefusal, answer, before, after, admission, rendered, landed_ms: landedMs, render_cap_ms: capMs, unchangedEntry, nothingFoundAllowed }, thresholds) {
  if (failure) return failure;
  if (expectRefusal && !answer.isError) return "expected a refusal, the tool succeeded";
  if (expectRefusal && refusalClass(answer) === null) {
    return `expected a refusal with nothing changed (outcome failed, or unknown naming Update AI Settings), got ${answer.outcome}: ${errorOf(answer)}`;
  }
  if (!expectRefusal && answer.isError && !onlyNothingFound(answer, nothingFoundAllowed)) return `tool failed: ${errorOf(answer)}`;
  const found = maskCount(after) - maskCount(before);
  if (found !== added) return `expected ${added} mask(s) added, found ${found}`;
  if (expectRefusal && !isDeepStrictEqual(entriesOf(before), entriesOf(after))) return "the masks are not back exactly after the refusal";
  const problems = admission?.photo?.schema_problems;
  if (!Array.isArray(problems)) return "the admission read returned no schema check for the photo";
  const written = writtenBy(before, after);
  const judged = problems.filter((problem) => problemPosition(problem) === null || written.has(problemPosition(problem)));
  if (judged.length > 0) return `masks left the pinned format: ${judged.join("; ")}`;
  if (unchangedEntry !== undefined && !isDeepStrictEqual(entryOf(before, unchangedEntry), entryOf(after, unchangedEntry))) {
    return `entry ${unchangedEntry} changed`;
  }
  if (rendered && !Object.hasOwn(RENDER_CHECKS, rendered.check)) return `rendered check ${rendered.check} is not one this kit judges: ${JSON.stringify(rendered.measured)}`;
  if (rendered && !renderPasses(rendered, thresholds)) {
    const landing = landedMs === null ? `the expected change never landed within ${capMs / 1000} s; ` : "";
    return `${landing}rendered check ${rendered.check} failed: ${JSON.stringify(rendered.measured)}`;
  }
  return null;
}

export function evaluateStep(step, thresholds = THRESHOLDS) {
  const problem = problemOf(step, thresholds);
  if (problem) return { name: step.name, passed: false, problem };
  const passed = { name: step.name, passed: true, rendered: Boolean(step.rendered), process_version: step.after.settings.ProcessVersion };
  return step.expectRefusal ? { ...passed, refusal: refusalClass(step.answer) } : passed;
}

export function judgeRun(evidence, thresholds = THRESHOLDS) {
  const steps = [];
  let notExercised = NOT_EXERCISED;
  for (const entry of evidence) {
    const step = evaluateStep(entry, thresholds);
    if (entry.name !== DEPTH_STEP) {
      steps.push(step);
      continue;
    }
    const depth = depthCoverage(step, entry.answer);
    notExercised = depth.notExercised;
    if (depth.step) steps.push(depth.step);
  }
  return { steps, notExercised };
}

export function buildCertificationRecord(status, steps, now, { kitCommit, notExercised = NOT_EXERCISED, ranges, thresholds = THRESHOLDS, judgedFrom } = {}) {
  if (!status.running.build) throw new Error("Lightroom reports no build number; nothing certified");
  if (steps.length === 0) throw new Error("no checks ran; nothing certified");
  const failed = steps.filter((step) => !step.passed);
  if (failed.length > 0) {
    throw new Error(`certification failed: ${failed.map((step) => `${step.name}: ${step.problem}`).join("; ")}`);
  }
  return {
    lightroom: { version: status.running.version, build: status.running.build, version_table: status.running.version_table },
    process_versions: [...new Set(steps.map((step) => step.process_version))].sort(),
    certified_at: now.toISOString(),
    checks: steps.map((step) => step.name),
    rendered_checks: steps.filter((step) => step.rendered).map((step) => step.name),
    ...(steps.some((step) => step.refusal) ? { refusals: Object.fromEntries(steps.filter((step) => step.refusal).map((step) => [step.name, step.refusal])) } : {}),
    not_exercised: [LOCAL_SCALES_NOT_EXERCISED, ...notExercised],
    kit_commit: kitCommit ?? null,
    thresholds,
    ...(judgedFrom ? { judged_from: judgedFrom } : {}),
    ...(ranges ? { ranges: { build: status.running.build, ...ranges } } : {}),
  };
}

export function certificationResult(status, steps, now, options = {}) {
  const record = buildCertificationRecord(status, steps, now, options);
  const stale = record.ranges?.stale_ranges ?? [];
  const lines = stale.map((entry) => `stale range ${entry.key}: table ${JSON.stringify(entry.table)}, Lightroom ${JSON.stringify(entry.live)}`);
  if (lines.length) lines.push(`${lines.length} static range(s) in DEVELOP_KEYS differ from Lightroom ${record.lightroom.build}; the mask record was written, but correct the table before installing`);
  return { record, exitCode: lines.length ? 1 : 0, lines };
}

export function writeCertification(file, record) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`);
  fs.renameSync(temporary, file);
}
