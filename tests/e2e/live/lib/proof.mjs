import fs from "node:fs";

export function createReport(proof, argv = process.argv) {
  const checks = [];
  const at = argv.indexOf("--evidence");
  const evidenceFile = at === -1 ? null : argv[at + 1];
  return {
    check(label, passed, detail = {}) {
      checks.push({ label, passed: Boolean(passed), detail });
      console.log(`${passed ? "pass" : "FAIL"} ${label} ${JSON.stringify(detail)}`);
      return Boolean(passed);
    },
    finish(extra = {}) {
      const summary = { proof, passed: checks.every((entry) => entry.passed), checks, ...extra };
      if (evidenceFile) fs.writeFileSync(evidenceFile, `${JSON.stringify(summary, null, 2)}\n`);
      console.log(`${summary.passed ? "passed" : "FAILED"} ${proof}${evidenceFile ? `; evidence ${evidenceFile}` : ""}`);
      process.exitCode = summary.passed ? 0 : 1;
      return summary;
    },
  };
}
