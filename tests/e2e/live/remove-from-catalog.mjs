#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import readline from "node:readline/promises";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { requireThrowawayCatalog } from "./lib/catalog-guard.mjs";

const { marker, catalogPath, session } = await openLiveSession();
const disposableDirectory = path.join(path.dirname(catalogPath), `remove-check-${randomUUID()}`);
const survivorId = requireFixtureId(marker, "wide_plain");
const source = marker.fixtures.wide_plain.path;
const copies = [];
try {
  requireThrowawayCatalog();
  fs.mkdirSync(disposableDirectory);
  for (let i = 0; i < 3; i++) {
    const file = path.join(disposableDirectory, `remove-${i}.jpg`);
    fs.copyFileSync(source, file);
    const imported = await session.toolOrThrow("import_photos", { source_path: file });
    assert.equal(imported.data.imported, 1);
    const found = await session.toolOrThrow("search_photos", {
      filename: path.basename(file),
      limit: 100,
      include_path: true,
    });
    const photo = found.data.photos.find((photo) => photo.path === file);
    assert.ok(photo, `imported copy missing: ${file}`);
    copies.push({ id: photo.photo_id, file });
  }
  const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
  await prompt.question(
    `In Lightroom's All Photographs, select exactly photos ${survivorId} (${path.basename(source)})` +
      ` and ${copies[0].id} (${path.basename(copies[0].file)}), then press Enter. `,
  );
  prompt.close();
  const selectionBefore = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(
    new Set(selectionBefore.data.photos.map((photo) => photo.photo_id)),
    new Set([survivorId, copies[0].id].map(String)),
  );
  const before = await session.toolOrThrow("search_photos", { limit: 1 });
  for (const confirm of [undefined, false, "true"]) {
    const answer = await session.tool("remove_photos_from_catalog", { photo_ids: [copies[0].id], confirm });
    assert.equal(answer.isError, true);
  }
  const selected = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(
    selected.data.photos.map((photo) => photo.photo_id),
    selectionBefore.data.photos.map((photo) => photo.photo_id),
  );
  requireThrowawayCatalog();
  const removed = await session.toolOrThrow("remove_photos_from_catalog", {
    photo_ids: [copies[0].id, copies[1].id, copies[0].id],
    confirm: true,
  });
  assert.equal(removed.data.removed, 2);
  const after = await session.toolOrThrow("search_photos", { limit: 1 });
  assert.equal(after.data.count, before.data.count - 2);
  for (const copy of copies) assert.equal(fs.existsSync(copy.file), true);
  const restored = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(
    restored.data.photos.map((photo) => photo.photo_id),
    [String(survivorId)],
  );
  for (const fixture of Object.values(marker.fixtures)) {
    await session.photoMetadata(fixture.id);
  }
  await session.photoMetadata(copies[2].id);
  requireThrowawayCatalog();
  const cleanup = await session.toolOrThrow("remove_photos_from_catalog", {
    photo_ids: [copies[2].id],
    confirm: true,
  });
  assert.equal(cleanup.data.removed, 1);
  for (const copy of copies) assert.equal(fs.existsSync(copy.file), true);
  console.log(
    JSON.stringify({
      passed: true,
      catalogPath,
      copies,
      removed: 3,
      checks: [
        "confirm guard",
        "two-photo removal",
        "duplicate IDs",
        "files remain",
        "unrelated fixtures remain",
        "surviving selection restored",
      ],
    }),
  );
} finally {
  await session.stop();
}
