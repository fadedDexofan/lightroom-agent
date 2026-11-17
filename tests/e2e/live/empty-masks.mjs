#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const report = createReport("delete_empty_masks removes only masks without adjustments");
const { session, marker } = await openLiveSession();
const photoId = String(requireFixtureId(marker, "wide_plain"));
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 120_000 })).data;
const masks = async () => (await data("list_masks", { photo_id: photoId })).masks.map((mask) => String(mask.id));

try {
  const empty = await data("create_gradient_mask", { photo_id: photoId, shape: "linear", start: { x: 0.1, y: 0.5 }, end: { x: 0.2, y: 0.5 } });
  const kept = await data("create_gradient_mask", { photo_id: photoId, shape: "linear", start: { x: 0.9, y: 0.5 }, end: { x: 0.8, y: 0.5 }, adjustments: { local_Exposure: 0.5 } });
  const removed = await data("delete_empty_masks", { photo_ids: [photoId] });
  const left = await masks();
  report.check("the empty gradient is gone and the adjusted one stays",
    !left.includes(String(empty.mask_id)) && left.includes(String(kept.mask_id)), { removed, empty: empty.mask_id, kept: kept.mask_id, left });
  await data("delete_masks", { photo_id: photoId, mask_ids: [String(kept.mask_id)] });
  report.finish();
} finally {
  await session.stop();
}
