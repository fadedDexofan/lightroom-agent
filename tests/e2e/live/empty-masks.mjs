#!/usr/bin/env node
import { openLiveSession } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const at = process.argv.indexOf("--empty-group");
const photoId = at === -1 ? null : process.argv[at + 1];
if (!photoId)
  throw new Error(
    "usage: empty-masks.mjs --empty-group <photo id holding a mask group with no components> [--evidence <file>]",
  );

const report = createReport(
  "delete_empty_masks removes a mask group with no components and keeps a gradient without adjustments",
);
const { session } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 120_000 })).data;
const groups = async () =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections"] })).photos[0].settings
    .MaskGroupBasedCorrections ?? [];
const idsOf = (list) => list.map((group) => String(group.CorrectionID));

try {
  const before = await groups();
  const emptyIds = idsOf(before.filter((group) => (group.CorrectionMasks ?? []).length === 0));
  const plain = await data("create_gradient_mask", {
    photo_ids: [photoId],
    shape: "linear",
    start: { x: 0.1, y: 0.5 },
    end: { x: 0.2, y: 0.5 },
  });
  const removed = await data("delete_empty_masks", { photo_ids: [photoId] });
  const left = idsOf(await groups());
  report.check("the photo held a mask group with no components before the call", emptyIds.length > 0, {
    groups: idsOf(before),
    empty: emptyIds,
  });
  report.check(
    "the group with no components is gone and the gradient without adjustments stays",
    emptyIds.every((id) => !left.includes(id)) && left.includes(String(plain.mask_id)),
    { removed, empty: emptyIds, plain: plain.mask_id, left },
  );
  report.finish({ photo_id: photoId });
} finally {
  await session.stop();
}
