import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export function createReport(proof, argv = process.argv, now = () => new Date()) {
  const checks = [];
  const started = now();
  const at = argv.indexOf("--evidence");
  const evidenceFile = at === -1 ? null : argv[at + 1];
  const previewsDirectory = evidenceFile ? `${evidenceFile.replace(/\.json$/, "")}-previews` : null;
  let previews = 0;
  const write = (summary) => {
    if (evidenceFile) fs.writeFileSync(evidenceFile, `${JSON.stringify(summary, null, 2)}\n`);
  };
  return {
    check(label, passed, detail = {}) {
      checks.push({ label, passed: Boolean(passed), detail });
      console.log(`${passed ? "pass" : "FAIL"} ${label} ${JSON.stringify(detail)}`);
      write({ proof, started_at: started.toISOString(), checks });
      return Boolean(passed);
    },
    preview(name, pixels) {
      if (!previewsDirectory) return null;
      fs.mkdirSync(previewsDirectory, { recursive: true });
      const bytes = Buffer.from(pixels.jpeg, "base64");
      previews += 1;
      const file = path.join(path.basename(previewsDirectory), `${String(previews).padStart(2, "0")}-${name.replace(/[^a-z0-9]+/gi, "-")}.jpg`);
      fs.writeFileSync(path.join(path.dirname(evidenceFile), file), bytes);
      return { file, sha256: createHash("sha256").update(bytes).digest("hex") };
    },
    finish(extra = {}) {
      const finished = now();
      const summary = { proof, passed: checks.every((entry) => entry.passed), started_at: started.toISOString(), finished_at: finished.toISOString(),
        seconds: (finished - started) / 1000, checks, ...extra };
      write(summary);
      console.log(`${summary.passed ? "passed" : "FAILED"} ${proof}${evidenceFile ? `; evidence ${evidenceFile}` : ""}`);
      process.exitCode = summary.passed ? 0 : 1;
      return summary;
    },
  };
}
