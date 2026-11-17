import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  buildCertificationRecord,
  certificationResult,
  depthCoverage,
  evaluateStep,
  maskCount,
  NOT_EXERCISED,
  requireThrowaway,
  writeCertification,
} from "../lib/certification.mjs";
import { REPO_ROOT, THROWAWAY_MARKER_FILE } from "../lib/paths.mjs";

const raw = (entries, processVersion = "15.4") => ({
  settings: { ProcessVersion: processVersion, ...(entries === undefined ? {} : { MaskGroupBasedCorrections: entries }) },
});
const admitted = (problems = []) => ({ photo: { schema_problems: problems } });
const answerOf = (envelope) => ({
  isError: envelope.outcome !== "done", text: JSON.stringify(envelope), envelope, outcome: envelope.outcome, data: envelope.data,
});
const ok = answerOf({ outcome: "done", data: { mask_id: "a" } });
const refused = answerOf({ outcome: "failed", error: "Lightroom found no face_skin on any person in photo 2139; no mask was left on the photo" });

test("a photo without the mask setting counts as zero masks", () => {
  assert.equal(maskCount(raw(undefined)), 0);
  assert.equal(maskCount(raw([])), 0);
  assert.equal(maskCount(raw([{}, {}])), 2);
});

test("a write passes when it succeeds, adds the expected masks and leaves every mask in the pinned format", () => {
  const step = evaluateStep({ name: "linear create", added: 1, answer: ok, before: raw([]), after: raw([{}]), admission: admitted() });

  assert.deepEqual(step, { name: "linear create", passed: true, rendered: false, process_version: "15.4" });
});

test("a write with a rendered check passes only when the rendered check passed", () => {
  const base = { name: "linear create", added: 1, answer: ok, before: raw([]), after: raw([{}]), admission: admitted() };

  assert.equal(evaluateStep({ ...base, rendered: { passed: true, detail: { left: 0.2 } } }).rendered, true);
  assert.match(evaluateStep({ ...base, rendered: { passed: false, detail: { left: 0.001 } } }).problem, /rendered check failed: \{"left":0.001\}/);
});

test("the command refuses a catalog without the kit marker", () => {
  assert.throws(() => requireThrowaway({ throwaway_catalog: false }), /not the live kit's throwaway catalog/);
  assert.throws(() => requireThrowaway(undefined), /not the live kit's throwaway catalog/);
  assert.doesNotThrow(() => requireThrowaway({ throwaway_catalog: true }));
});

test("a write fails when the tool errs, the mask count is off or Lightroom's entries leave the pinned format", () => {
  const base = { name: "radial create", added: 1, before: raw([]), after: raw([{}]), admission: admitted() };

  assert.match(evaluateStep({ ...base, answer: answerOf({ outcome: "failed", error: "boom" }) }).problem, /tool failed: boom/);
  assert.match(evaluateStep({ ...base, answer: ok, after: raw([]) }).problem, /expected 1 mask\(s\) added, found 0/);
  assert.match(
    evaluateStep({ ...base, answer: ok, admission: admitted(["existing mask 1 component 1: unexpected field Spacing"]) }).problem,
    /pinned format: existing mask 1 component 1: unexpected field Spacing/,
  );
});

test("an expected refusal passes only when the tool refused and left the photo's masks as they were", () => {
  const base = { name: "people refused with cleanup", added: 0, expectRefusal: true, admission: admitted() };

  assert.equal(evaluateStep({ ...base, answer: refused, before: raw(undefined), after: raw([]) }).passed, true);
  assert.match(evaluateStep({ ...base, answer: ok, before: raw([]), after: raw([]) }).problem, /expected a refusal/);
  assert.match(evaluateStep({ ...base, answer: refused, before: raw([]), after: raw([{}]) }).problem, /expected 0 mask\(s\) added, found 1/);
});

test("an expected refusal fails when the tool answered unknown instead of failed", () => {
  const unknown = answerOf({ outcome: "unknown", error: "Lightroom may have changed the photo" });
  const step = evaluateStep({ name: "people refused with cleanup", added: 0, expectRefusal: true, admission: admitted(), answer: unknown, before: raw([]), after: raw([]) });

  assert.equal(step.problem, "expected a refusal with nothing changed (outcome failed), got unknown: Lightroom may have changed the photo");
});

const moire = { name: "local_Moire", range: [-100, 100], tolerance: 0.5, stored: "LocalMoire", scale: 100 };

test("a slider creation passes only when the new mask stores the written value at the table's scale", () => {
  const base = { name: "local scale Moire", added: 1, answer: ok, before: raw([{ CorrectionID: "a", LocalMoire: 9 }]), admission: admitted() };
  const created = (stored) => raw([{ CorrectionID: "a", LocalMoire: 9 }, { CorrectionID: "b", LocalMoire: stored }]);

  assert.equal(evaluateStep({ ...base, after: created(0.5), slider: { key: moire, value: 50 } }).passed, true);
  assert.equal(
    evaluateStep({ ...base, after: created(50), slider: { key: moire, value: 50 } }).problem,
    "local_Moire written 50: expected LocalMoire 0.5, stored 50",
  );
});

const exposureKey = { name: "local_Exposure", range: [-4, 4], tolerance: 0.01, stored: "LocalExposure2012", scale: 4 };

test("an observation of Lightroom's stored scale fails on any mismatch and passes listing what it could not observe", () => {
  const keys = [exposureKey, moire];
  const values = { local_Exposure: 1, local_Moire: 25 };
  const set = answerOf({ outcome: "done", data: { mask_id: "b", unchanged: [] } });
  const base = { name: "Lightroom's stored scale", added: 0, answer: set, before: raw([{ CorrectionID: "a" }, { CorrectionID: "b" }]), admission: admitted() };
  const after = (fields) => raw([{ CorrectionID: "a", LocalMoire: 0.25 }, { CorrectionID: "b", ...fields }]);

  assert.deepEqual(evaluateStep({ ...base, after: after({ LocalExposure2012: 0.25 }), observed: { keys, values } }), {
    name: "Lightroom's stored scale", passed: true, rendered: false, process_version: "15.4", not_observed: ["local_Moire"],
  });
  assert.equal(
    evaluateStep({ ...base, after: after({ LocalExposure2012: 1, LocalMoire: 25 }), observed: { keys, values } }).problem,
    "local_Exposure written 1: expected LocalExposure2012 0.25, stored 1; local_Moire written 25: expected LocalMoire 0.25, stored 25",
  );
});

const versionTable = { major: 16, minor: 0, revision: 0, build: 1234567 };
const status = { running: { version: "16.0", build: "16.0.0 build 1234567", version_table: versionTable } };

test("depth range counts as exercised only when a depth photo was supplied and Lightroom read its depth map", () => {
  const passedStep = { name: "depth range", passed: true };
  const failedStep = { name: "depth range", passed: false, problem: "rendered check failed" };
  const noDepth = answerOf({ outcome: "failed", error: "Lightroom found no depth map on this photo, so a depth range would select nothing; depth range needs device depth such as an iPhone Portrait HEIC" });
  assert.deepEqual(depthCoverage(null), { step: null, notExercised: NOT_EXERCISED });
  assert.deepEqual(depthCoverage({ step: passedStep, answer: ok }), { step: passedStep, notExercised: [] });
  assert.deepEqual(depthCoverage({ step: failedStep, answer: ok }), { step: failedStep, notExercised: [] });
  assert.deepEqual(depthCoverage({ step: { name: "depth range", passed: false, problem: "tool failed" }, answer: noDepth }),
    { step: null, notExercised: ["depth range (Lightroom found no depth map in the supplied depth photo)"] });
  assert.deepEqual(depthCoverage({ step: failedStep, answer: answerOf({ outcome: "unknown", error: "Lightroom found no depth map on this photo" }) }),
    { step: failedStep, notExercised: [] });
});

test("the record names the running build, the exercised process versions, the time and the checks", () => {
  const steps = [
    { name: "linear create", passed: true, rendered: true, process_version: "15.4" },
    { name: "sky batch", passed: true, rendered: false, process_version: "15.4" },
  ];

  assert.deepEqual(buildCertificationRecord(status, steps, new Date("2026-11-12T10:00:00Z"), { kitCommit: "abc1234" }), {
    lightroom: { version: "16.0", build: "16.0.0 build 1234567", version_table: versionTable },
    process_versions: ["15.4"],
    certified_at: "2026-11-12T10:00:00.000Z",
    checks: ["linear create", "sky batch"],
    rendered_checks: ["linear create"],
    not_exercised: NOT_EXERCISED,
    kit_commit: "abc1234",
  });
});

test("a stale static range keeps the mask record and fails the run, naming the key with both ranges", () => {
  const steps = [{ name: "linear create", passed: true, rendered: true, process_version: "15.4" }];
  const ranges = {
    compared: ["Contrast2012"], stale_ranges: [{ key: "Contrast2012", table: [-100, 100], live: [-100, 150] }],
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

  const result = certificationResult(status, steps, new Date(), { ranges: { compared: ["Exposure2012"], stale_ranges: [], not_compared: [] } });

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

test("the record replaces the file whole and leaves no temporary file", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-cert-"));
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
  const admission = fs.readFileSync(path.join(REPO_ROOT, "plugin", "LightroomMCP.lrplugin", "MaskWriteAdmission.lua"), "utf8");

  assert.equal(admission.match(/THROWAWAY_MARKER_FILE = "([^"]+)"/)?.[1], THROWAWAY_MARKER_FILE);
});
