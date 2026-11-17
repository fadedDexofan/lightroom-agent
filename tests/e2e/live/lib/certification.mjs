import fs from "node:fs";
import path from "node:path";
import { describeMismatch, observedScales, storedMismatch } from "./local-scales.mjs";

const entriesOf = (rawAnswer) => {
  const entries = rawAnswer?.settings?.MaskGroupBasedCorrections;
  return Array.isArray(entries) ? entries : [];
};

export function maskCount(rawAnswer) {
  return entriesOf(rawAnswer).length;
}

function sliderProblem({ key, value }, before, after) {
  const known = new Set(entriesOf(before).map((entry) => entry.CorrectionID));
  const mismatch = storedMismatch(key, value, entriesOf(after).find((entry) => !known.has(entry.CorrectionID)));
  return mismatch ? describeMismatch(mismatch) : null;
}

function observation({ keys, values }, answer, after) {
  const entry = entriesOf(after).find((candidate) => String(candidate.CorrectionID) === String(answer.data?.mask_id));
  return observedScales(keys, values, entry, answer.data?.unchanged ?? []);
}

const errorOf = (answer) => answer.envelope?.error ?? answer.text;

export const NOT_EXERCISED = ["depth range (needs a photo with device depth)"];
const NO_DEPTH_MAP_READ = ["depth range (Lightroom found no depth map in the supplied depth photo)"];

export function depthCoverage(run) {
  if (!run) return { step: null, notExercised: NOT_EXERCISED };
  if (run.answer.outcome === "failed" && /found no depth map/.test(errorOf(run.answer))) return { step: null, notExercised: NO_DEPTH_MAP_READ };
  return { step: run.step, notExercised: [] };
}

export function requireThrowaway(status) {
  if (status?.throwaway_catalog !== true) {
    throw new Error("the open catalog is not the live kit's throwaway catalog; nothing certified");
  }
}

function problemOf({ added, expectRefusal, answer, before, after, admission, rendered, slider, observed }) {
  if (expectRefusal && !answer.isError) return "expected a refusal, the tool succeeded";
  if (expectRefusal && answer.outcome !== "failed") {
    return `expected a refusal with nothing changed (outcome failed), got ${answer.outcome}: ${errorOf(answer)}`;
  }
  if (!expectRefusal && answer.isError) return `tool failed: ${errorOf(answer)}`;
  const found = maskCount(after) - maskCount(before);
  if (found !== added) return `expected ${added} mask(s) added, found ${found}`;
  const problems = admission?.photo?.schema_problems;
  if (!Array.isArray(problems)) return "the admission read returned no schema check for the photo";
  if (problems.length > 0) return `masks left the pinned format: ${problems.join("; ")}`;
  if (slider) {
    const mismatch = sliderProblem(slider, before, after);
    if (mismatch) return mismatch;
  }
  if (observed) {
    const { mismatches } = observation(observed, answer, after);
    if (mismatches.length > 0) return mismatches.map(describeMismatch).join("; ");
  }
  if (rendered && !rendered.passed) return `rendered check failed: ${JSON.stringify(rendered.detail)}`;
  return null;
}

export function evaluateStep(step) {
  const problem = problemOf(step);
  if (problem) return { name: step.name, passed: false, problem };
  const passed = { name: step.name, passed: true, rendered: Boolean(step.rendered), process_version: step.after.settings.ProcessVersion };
  if (!step.observed) return passed;
  return { ...passed, not_observed: observation(step.observed, step.answer, step.after).notObserved };
}

export function buildCertificationRecord(status, steps, now, { kitCommit, notExercised = NOT_EXERCISED, ranges } = {}) {
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
    not_exercised: notExercised,
    kit_commit: kitCommit ?? null,
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
