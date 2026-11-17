#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { fetchStablePixels, sampledMaxLuminanceDifference, meanChroma } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const GREY_CHROMA = 0.01;
const SAME_RENDER = 0.02;
const KEYS = ["ConvertToGrayscale", "CameraProfile", "Look", "ToggleStyleDigest", "ToggleStyleAmount"];

const argv = process.argv;
const option = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : null);
const roundTripOnly = option("--round-trip");
const toGreyOnly = option("--to-black-and-white");
const toColourOnly = option("--to-color");
const expectedProfile = option("--expect-profile");
const withPreset = argv.includes("--with-preset");
const single = roundTripOnly ?? toGreyOnly ?? toColourOnly;

const report = createReport(single ? `set_treatment on photo ${single}` : "treatment (edit-breadth 03)");
const { session, marker } = await openLiveSession();
const id = (key) => String(requireFixtureId(marker, key));
const answer = (name, args) => session.toolOrThrow(name, args, { timeoutMs: 180_000 });
const data = async (name, args) => (await answer(name, args)).data;
const copies = [];
const findings = {};

const raw = async (photoId) => (await data("get_develop_settings", { photo_ids: [photoId], keys: KEYS })).photos[0].settings;
const profileOf = (settings) => settings.Look?.Name ?? settings.CameraProfile;
const look = async (photoId) => {
  const pixels = await fetchStablePixels(session, photoId);
  return { pixels, chroma: meanChroma(pixels), settings: await raw(photoId) };
};

const stateOf = (settings) => ({
  profile: profileOf(settings), look: settings.Look ?? null,
  ToggleStyleDigest: settings.ToggleStyleDigest ?? null, ToggleStyleAmount: settings.ToggleStyleAmount ?? null,
});

async function treat(photoId, treatment, before) {
  const result = (await data("set_treatment", { photo_ids: [photoId], treatment })).results[0];
  const after = await look(photoId);
  report.check(`photo ${photoId} ${treatment}: the reply matches the stored flag and the profile before and after`,
    result.convert_to_grayscale === after.settings.ConvertToGrayscale
      && result.profile?.before === profileOf(before.settings) && result.profile?.after === profileOf(after.settings),
    { reply: result, stored: { ConvertToGrayscale: after.settings.ConvertToGrayscale, before: profileOf(before.settings), after: profileOf(after.settings) } });
  return after;
}

function verdict(before, back) {
  return profileOf(back.settings) === before ? `restored to ${before}` : `fell back to ${profileOf(back.settings)}`;
}

async function toGrey(label, photoId) {
  const before = await look(photoId);
  const grey = await treat(photoId, "black_and_white", before);
  report.check(`${label}: black_and_white renders grey`, grey.chroma < GREY_CHROMA, { chroma: grey.chroma, before: before.chroma });
  findings[label] = { before: stateOf(before.settings), black_and_white: stateOf(grey.settings), chroma: { before: before.chroma, black_and_white: grey.chroma } };
  return { before, grey };
}

async function toColour(label, photoId, before, grey) {
  const back = await treat(photoId, "color", grey ?? (await look(photoId)));
  const expected = before ? profileOf(before.settings) : expectedProfile;
  const entry = findings[label] ?? (findings[label] = {});
  Object.assign(entry, {
    after: stateOf(back.settings),
    verdict: expected ? verdict(expected, back) : `returned to ${profileOf(back.settings)}`,
    look_restored: before ? JSON.stringify(back.settings.Look ?? null) === JSON.stringify(before.settings.Look ?? null) : null,
  });
  if (before) {
    const difference = sampledMaxLuminanceDifference(before.pixels, back.pixels);
    Object.assign(entry, {
      renders_as_before: difference < SAME_RENDER && Math.abs(back.chroma - before.chroma) < GREY_CHROMA,
      sampled_max_luminance_difference: difference,
      chroma: { ...entry.chroma, after: back.chroma },
    });
  }
  console.log(`finding ${label}: ${entry.verdict}${entry.renders_as_before === undefined ? "" : `, renders as before: ${entry.renders_as_before}`}`);
  return back;
}

async function roundTrip(label, photoId) {
  const selection = await data("get_selected_photos", {});
  const { before, grey } = await toGrey(label, photoId);
  await toColour(label, photoId, before, grey);
  report.check(`${label}: the selection is restored exactly`, JSON.stringify(await data("get_selected_photos", {})) === JSON.stringify(selection), { selection });
}

async function virtualCopy(photoId, name) {
  const copy = (await data("create_virtual_copies", { photo_ids: [photoId], copy_name: name })).copies[0].copy_photo_id;
  copies.push(copy);
  if ((await data("list_masks", { photo_id: copy })).count > 0) await data("delete_masks", { photo_id: copy, all: true });
  return copy;
}

try {
  if (roundTripOnly) {
    await roundTrip(`photo ${roundTripOnly}`, roundTripOnly);
  } else if (toGreyOnly) {
    await toGrey(`photo ${toGreyOnly}`, toGreyOnly);
  } else if (toColourOnly) {
    await toColour(`photo ${toColourOnly}`, toColourOnly, null, null);
  } else {
    await roundTrip("raw arw_12bit", id("arw_12bit"));
    await roundTrip("png chart80", id("chart80"));

    const refused = await session.tool("set_develop_settings", { photo_id: id("chart80"), settings: { ConvertToGrayscale: true } });
    report.check("set_develop_settings refuses ConvertToGrayscale and points to set_treatment",
      refused.isError && refused.text.includes("set_treatment"), { text: refused.text });

    const source = await virtualCopy(id("arw_12bit"), "LRAGENT live B&W source");
    await data("set_treatment", { photo_ids: [source], treatment: "black_and_white" });
    const copyTarget = await virtualCopy(id("arw_14bit"), "LRAGENT live B&W copy target");
    await data("copy_develop_settings", { source_id: source, target_ids: [copyTarget] });
    const copied = await look(copyTarget);
    findings.copy = { chroma: copied.chroma, grey: copied.chroma < GREY_CHROMA, ConvertToGrayscale: copied.settings.ConvertToGrayscale, profile: profileOf(copied.settings) };
    report.check("copy_develop_settings from a B&W raw: what the colour target reads back is recorded", true, findings.copy);

    if (withPreset) {
      const presetTarget = await virtualCopy(id("arw_14bit"), "LRAGENT live B&W preset target");
      const preset = await session.tool("create_develop_preset", { photo_id: source, preset_name: `LRAGENT live B&W transfer ${Date.now()}`, settings: ["ConvertToGrayscale"] });
      findings.preset_create = { isError: preset.isError, text: preset.isError ? preset.text : undefined, data: preset.data };
      if (!preset.isError) {
        await data("apply_develop_preset", { photo_ids: [presetTarget], preset_uuid: preset.data.uuid });
        const applied = await look(presetTarget);
        findings.preset = { chroma: applied.chroma, grey: applied.chroma < GREY_CHROMA, ConvertToGrayscale: applied.settings.ConvertToGrayscale, profile: profileOf(applied.settings) };
      }
      report.check("a develop preset from a B&W raw: the outcome is recorded", true, { create: findings.preset_create, applied: findings.preset ?? null });
    }
  }
  report.finish({ findings });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
