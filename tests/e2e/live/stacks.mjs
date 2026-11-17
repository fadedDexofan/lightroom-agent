#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { STACK_CARDS } from "./lib/patterns.mjs";
import { colorCentroid, decodeJpegBase64 } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const PROMPT_REFUSAL_MS = 3000;
const ASPECT_TOLERANCE = 0.01;

const report = createReport("collapsed stack: removal refusal, search warning and hidden members by id (lr16-compat 15)");
const { session, marker } = await openLiveSession();
const cards = STACK_CARDS.map((card) => ({ ...card, id: String(requireFixtureId(marker, card.key)) }));
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 180_000 })).data;

try {
  const rows = (await data("get_photo_metadata", { photo_ids: cards.map((card) => card.id) })).photos;
  const top = rows.find((row) => row.stack?.is_collapsed && row.stack.position === 1);
  if (!top) throw new Error(`stack_1..3 are not a collapsed stack: ${JSON.stringify(rows.map((row) => ({ id: row.photo_id, stack: row.stack })))}`);
  const topId = String(top.photo_id);
  const members = (top.stack.member_photo_ids ?? []).map(String);
  report.check("the top lists every member of the stack", cards.every((card) => members.includes(card.id)), { top: topId, members });

  const hidden = cards.filter((card) => card.id !== topId);
  const removal = await session.tool("remove_photos_from_catalog", { photo_ids: [hidden[0].id], confirm: true });
  report.check("removing a hidden member is refused at once", removal.isError && removal.text.includes("collapsed stack") && removal.ms < PROMPT_REFUSAL_MS,
    { text: removal.text, ms: removal.ms });
  const still = (await data("get_photo_metadata", { photo_ids: [hidden[0].id] })).photos;
  report.check("the refused member is still in the catalog", still.length === 1, {});

  const search = await session.toolOrThrow("search_photos", { filename: "stack_", limit: 10 });
  const warnings = search.envelope.warnings ?? [];
  report.check("search shows the top and warns that hidden members are not searched",
    search.data.photos.some((row) => String(row.photo_id) === topId) && warnings.some((text) => text.includes(topId)),
    { count: search.data.count, ids: search.data.photos.map((row) => row.photo_id), warnings });

  for (const card of hidden) {
    const preview = await session.toolOrThrow("get_photo_preview", { photo_id: card.id, size: 512 });
    const pixels = decodeJpegBase64(preview.image.data);
    const aspect = pixels.w / pixels.h;
    const colour = colorCentroid(pixels, card.color);
    report.check(`${card.key}: the preview by id is the hidden member's own render`,
      Math.abs(aspect / (card.width / card.height) - 1) <= ASPECT_TOLERANCE && colour !== null && colour.count > pixels.w * pixels.h * 0.9,
      { decoded: `${pixels.w}x${pixels.h}`, expected: `${card.width}x${card.height}`, coloured_pixels: colour?.count ?? 0, colour: card.color,
        preview: report.preview(`${card.key} by id`, { jpeg: preview.image.data }) });
    const detail = await data("get_photo_detail", { photo_id: card.id, regions: [{ x: 0.4, y: 0.4, width: 0.2, height: 0.2 }] });
    report.check(`${card.key}: the detail render by id has the hidden member's size`,
      detail.render.width === card.width && detail.render.height === card.height, { render: detail.render });
  }
  report.finish({ top: topId, members });
} finally {
  await session.stop();
}
