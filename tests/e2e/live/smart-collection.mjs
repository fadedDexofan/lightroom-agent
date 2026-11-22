#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const ROW_KEYS = ["is_smart", "name", "photo_count"];

const report = createReport("smart collection refuses added photos (proof x, C41)");
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args)).data;
const board = String(requireFixtureId(marker, "checkerboard"));
const name = `LRAGENT live smart ${Date.now()}`;
const rowOf = async (collection) =>
  (await data("list_collections", { limit: 1000 })).collections.find((row) => row.name === collection);
let created = null;

try {
  created = (await data("create_smart_collection", { name, filename: "lragent-live-no-such-file" })).path;
  const row = await rowOf(created);
  report.check(
    "list_collections lists the smart collection as a row of name, is_smart and photo_count, smart and empty",
    row !== undefined &&
      JSON.stringify(Object.keys(row).sort()) === JSON.stringify(ROW_KEYS) &&
      row.is_smart === true &&
      row.photo_count === 0,
    { created, row },
  );

  const refused = await session.tool("add_to_collection", { collection_name: created, photo_ids: [board] });
  const after = await rowOf(created);
  report.check(
    "add_to_collection on a smart collection is refused with nothing added",
    refused.outcome === "failed" &&
      refused.envelope.error?.includes(`Cannot add or remove photos in a smart collection: ${created}`) &&
      after?.photo_count === 0,
    { reply: refused.envelope, after },
  );
  report.finish({ collection: created });
} finally {
  if (created) await session.tool("delete_collection", { collection_name: created });
  await session.stop();
}
