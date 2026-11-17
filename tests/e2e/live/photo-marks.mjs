#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const report = createReport("rating, flag and label in the filters' vocabulary, and accessibility text read back (api-shape 11, N32)");
const { session, marker } = await openLiveSession();
const photoId = String(requireFixtureId(marker, "ramp256"));
const data = async (name, args) => (await session.toolOrThrow(name, args)).data;
const original = await session.photoMetadata(photoId);
const ACCESSIBILITY = { alt_text: "LRMCP live alt text: a grey ramp", extended_description: "LRMCP live description: 256 grey steps from black to white" };

try {
  for (const [rating, flag, label] of [[3, "pick", "green"], [1, "reject", "yellow"], [0, "none", "none"]]) {
    await data("set_rating_and_flag", { photo_ids: [photoId], rating, flag });
    await data("set_color_label", { photo_ids: [photoId], label });
    const read = await session.photoMetadata(photoId);
    const found = (await data("search_photos", { rating, flag, color_label: label, filename: "ramp256", limit: 5 })).photos;
    report.check(`rating ${rating}, ${flag}, ${label}: read back and found by the same words`,
      read.rating === rating && read.flag === flag && read.color_label === label && found.some((row) => String(row.photo_id) === photoId),
      { read: { rating: read.rating, flag: read.flag, color_label: read.color_label }, found: found.map((row) => row.photo_id) });
  }
  const write = await session.tool("set_metadata", { photo_ids: [photoId], ...ACCESSIBILITY });
  const read = await session.tool("get_photo_metadata", { photo_ids: [photoId] });
  report.check("get_photo_metadata returns the accessibility text set_metadata wrote, in its one batch read",
    write.outcome === "done" && read.outcome === "done"
      && read.data?.photos?.[0]?.accessibility?.alt_text === ACCESSIBILITY.alt_text
      && read.data?.photos?.[0]?.accessibility?.extended_description === ACCESSIBILITY.extended_description,
    { write: write.envelope, read: read.envelope.error ?? read.data?.photos?.[0]?.accessibility ?? null });
  report.finish();
} finally {
  await session.tool("set_metadata", {
    photo_ids: [photoId],
    alt_text: original.accessibility?.alt_text ?? "",
    extended_description: original.accessibility?.extended_description ?? "",
  });
  await session.tool("set_rating_and_flag", { photo_ids: [photoId], rating: original.rating, flag: original.flag });
  await session.tool("set_color_label", { photo_ids: [photoId], label: original.color_label });
  await session.stop();
}
