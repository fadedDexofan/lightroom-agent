#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { CHART80_LAYOUT, chart80Patches, patchCenterFraction } from "./lib/patterns.mjs";
import { measureChange, patchDeltas } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const WHOLE_FRAME = { shape: "radial", center: { x: 0.5, y: 0.5 }, width: 2, height: 2, rotation: 0, feather: 0 };
const SOURCE = { SrcHue: 3.021347, SrcSat: 0.537218, SrcLum: 0.512694, LumScale: -0.8 };
const NEARBY = { ...SOURCE, SrcHue: 3.071347 };
const EQUAL_EDGES = { HueRange: { LowerNone: 0.4, LowerFull: 0.4, UpperFull: 0.6, UpperNone: 0.6 } };
const SOURCE_HUE_DEGREES = (SOURCE.SrcHue / 6) * 360;
const NEAR_HUE_DEGREES = 60;
const MOVED = 0.02;

const report = createReport(
  "Point Color add in the saved settings: kept at a six-decimal source, rendered on its hue, a nearby source, unordered edges refused, equal edges kept or refused with nothing lost",
);
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 120_000 })).data;
const stored = async (photoId, maskId) =>
  (
    (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections"] })).photos[0]
      .settings.MaskGroupBasedCorrections ?? []
  ).find((entry) => String(entry.CorrectionID) === String(maskId)) ?? null;
const hueOf = ([r, g, b]) => {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  if (max === min) return null;
  const d = max - min;
  const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return (h * 60 + 360) % 360;
};
const hueGap = (a, b) => Math.min(Math.abs(a - b), 360 - Math.abs(a - b));
const PATCHES = chart80Patches().map((rgb, index) => ({
  index,
  hue: hueOf(rgb),
  ...patchCenterFraction(CHART80_LAYOUT, index),
}));

let copy = null;
try {
  copy = String(
    (
      await data("create_virtual_copies", {
        photo_ids: [String(requireFixtureId(marker, "chart80"))],
        copy_name: "LRAGENT point color add",
      })
    ).copies[0].copy_photo_id,
  );
  const mask = String((await data("create_gradient_mask", { photo_ids: [copy], ...WHOLE_FRAME })).mask_id);

  let added;
  const shown = await measureChange(session, copy, async () => {
    added = await session.tool("edit_mask_point_colors", {
      photo_ids: [copy],
      mask_id: mask,
      action: "add",
      swatch: SOURCE,
    });
  });
  const patches = patchDeltas(shown.before, shown.after, PATCHES).map((delta, index) => ({
    ...PATCHES[index],
    deltaL: delta.deltaL,
  }));
  const moved = patches.filter((patch) => Math.abs(patch.deltaL) > MOVED);
  const afterAdd = await stored(copy, mask);
  report.check(
    "the add is done, stores one swatch and moves only patches near its hue",
    added.outcome === "done" &&
      (afterAdd?.LocalPointColors ?? []).length === 1 &&
      moved.length > 0 &&
      moved.every((patch) => patch.hue !== null && hueGap(patch.hue, SOURCE_HUE_DEGREES) <= NEAR_HUE_DEGREES),
    {
      reply: added.envelope,
      stored: afterAdd?.LocalPointColors ?? null,
      variance: afterAdd?.LocalColorVariance ?? null,
      moved_above: MOVED,
      near_hue_degrees: NEAR_HUE_DEGREES,
      source_hue_degrees: SOURCE_HUE_DEGREES,
      patches,
    },
  );

  const nearby = await session.tool("edit_mask_point_colors", {
    photo_ids: [copy],
    mask_id: mask,
    action: "add",
    swatch: NEARBY,
  });
  const afterNearby = await stored(copy, mask);
  const nearbyKeptSwatches =
    JSON.stringify(afterNearby?.LocalPointColors) === JSON.stringify(afterAdd?.LocalPointColors);
  report.check(
    `a nearby source answered ${nearby.outcome}${nearby.envelope.error ? ` (${nearby.envelope.error})` : ""}; stored swatches ${(afterNearby?.LocalPointColors ?? []).length}`,
    nearby.outcome === "done" || (nearby.outcome === "failed" && nearbyKeptSwatches),
    {
      reply: nearby.envelope,
      stored: afterNearby?.LocalPointColors ?? null,
      swatches_as_after_the_add: nearbyKeptSwatches,
    },
  );

  const before = await stored(copy, mask);
  const unordered = await session.tool("edit_mask_point_colors", {
    photo_ids: [copy],
    mask_id: mask,
    action: "update",
    index: 1,
    swatch: { HueRange: { LowerNone: 0.6, LowerFull: 0.2, UpperFull: 0.9, UpperNone: 0.4 } },
  });
  const afterUnordered = await stored(copy, mask);
  report.check(
    "the running server refuses an update with unordered range edges before dispatch and the swatches stay as they were",
    unordered.outcome === "failed" &&
      JSON.stringify(afterUnordered?.LocalPointColors) === JSON.stringify(before?.LocalPointColors),
    { reply: unordered.envelope },
  );

  const equal = await session.tool("edit_mask_point_colors", {
    photo_ids: [copy],
    mask_id: mask,
    action: "update",
    index: 1,
    swatch: EQUAL_EDGES,
  });
  const afterEqual = await stored(copy, mask);
  const kept = (afterEqual?.LocalPointColors ?? []).length === (afterUnordered?.LocalPointColors ?? []).length;
  const unchanged = JSON.stringify(afterEqual?.LocalPointColors) === JSON.stringify(afterUnordered?.LocalPointColors);
  report.check(
    `an update with equal range edges reaches Lightroom and answered ${equal.outcome}: ${equal.outcome === "done" ? "Lightroom must keep every swatch" : "nothing may be lost"}`,
    (equal.outcome === "done" && kept && !unchanged) || (equal.outcome !== "done" && unchanged),
    {
      reply: equal.envelope,
      sent: EQUAL_EDGES,
      stored_before: afterUnordered?.LocalPointColors ?? null,
      stored_after: afterEqual?.LocalPointColors ?? null,
    },
  );
  report.finish({ photo_id: copy });
} finally {
  if (copy) await session.tool("remove_photos_from_catalog", { photo_ids: [copy], confirm: true });
  await session.stop();
}
