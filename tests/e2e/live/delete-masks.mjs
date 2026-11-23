#!/usr/bin/env node
import { isDeepStrictEqual } from "node:util";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const report = createReport(
  "delete_masks by mask id and by tool id removes only what it names from the saved settings",
);
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 120_000 })).data;
const entries = async (photoId) =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections"] })).photos[0].settings
    .MaskGroupBasedCorrections ?? [];
const linear = (y) => ({
  shape: "linear",
  start: { x: 0.5, y },
  end: { x: 0.5, y: y + 0.2 },
  adjustments: { local_Exposure: 0.3 },
});
const radial = { shape: "radial", center: { x: 0.2, y: 0.8 }, width: 0.2, height: 0.2, rotation: 0, feather: 50 };
const unchangedExcept = (before, after, ids) =>
  before
    .filter((entry) => !ids.includes(String(entry.CorrectionID)))
    .filter(
      (entry) =>
        !isDeepStrictEqual(
          entry,
          after.find((candidate) => candidate.CorrectionID === entry.CorrectionID),
        ),
    )
    .map((entry) => entry.CorrectionID);
const componentIds = (entry) => (entry?.CorrectionMasks ?? []).map((component) => String(component.MaskID));

let copy = null;
try {
  copy = String(
    (
      await data("create_virtual_copies", {
        photo_ids: [String(requireFixtureId(marker, "wide_plain"))],
        copy_name: "LRAGENT delete masks",
      })
    ).copies[0].copy_photo_id,
  );
  const survivor = String((await data("create_gradient_mask", { photo_ids: [copy], ...linear(0.0) })).mask_id);
  const byMask = String((await data("create_gradient_mask", { photo_ids: [copy], ...linear(0.25) })).mask_id);
  const twoTools = String((await data("create_gradient_mask", { photo_ids: [copy], ...linear(0.5) })).mask_id);
  await data("create_gradient_mask", { photo_ids: [copy], mask_id: twoTools, mode: "add", ...radial });
  const oneTool = String((await data("create_gradient_mask", { photo_ids: [copy], ...linear(0.7) })).mask_id);

  const start = await entries(copy);
  const deletedMask = await data("delete_masks", { photo_ids: [copy], mask_ids: [byMask] });
  const afterMask = await entries(copy);
  report.check(
    "by mask id: the named mask is gone and every other mask is byte-identical",
    !afterMask.some((entry) => String(entry.CorrectionID) === byMask) &&
      unchangedExcept(start, afterMask, [byMask]).length === 0,
    {
      reply: deletedMask,
      survivor,
      before: start.map((entry) => entry.CorrectionID),
      after: afterMask.map((entry) => entry.CorrectionID),
    },
  );

  const twoToolEntry = afterMask.find((entry) => String(entry.CorrectionID) === twoTools);
  const [firstTool, secondTool] = componentIds(twoToolEntry);
  const deletedTool = await data("delete_masks", { photo_ids: [copy], tool_ids: [secondTool] });
  const afterTool = await entries(copy);
  const trimmed = afterTool.find((entry) => String(entry.CorrectionID) === twoTools);
  report.check(
    "by tool id: the mask keeps its other component, and every other mask is byte-identical",
    isDeepStrictEqual(componentIds(trimmed), [firstTool]) &&
      unchangedExcept(afterMask, afterTool, [twoTools]).length === 0,
    { reply: deletedTool, components_before: componentIds(twoToolEntry), components_after: componentIds(trimmed) },
  );

  const lastTool = componentIds(afterTool.find((entry) => String(entry.CorrectionID) === oneTool))[0];
  const deletedLast = await data("delete_masks", { photo_ids: [copy], tool_ids: [lastTool] });
  const afterLast = await entries(copy);
  report.check(
    "by the last tool id of a mask: the mask is removed, and every other mask is byte-identical",
    !afterLast.some((entry) => String(entry.CorrectionID) === oneTool) &&
      unchangedExcept(afterTool, afterLast, [oneTool]).length === 0,
    { reply: deletedLast, after: afterLast.map((entry) => entry.CorrectionID) },
  );
  report.finish({ photo_id: copy });
} finally {
  if (copy) await session.tool("remove_photos_from_catalog", { photo_ids: [copy], confirm: true });
  await session.stop();
}
