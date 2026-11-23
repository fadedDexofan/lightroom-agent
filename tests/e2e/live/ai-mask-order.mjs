#!/usr/bin/env node
import { isDeepStrictEqual } from "node:util";
import { developHistory, pollCatalog } from "./lib/catalog-db.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { fetchStablePixels, luminanceGap } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const SIZE = 1024;
const RAW_PREVIEW_TRIES = 40;
const MASK_ADJUSTMENT = { local_Exposure: -1 };
const TONE_AND_GEOMETRY = {
  Exposure2012: 1.5,
  Contrast2012: 60,
  Highlights2012: -80,
  Shadows2012: 60,
  PerspectiveVertical: -20,
  PerspectiveRotate: 3,
};
const CROP = { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 };
const GLOBAL_KEYS = [...Object.keys(TONE_AND_GEOMETRY), "CropLeft", "CropTop", "CropRight", "CropBottom", "CropAngle"];
const VOLATILE = new Set(["CorrectionID", "MaskID", "MaskSyncID", "MaskDigest", "InputDigest", "LocalInputDigest"]);

const report = createReport(
  "AI mask order in a full copy against a mask made after the settings, and a full copy from a maskless source (proof t, C31 block 3b, N4)",
);
const { session, marker, catalogPath } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 300_000 })).data;
const base = String(requireFixtureId(marker, "arw_12bit"));
const copies = [];

async function freshCopy(name) {
  const copy = String(
    (await data("create_virtual_copies", { photo_ids: [base], copy_name: name })).copies[0].copy_photo_id,
  );
  copies.push(copy);
  return copy;
}

async function settleAndMask(photoId) {
  await data("set_develop_settings", { photo_ids: [photoId], settings: TONE_AND_GEOMETRY });
  await data("set_crop", { photo_ids: [photoId], rectangle: CROP });
  return String(
    (await data("create_mask", { photo_ids: [photoId], type: "sky", adjustments: MASK_ADJUSTMENT })).mask_id,
  );
}

const stored = async (photoId) =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections", ...GLOBAL_KEYS] }))
    .photos[0].settings;

function differences(a, b, at = "") {
  if (typeof a !== "object" || a === null || typeof b !== "object" || b === null) {
    if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) <= 1e-6 ? [] : [{ at, a, b }];
    return a === b ? [] : [{ at, a, b }];
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  return [...keys]
    .filter((key) => !VOLATILE.has(key))
    .flatMap((key) => differences(a[key], b[key], at ? `${at}.${key}` : key));
}

async function maskEffect(photoId, maskId) {
  const on = await fetchStablePixels(session, photoId, { size: SIZE, tries: RAW_PREVIEW_TRIES });
  await data("set_mask_adjustments", { photo_ids: [photoId], mask_id: maskId, adjustments: { local_Exposure: 0 } });
  const off = await fetchStablePixels(session, photoId, { size: SIZE, tries: RAW_PREVIEW_TRIES });
  await data("set_mask_adjustments", { photo_ids: [photoId], mask_id: maskId, adjustments: MASK_ADJUSTMENT });
  return { on, effect: { w: on.w, h: on.h, L: on.L.map((value, i) => off.L[i] - value) } };
}

const onlyMask = (settings) => (settings.MaskGroupBasedCorrections ?? []).at(-1) ?? null;

const maskCount = async (photoId) => (await data("list_masks", { photo_ids: [photoId] })).count;

async function masklessCopy(name) {
  const copy = await freshCopy(name);
  if ((await maskCount(copy)) > 0) await data("delete_masks", { photo_ids: [copy], all: true });
  return copy;
}

async function storedMaskKey(photoId) {
  const settings = await stored(photoId);
  if (!Object.hasOwn(settings, "MaskGroupBasedCorrections")) return { shape: "absent" };
  const value = settings.MaskGroupBasedCorrections;
  if (value === null) return { shape: "null" };
  return { shape: Array.isArray(value) && value.length === 0 ? "[]" : typeof value, value };
}

async function dryRunFromMaskless(source, masked, plain) {
  const historyBefore = [masked, plain].map((id) => developHistory(catalogPath, id).length);
  const reply = await data("copy_develop_settings", {
    source_photo_id: source,
    photo_ids: [masked, plain],
    dry_run: true,
  });
  const lengths = () => [masked, plain].map((id) => developHistory(catalogPath, id).length);
  const historyAfter = await pollCatalog(lengths, (after) =>
    after.some((length, index) => length !== historyBefore[index]),
  );
  const changesOf = (id) => [(reply.details ?? []).find((detail) => detail.id === id)?.changes ?? []].flat();
  const maskChange = (id) => changesOf(id).find((change) => change.key === "MaskGroupBasedCorrections") ?? null;
  return {
    reply,
    masked: maskChange(masked),
    plain: maskChange(plain),
    history_added: historyAfter.map((length, index) => length - historyBefore[index]),
    masks_after: await maskCount(masked),
  };
}

async function copyFromMaskless(source, target) {
  const historyBefore = developHistory(catalogPath, target);
  const reply = await session.tool(
    "copy_develop_settings",
    { source_photo_id: source, photo_ids: [target] },
    { timeoutMs: 300_000 },
  );
  const historyAfter = await pollCatalog(
    () => developHistory(catalogPath, target),
    () => false,
  );
  return {
    outcome: reply.outcome,
    error: reply.envelope.error ?? null,
    data: reply.data,
    list_masks: await data("list_masks", { photo_ids: [target] }),
    stored: await storedMaskKey(target),
    history_added: historyAfter.slice(historyBefore.length),
  };
}

try {
  const source = await freshCopy("LRAGENT live AI order source");
  await settleAndMask(source);
  const copied = await freshCopy("LRAGENT live AI order copied");
  const copy = await data("copy_develop_settings", { source_photo_id: source, photo_ids: [copied] });
  const direct = await freshCopy("LRAGENT live AI order direct");
  const directMask = await settleAndMask(direct);
  const noise = await freshCopy("LRAGENT live AI order direct again");
  const noiseMask = await settleAndMask(noise);

  const settings = { copied: await stored(copied), direct: await stored(direct), noise: await stored(noise) };
  const copiedMask = String(onlyMask(settings.copied)?.CorrectionID ?? "");
  report.check(
    "the full copy wrote and computed the target",
    copy.copied === 1 && (copy.computed ?? []).map(String).includes(copied),
    { reply: copy },
  );
  const globals = (photo) => Object.fromEntries(GLOBAL_KEYS.map((key) => [key, settings[photo][key]]));
  report.check(
    "copied and direct targets carry the same global settings",
    differences(globals("copied"), globals("direct")).length === 0,
    { copied: globals("copied"), direct: globals("direct") },
  );

  const entry = {
    copied_vs_direct: differences(onlyMask(settings.copied), onlyMask(settings.direct)),
    direct_vs_direct_again: differences(onlyMask(settings.direct), onlyMask(settings.noise)),
  };
  let rendered;
  let beyondNoise = null;
  try {
    const effects = {
      copied: await maskEffect(copied, copiedMask),
      direct: await maskEffect(direct, directMask),
      noise: await maskEffect(noise, noiseMask),
    };
    rendered = {
      effect_copied_vs_direct: luminanceGap(effects.copied.effect, effects.direct.effect),
      effect_direct_vs_direct_again: luminanceGap(effects.direct.effect, effects.noise.effect),
      render_copied_vs_direct: luminanceGap(effects.copied.on, effects.direct.on),
      render_direct_vs_direct_again: luminanceGap(effects.direct.on, effects.noise.on),
    };
    beyondNoise =
      rendered.effect_copied_vs_direct.mean_abs > 2 * rendered.effect_direct_vs_direct_again.mean_abs + 0.002;
    console.log(
      `order matters: ${beyondNoise} (effect mean |d| ${rendered.effect_copied_vs_direct.mean_abs?.toFixed(4)} against noise ${rendered.effect_direct_vs_direct_again.mean_abs?.toFixed(4)})`,
    );
  } catch (error) {
    rendered = { error: error.message };
  }
  report.check(
    "the stored mask and its rendered effect are recorded for copied, direct and direct-again targets",
    true,
    { entry, rendered, order_matters: beyondNoise },
  );

  const bare = await masklessCopy("LRAGENT live maskless source");
  await data("set_develop_settings", { photo_ids: [bare], settings: { Exposure2012: 0.5 } });
  const masked = await masklessCopy("LRAGENT live maskless target with masks");
  await data("create_mask", { photo_ids: [masked], type: "sky" });
  await data("create_gradient_mask", {
    photo_ids: [masked],
    shape: "linear",
    start: { x: 0.5, y: 0.9 },
    end: { x: 0.5, y: 0.7 },
  });
  const maskedBefore = await maskCount(masked);
  const plain = await masklessCopy("LRAGENT live maskless target without masks");
  const preview = await dryRunFromMaskless(bare, masked, plain);
  report.check(
    "the dry run of that full copy previews the removal of the masked target's two masks, none for the maskless target, and writes nothing",
    preview.reply.dry_run === true &&
      preview.reply.setting_totals?.MaskGroupBasedCorrections === 1 &&
      preview.masked?.before?.type === "table" &&
      preview.masked.before.entries === 2 &&
      preview.masked.after?.type === "table" &&
      preview.masked.after.entries === 0 &&
      preview.plain === null &&
      preview.history_added.every((count) => count === 0) &&
      preview.masks_after === 2,
    preview,
  );
  const cleared = await copyFromMaskless(bare, masked);
  report.check(
    "a full copy from a maskless source removes the target's masks and says how many",
    maskedBefore === 2 &&
      cleared.outcome === "done" &&
      cleared.data?.copied === 1 &&
      isDeepStrictEqual(cleared.data?.masks_removed, [{ photo_id: masked, count: 2 }]) &&
      cleared.list_masks.count === 0,
    { masks_before: maskedBefore, ...cleared },
  );
  report.check("the stored shape after the emptying write and its history steps are recorded", true, {
    stored: cleared.stored,
    history_added: cleared.history_added,
  });

  const untouched = await copyFromMaskless(bare, plain);
  report.check(
    "a full copy from a maskless source onto a maskless target removes nothing and names no removal",
    untouched.outcome === "done" &&
      untouched.data?.copied === 1 &&
      untouched.data?.masks_removed === undefined &&
      untouched.list_masks.count === 0,
    untouched,
  );

  report.finish({
    source,
    copied,
    direct,
    noise,
    order_matters: beyondNoise,
    maskless: { source: bare, masked, plain },
  });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
