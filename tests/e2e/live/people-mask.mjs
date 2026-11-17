#!/usr/bin/env node
import { fixtureIdOrNull, openLiveSession } from "./lib/live-catalog.mjs";
import { measureChange, regionDeltas } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const PARTS = ["face_skin", "hair", "facial_hair", "clothes", "entire_person"];
const AI_TIMEOUT_MS = 300_000;
const MIN_CHANGE = 0.05;
const MAX_UNTOUCHED_CHANGE = 0.01;
const BACKGROUND = { name: "background", x0: 0.9, y0: 0.02, x1: 0.99, y1: 0.12 };
const FOREHEAD = { name: "forehead", x0: 0.38, y0: 0.24, x1: 0.58, y1: 0.3 };
const JACKET = { name: "jacket", x0: 0.7, y0: 0.78, x1: 0.9, y1: 0.92 };

const report = createReport("People masks on a portrait: every part found, computed, and placed on the person (people-mask)");
const { session, marker } = await openLiveSession();
const portrait = fixtureIdOrNull(marker, "people_photo");
if (portrait === null) {
  console.log("skipped: the throwaway catalog has no people_photo (run setup-catalog.mjs --add-missing)");
  await session.stop();
  process.exit(0);
}
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: AI_TIMEOUT_MS })).data;
const imageComponents = (entry) => (entry?.CorrectionMasks ?? []).filter((component) => component?.What === "Mask/Image")
  .map((component) => ({ digest: component.MaskDigest ?? null, error_reason: component.ErrorReason ?? null }));

const copy = String((await data("create_virtual_copies", { photo_ids: [String(portrait)], copy_name: "LRAGENT live people parts" })).copies[0].copy_photo_id);
try {
  const started = Date.now();
  const created = await session.tool("create_mask", { photo_id: copy, type: "people", parts: PARTS }, { timeoutMs: AI_TIMEOUT_MS });
  const masks = created.data?.masks ?? [];
  const ids = masks.map((mask) => String(mask.mask_id));
  report.check(`create_mask people with ${PARTS.join(", ")} is done with one mask per part`,
    created.outcome === "done" && masks.length === PARTS.length && new Set(ids).size === PARTS.length,
    { reply: created.envelope, ms: Date.now() - started });

  const stored = (await data("get_develop_settings", { photo_ids: [copy], keys: ["MaskGroupBasedCorrections"] })).photos[0].settings.MaskGroupBasedCorrections ?? [];
  const states = masks.map((mask) => ({ ...mask, components: imageComponents(stored.find((entry) => String(entry.CorrectionID) === String(mask.mask_id))) }));
  report.check("every part's stored mask is computed: each image component has a digest and no ErrorReason",
    states.length === PARTS.length && states.every((state) => state.components.length > 0
      && state.components.every((component) => typeof component.digest === "string" && component.digest !== "" && component.error_reason === null)),
    { states });
  const listed = (await data("list_masks", { photo_id: copy })).masks ?? [];
  report.check("list_masks lists every new mask", ids.every((id) => listed.some((mask) => String(mask.id) === id)), { listed: listed.map((mask) => String(mask.id)) });

  const maskOf = (part) => ids[PARTS.indexOf(part)] ?? "missing";
  const face = await measureChange(session, copy, () => data("set_mask_adjustments", { photo_id: copy, mask_id: maskOf("face_skin"), adjustments: { local_Exposure: 1 } }));
  const faceDeltas = regionDeltas(face.before, face.after, [FOREHEAD, BACKGROUND]);
  report.check("Exposure +1 on the face_skin mask brightens the forehead and leaves the background unchanged",
    faceDeltas.forehead >= MIN_CHANGE && Math.abs(faceDeltas.background) < MAX_UNTOUCHED_CHANGE, faceDeltas);
  const person = await measureChange(session, copy, () => data("set_mask_adjustments", { photo_id: copy, mask_id: maskOf("entire_person"), adjustments: { local_Exposure: -1 } }));
  const personDeltas = regionDeltas(person.before, person.after, [JACKET, BACKGROUND]);
  report.check("Exposure -1 on the entire_person mask darkens the jacket and leaves the background unchanged",
    personDeltas.jacket <= -MIN_CHANGE && Math.abs(personDeltas.background) < MAX_UNTOUCHED_CHANGE, personDeltas);
  report.finish({ portrait: String(portrait), copy });
} finally {
  await session.tool("remove_photos_from_catalog", { photo_ids: [copy], confirm: true });
  await session.stop();
}
