import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  buildCertificationRecord,
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
const ok = { isError: false, data: { success: true } };
const refused = { isError: true, data: "Lightroom found no face_skin on any person in photo 2139; no mask was left on the photo" };

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

  assert.match(evaluateStep({ ...base, answer: { isError: true, data: "boom" } }).problem, /tool failed: boom/);
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

const versionTable = { major: 16, minor: 0, revision: 0, build: 1234567 };
const status = { running: { version: "16.0", build: "16.0.0 build 1234567", version_table: versionTable } };

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
