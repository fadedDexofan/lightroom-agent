#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { changedShare, fetchStablePixels, luminanceGap, measureChange } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const AI_TIMEOUT_MS = 300_000;
const SKY = { local_Exposure: -1 };
const MAX_MEAN_GAP = 0.01;
const SIZE_FIELDS = ["FullMaskSize", "WholeImageArea", "Origin"];
const TARGETS = ["flat_gray", "orient_6"];

const report = createReport(
  "a full copy carries a Sky onto photos of another size and orientation, computed and rendered as a Sky made on each target (row 4b)",
);
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: AI_TIMEOUT_MS })).data;
const copies = [];

async function freshCopy(fixture, role) {
  const copy = String(
    (
      await data("create_virtual_copies", {
        photo_ids: [String(requireFixtureId(marker, fixture))],
        copy_name: `LRAGENT copy turned ${role}`,
      })
    ).copies[0].copy_photo_id,
  );
  copies.push(copy);
  return copy;
}

const entries = async (photoId) =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections"] })).photos[0].settings
    .MaskGroupBasedCorrections ?? [];
const imageOf = (entry) => (entry?.CorrectionMasks ?? []).find((component) => component.What === "Mask/Image") ?? null;
const computedOf = (component) => ({
  computed: typeof component?.MaskDigest === "string",
  error_reason: component?.ErrorReason ?? null,
  ...Object.fromEntries(SIZE_FIELDS.map((field) => [field, component?.[field] ?? null])),
});

try {
  const source = await freshCopy("arw_12bit", "source");
  const targets = {};
  for (const fixture of TARGETS)
    targets[fixture] = {
      copy: await freshCopy(fixture, `${fixture} target`),
      native: await freshCopy(fixture, `${fixture} native`),
    };
  await data("reset_develop_adjustments", { photo_ids: copies, confirm: true });
  for (const photoId of copies) {
    if ((await entries(photoId)).length > 0) await data("delete_masks", { photo_id: photoId, all: true });
  }

  const sourceSky = String((await data("create_mask", { photo_id: source, type: "sky", adjustments: SKY })).mask_id);
  const sourceComponent = imageOf((await entries(source)).find((entry) => String(entry.CorrectionID) === sourceSky));

  const before = {};
  for (const fixture of TARGETS) before[fixture] = await entries(targets[fixture].copy);
  const copied = await session.tool(
    "copy_develop_settings",
    { source_id: source, target_ids: TARGETS.flatMap((fixture) => [targets[fixture].copy, targets[fixture].native]) },
    { timeoutMs: AI_TIMEOUT_MS },
  );
  const computedIds = (copied.data?.computed ?? []).map(String);
  const stoppedFor = (photoId) =>
    [...(copied.envelope.failed ?? []), ...(copied.envelope.unknown ?? [])].find(
      (entry) => String(entry.photo_id) === photoId,
    ) ?? null;

  for (const fixture of TARGETS) {
    const { copy: target, native } = targets[fixture];
    if ((await entries(native)).length > 0) await data("delete_masks", { photo_id: native, all: true });
    const made = await session.tool(
      "create_mask",
      { photo_id: native, type: "sky", adjustments: SKY },
      { timeoutMs: AI_TIMEOUT_MS },
    );
    const nothingFound = made.outcome === "failed" && /Lightroom found nothing/.test(made.envelope.error ?? "");
    const nativeComponent = made.outcome === "done" ? imageOf((await entries(native)).at(-1)) : null;
    const after = await entries(target);
    const sky = after.find((entry) => imageOf(entry)?.MaskSubType === sourceComponent?.MaskSubType) ?? null;
    const twin = { create_mask: made.outcome, error: made.envelope.error ?? null, component: nativeComponent };

    if (nothingFound) {
      const refusal = stoppedFor(target);
      const voided = (copied.envelope.unknown ?? []).includes(refusal);
      report.check(
        `${fixture}: Lightroom finds no sky on the twin, so the copy stops this photo as nothing found (${voided ? "unknown" : "failed"}) and leaves its masks as before`,
        refusal !== null &&
          /Lightroom found nothing/.test(refusal.reason) &&
          /the new masks were removed/.test(refusal.reason) &&
          (!voided || /Update AI Settings/.test(refusal.reason)) &&
          !computedIds.includes(target) &&
          JSON.stringify(after) === JSON.stringify(before[fixture]),
        { reply: copied.envelope, twin, masks_before: before[fixture].length, masks_after: after.length },
      );
    } else {
      report.check(
        `${fixture}: the full copy computed this photo`,
        computedIds.includes(target) && stoppedFor(target) === null,
        { reply: copied.envelope, twin },
      );
      const copiedState = computedOf(imageOf(sky));
      const sourceSizes = computedOf(sourceComponent);
      report.check(
        `${fixture}: the copied Sky is computed as a Sky made on ${fixture} itself, with ${fixture}'s size fields`,
        sky !== null &&
          JSON.stringify(copiedState) === JSON.stringify(computedOf(nativeComponent)) &&
          (!copiedState.computed || SIZE_FIELDS.some((field) => copiedState[field] !== sourceSizes[field])),
        { copied: imageOf(sky), twin, source: sourceSizes },
      );
    }

    const targetPixels = await fetchStablePixels(session, target);
    const nativePixels = await fetchStablePixels(session, native);
    const gap = luminanceGap(targetPixels, nativePixels);
    const off = sky
      ? await measureChange(session, target, () =>
          data("set_mask_adjustments", {
            photo_id: target,
            mask_id: String(sky.CorrectionID),
            adjustments: { local_Exposure: 0 },
          }),
        )
      : null;
    report.check(
      `${fixture}: the target with the copied Sky renders as the copy with a Sky made on it`,
      gap.mean_abs !== undefined && gap.mean_abs <= MAX_MEAN_GAP,
      {
        gap,
        max_mean_gap: MAX_MEAN_GAP,
        copied_sky_off_brightens: off
          ? changedShare(off.before, off.after, () => true, { direction: "brighter" }).changed
          : null,
        previews: {
          target: report.preview(`${fixture} target`, targetPixels),
          native: report.preview(`${fixture} native`, nativePixels),
        },
      },
    );
  }
  report.finish({ source, targets });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
