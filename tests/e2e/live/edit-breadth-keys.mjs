#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { maxLuminanceDifference, measureChange, meanChroma } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const VISIBLE = 0.01;

const WRITES = [
  { label: "Defringe purple", settings: { DefringePurpleAmount: 20, DefringePurpleHueLo: 30, DefringePurpleHueHi: 70 }, visible: false },
  { label: "Remove CA", settings: { AutoLateralCA: 1 }, visible: false },
  { label: "global Color Grading", settings: { ColorGradeGlobalHue: 200, ColorGradeGlobalSat: 40 }, visible: true },
  { label: "midtone Color Grading, blending and balance", settings: { ColorGradeMidtoneHue: 30, ColorGradeMidtoneSat: 30, ColorGradeBlending: 70, SplitToningBalance: 20 }, visible: true },
  { label: "Glow with a directional style", settings: { Glow: 60, GlowStyle: 3, GlowDirection: 90, GlowRange: 50, GlowSpread: 50, GlowWarmth: 20 }, visible: true },
  { label: "Upright level", settings: { PerspectiveUpright: 3 }, visible: false },
  { label: "Projection", settings: { ReshapeAmount: 50 }, visible: false },
];

const REFUSALS = [
  { label: "Glow out of range", settings: { Glow: 200 } },
  { label: "a Defringe hue pair closer than 10", settings: { DefringePurpleHueLo: 30, DefringePurpleHueHi: 35 } },
  { label: "GlowStyle with Glow 0", settings: { Glow: 0, GlowStyle: 2 } },
  { label: "a GrayMixer key on a colour photo", settings: { GrayMixerRed: 40 } },
];

const report = createReport("edit-breadth keys through set_develop_settings (edit-breadth 01, 02, 04, 06; api-shape 18)");
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 180_000 })).data;
const copyId = (await data("create_virtual_copies", { photo_ids: [requireFixtureId(marker, "arw_12bit")], copy_name: "LRMCP live edit-breadth keys" })).copies[0].copy_photo_id;
const stored = async (keys) => (await data("get_develop_settings", { photo_ids: [copyId], keys })).photos[0].settings;

try {
  for (const refusal of REFUSALS) {
    const keys = Object.keys(refusal.settings);
    const before = await stored(keys);
    const answer = await session.tool("set_develop_settings", { photo_id: copyId, settings: refusal.settings });
    const after = await stored(keys);
    report.check(`refused before the write: ${refusal.label}`, answer.isError && JSON.stringify(after) === JSON.stringify(before), { text: answer.text, before, after });
  }

  for (const write of WRITES) {
    let reply;
    const pixels = await measureChange(session, copyId, async () => {
      reply = await data("set_develop_settings", { photo_id: copyId, settings: write.settings });
    });
    const keys = Object.keys(write.settings);
    const readBack = await stored(keys);
    const change = Math.max(maxLuminanceDifference(pixels.before, pixels.after), Math.abs(meanChroma(pixels.after) - meanChroma(pixels.before)));
    const kept = keys.every((key) => readBack[key] === write.settings[key]);
    report.check(`${write.label}: written, read back${write.visible ? " and visible" : ""}`, kept && !reply.adjusted && (!write.visible || change > VISIBLE),
      { requested: write.settings, read_back: readBack, adjusted: reply.adjusted ?? null, change });
  }

  await data("set_treatment", { photo_ids: [copyId], treatment: "black_and_white" });
  let mixer;
  const pixels = await measureChange(session, copyId, async () => {
    mixer = await data("set_develop_settings", { photo_id: copyId, settings: { GrayMixerRed: 60, GrayMixerBlue: -60 } });
  });
  report.check("GrayMixer on a black and white raw: written and visible",
    !mixer.adjusted && maxLuminanceDifference(pixels.before, pixels.after) > VISIBLE, { adjusted: mixer.adjusted ?? null, change: maxLuminanceDifference(pixels.before, pixels.after) });
  report.finish({ photo: copyId });
} finally {
  await session.tool("remove_photos_from_catalog", { photo_ids: [copyId], confirm: true });
  await session.stop();
}
