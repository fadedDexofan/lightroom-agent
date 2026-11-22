#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const report = createReport("export and import paths in the caller's spelling");
const { session, marker } = await openLiveSession();
const root = fs.mkdtempSync("/tmp/lragent-paths-");
const spelled = path.join("/tmp", path.basename(root));
let importedId = null;

try {
  const exported = (
    await session.toolOrThrow(
      "export_photos",
      {
        photo_ids: [requireFixtureId(marker, "wide_plain")],
        destination: path.join(spelled, "export"),
        format: "jpeg",
        width: 400,
      },
      { timeoutMs: 180_000 },
    )
  ).data;
  const files = (exported.files ?? []).map((file) => file.path ?? file);
  report.check(
    "export_photos names its files under the destination as spelled",
    files.length === 1 && files[0].startsWith(`${spelled}/export/`) && fs.existsSync(files[0]),
    { files },
  );

  const sourceDirectory = path.join(root, "source");
  fs.mkdirSync(sourceDirectory);
  const name = "lragent-paths-long-original-name.jpg";
  fs.copyFileSync(files[0], path.join(sourceDirectory, name));
  const imported = (
    await session.toolOrThrow(
      "import_photos",
      {
        source_path: path.join(spelled, "source", name),
        copy_to: path.join(spelled, "copied"),
      },
      { timeoutMs: 180_000 },
    )
  ).data;
  const copied = fs.existsSync(path.join(root, "copied"))
    ? fs.readdirSync(path.join(root, "copied"), { recursive: true })
    : [];
  report.check(
    "import_photos copy_to keeps the whole file name",
    imported?.imported === 1 && copied.some((entry) => String(entry).endsWith(name)),
    { imported, copied },
  );
  const found = (await session.toolOrThrow("search_photos", { filename: name, limit: 5 })).data.photos;
  importedId = found[0]?.photo_id ?? null;
  report.finish({ root });
} finally {
  if (importedId) await session.tool("remove_photos_from_catalog", { photo_ids: [importedId], confirm: true });
  fs.rmSync(root, { recursive: true, force: true });
  await session.stop();
}
