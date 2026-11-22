#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
const photoId = requireFixtureId(marker, "arw_14bit");
const changedRatings = [];
let initial;
let originalRating;
let exposureChanged = false;
let exportDirectory;

async function tool(name, args) {
  const result = await session.tool(name, args);
  assert.equal(result.isError, false, result.text);
  return result.data;
}

try {
  initial = (await session.developSettings(photoId, ["Exposure2012"])).settings;
  originalRating = (await session.photoMetadata(photoId)).rating;
  const top = await tool("search_photos", { rating: 5, limit: 1000 });
  assert.equal(top.has_more, false, "test catalog has more than 1000 five-star photos");
  for (const photo of top.photos) {
    if (String(photo.photo_id) !== String(photoId)) changedRatings.push(photo.photo_id);
  }
  if (changedRatings.length) await tool("set_rating_and_flag", { photo_ids: changedRatings, rating: 4 });
  await tool("set_rating_and_flag", { photo_ids: [photoId], rating: 5 });
  exposureChanged = true;
  await tool("set_develop_settings", { photo_id: photoId, settings: { Exposure2012: 0.5 } });
  const summary = await tool("summarize_develop_settings", { min_rating: 5 });
  assert.equal(summary.scanned, 1);
  assert.equal(summary.matched, 1);
  assert.equal(summary.groups.length, 1);
  assert.equal(summary.groups[0].settings.Exposure2012.median, 0.5);
  assert.equal(summary.groups[0].count, 1);
  console.log(JSON.stringify({ check: "single-photo", summary }));
  exportDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "lightroom-agent-style-export-"));
  const exported = await tool("export_photos", {
    photo_ids: [photoId],
    destination: exportDirectory,
    format: "jpeg",
    quality: 80,
    width: 1200,
    on_existing: "rename",
  });
  assert.equal(exported.files.length, 1);
  const exportedSummary = await tool("summarize_develop_settings", { min_rating: 5, exported_only: true });
  assert.equal(exportedSummary.scanned, 1);
  assert.equal(exportedSummary.groups[0].settings.Exposure2012.median, 0.5);
  console.log(JSON.stringify({ check: "exported-selection", summary: exportedSummary }));
} finally {
  try {
    if (exposureChanged) {
      await tool("set_develop_settings", { photo_id: photoId, settings: { Exposure2012: initial.Exposure2012 } });
    }
  } finally {
    try {
      if (originalRating !== undefined)
        await tool("set_rating_and_flag", { photo_ids: [photoId], rating: originalRating });
      if (changedRatings.length) await tool("set_rating_and_flag", { photo_ids: changedRatings, rating: 5 });
      if (originalRating !== undefined) assert.equal((await session.photoMetadata(photoId)).rating, originalRating);
      if (initial)
        assert.equal(
          (await session.developSettings(photoId, ["Exposure2012"])).settings.Exposure2012,
          initial.Exposure2012,
        );
    } finally {
      if (exportDirectory) fs.rmSync(exportDirectory, { recursive: true });
      await session.stop();
    }
  }
}

assert.equal(marker.batch?.ids?.length, 200, "import the 200-photo batch before the budget check");
const batch = await openLiveSession();
try {
  const result = await batch.session.tool("summarize_develop_settings", { min_rating: 0, max_photos: 200 });
  assert.equal(result.isError, false, result.text);
  assert.equal(result.data.scanned, 200);
  assert.ok(result.data.matched >= 200);
  assert.ok(result.ms < 30_000, `summary took ${result.ms} ms`);
  for (const group of result.data.groups) assert.ok(JSON.stringify(group).length <= 6000);
  console.log(JSON.stringify({ check: "200-photo-budget", ms: result.ms, summary: result.data }));
} finally {
  await batch.session.stop();
}
