import fs from "node:fs";
import path from "node:path";

const entriesOf = (rawAnswer) => {
  const entries = rawAnswer?.settings?.MaskGroupBasedCorrections;
  return Array.isArray(entries) ? entries : [];
};

export function maskCount(rawAnswer) {
  return entriesOf(rawAnswer).length;
}

const errorOf = (answer) => answer.envelope?.error ?? answer.text;

export const NOT_EXERCISED = ["depth range (needs a photo with device depth)"];
const LOCAL_SCALES_NOT_EXERCISED = "local slider stored scales (written and checked through the plug-in's own LOCAL_KEYS formula, so not observed independently)";
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

function problemOf({ added, expectRefusal, answer, before, after, admission, rendered }) {
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
  if (rendered && !rendered.passed) return `rendered check failed: ${JSON.stringify(rendered.detail)}`;
  return null;
}

export function evaluateStep(step) {
  const problem = problemOf(step);
  if (problem) return { name: step.name, passed: false, problem };
  return { name: step.name, passed: true, rendered: Boolean(step.rendered), process_version: step.after.settings.ProcessVersion };
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
    not_exercised: [LOCAL_SCALES_NOT_EXERCISED, ...notExercised],
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
