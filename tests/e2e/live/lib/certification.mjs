import fs from "node:fs";
import path from "node:path";

export function maskCount(rawAnswer) {
  const entries = rawAnswer?.settings?.MaskGroupBasedCorrections;
  return Array.isArray(entries) ? entries.length : 0;
}

function describeAnswer(answer) {
  return typeof answer.data === "string" ? answer.data : JSON.stringify(answer.data);
}

export const NOT_EXERCISED = ["depth range (needs a photo with device depth)"];

export function requireThrowaway(status) {
  if (status?.throwaway_catalog !== true) {
    throw new Error("the open catalog is not the live kit's throwaway catalog; nothing certified");
  }
}

function problemOf({ added, expectRefusal, answer, before, after, admission, rendered }) {
  if (expectRefusal && !answer.isError) return "expected a refusal, the tool succeeded";
  if (!expectRefusal && answer.isError) return `tool failed: ${describeAnswer(answer)}`;
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

export function buildCertificationRecord(status, steps, now, { kitCommit, notExercised = NOT_EXERCISED } = {}) {
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
  };
}

export function writeCertification(file, record) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`);
  fs.renameSync(temporary, file);
}
