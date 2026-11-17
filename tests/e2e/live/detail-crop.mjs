#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { developHistory, lastExportTimestamp, pollCatalog } from "./lib/catalog-db.mjs";
import { jpegQuantTables } from "./lib/jpeg.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { alternationRate, decodeJpegBase64 } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const MIN_ALTERNATION = 0.98;
const POLL_MS = 25;
const SETTING_KEYS = ["ProcessVersion", "Exposure2012", "CropLeft", "CropTop", "CropRight", "CropBottom", "CropAngle"];
const CROP = { left: 0.1, top: 0.2, right: 0.6, bottom: 0.9 };
const CENTRE = { x: 0.45, y: 0.45, width: 0.1, height: 0.1 };
const WHOLE = { x: 0, y: 0, width: 1, height: 1 };
const HINT_EDGE = 512;
const HINT_OFFSET = { x: 0.3004, y: 0.2006 };
const COCOA_EPOCH_MS = Date.UTC(2001, 0, 1);
const STALE_RENDER_MS = 300_000;
const ANGLE = 8;
const UPRIGHT = { PerspectiveUpright: 4, PerspectiveVertical: -20 };
const EXPORT_LEAVES = ["one Export history step", "the exported mark"];

const detailDirectory = path.join(execFileSync("getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim(), "lightroom-mcp-detail");
const captureDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-detail-capture-"));
const renderFolders = new Set();
const planted = [];

const report = createReport("detail crop (detail-crop 02)");
const { session, marker, catalogPath } = await openLiveSession();
const id = (key) => String(requireFixtureId(marker, key));
const ids = { board: id("checkerboard"), wide: id("wide_plain"), turned: id("orient_6"), raw: id("arw_14bit") };
const copies = [];

const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 300_000 })).data;
const state = async () => ({
  count: (await data("search_photos", { limit: 0 })).count,
  selection: await data("get_selected_photos", {}),
  settings: (await data("get_develop_settings", { photo_ids: Object.values(ids), keys: SETTING_KEYS })).photos,
});

const renderFiles = () => (fs.existsSync(detailDirectory)
  ? fs.readdirSync(detailDirectory, { recursive: true }).map(String).filter((name) => name.toLowerCase().endsWith(".jpg"))
  : []);

function directoryBytes() {
  return renderFiles().reduce((sum, name) => {
    const file = path.join(detailDirectory, name);
    renderFolders.add(path.dirname(name));
    try {
      fs.copyFileSync(file, path.join(captureDirectory, path.basename(name)));
      return sum + fs.statSync(file).size;
    } catch {
      return sum;
    }
  }, 0);
}

async function detail(photoId, regions, maxEdge) {
  let peak = 0;
  const timer = setInterval(() => { peak = Math.max(peak, directoryBytes()); }, POLL_MS);
  try {
    const answer = await session.toolOrThrow("get_photo_detail", { photo_id: photoId, regions, ...(maxEdge ? { max_edge: maxEdge } : {}) }, { timeoutMs: 300_000 });
    return { ...answer.data, images: answer.images, ms: answer.ms, peakTemporaryBytes: peak };
  } finally {
    clearInterval(timer);
  }
}

function plantDetailEntries() {
  const now = Date.now() - COCOA_EPOCH_MS;
  const entries = { abandoned: `${now - 2 * STALE_RENDER_MS}-0`, fresh: `${now}-0`, unrelated: "lrmcp-live-unrelated" };
  for (const name of Object.values(entries)) {
    fs.mkdirSync(path.join(detailDirectory, name), { recursive: true });
    fs.writeFileSync(path.join(detailDirectory, name, "planted.txt"), "planted");
    planted.push(name);
  }
  return entries;
}

const removePlanted = () => planted.splice(0).forEach((name) => fs.rmSync(path.join(detailDirectory, name), { recursive: true, force: true }));

const sameSize = (render, width, height) => Math.abs(render.width - width) <= 1 && Math.abs(render.height - height) <= 1;
const planned = async (photoId) => (await data("get_crop", { photo_id: photoId })).size;
const sizes = (render, frame) => ({ render: `${render.width}x${render.height}`, get_crop: `${frame.width}x${frame.height}`,
  equal: render.width === frame.width && render.height === frame.height });

try {
  const before = await state();

  const traces = () => ({ history: developHistory(catalogPath, ids.board), last_export_timestamp: lastExportTimestamp(catalogPath, ids.board) });
  const tracesBefore = traces();
  const refused = await session.tool("get_photo_detail", { photo_id: ids.board, regions: [WHOLE], max_edge: HINT_EDGE }, { timeoutMs: 300_000 });
  const tracesRefused = await pollCatalog(traces, (now) => !isDeepStrictEqual(now, tracesBefore));
  const hint = /allows regions up to width ([\d.]+) and height ([\d.]+)/.exec(refused.envelope.error ?? "");
  report.check("a region over max_edge is refused before the render and leaves nothing on the photo",
    refused.isError && refused.outcome === "failed" && refused.envelope.error?.includes(`over max_edge ${HINT_EDGE}`)
      && /nothing was rendered/.test(refused.envelope.error ?? "") && hint !== null
      && tracesRefused.history.length === tracesBefore.history.length
      && tracesRefused.last_export_timestamp === tracesBefore.last_export_timestamp,
    { reply: refused.envelope, before: tracesBefore, after: tracesRefused });
  const entries = plantDetailEntries();
  const board = await detail(ids.board, [CENTRE]);
  const kept = Object.fromEntries(Object.entries(entries).map(([role, name]) => [role, fs.existsSync(path.join(detailDirectory, name))]));
  report.check("the next render removes an abandoned render folder and keeps a fresh one and an unrelated entry",
    !kept.abandoned && kept.fresh && kept.unrelated, { directory: detailDirectory, entries, kept, render_folders_seen: [...renderFolders] });
  removePlanted();
  const tracesAfter = await pollCatalog(traces, () => false);
  const added = tracesAfter.history.slice(tracesBefore.history.length);
  report.check("one detail render leaves exactly one Export history step and the exported mark on the photo",
    added.length === 1 && added[0].name.startsWith("Export")
      && tracesAfter.last_export_timestamp !== null && tracesAfter.last_export_timestamp !== tracesBefore.last_export_timestamp,
    { before: tracesBefore, after: tracesAfter, added });
  report.check("the reply names its source and what it left on the photo",
    board.render.source === "export" && JSON.stringify(board.render.left_on_photo) === JSON.stringify(EXPORT_LEAVES),
    { source: board.render.source, left_on_photo: board.render.left_on_photo });
  const pixels = decodeJpegBase64(board.images[0].data);
  const rate = alternationRate(pixels);
  report.check("the checkerboard crop alternates pixel by pixel", rate >= MIN_ALTERNATION,
    { rate, box: board.regions[0].box, crop: report.preview("checkerboard crop", { jpeg: board.images[0].data }) });
  report.check("the checkerboard renders at its own size", sameSize(board.render, 1200, 800), board.render);
  const boardSizes = sizes(board.render, await planned(ids.board));
  report.check("the checkerboard render is the size get_crop plans with", boardSizes.equal, boardSizes);
  const suggested = hint && { ...HINT_OFFSET, width: Number(hint[1]), height: Number(hint[2]) };
  const fitted = suggested && await session.tool("get_photo_detail", { photo_id: ids.board, regions: [suggested], max_edge: HINT_EDGE }, { timeoutMs: 300_000 });
  const fittedBox = fitted?.data?.regions?.[0]?.box;
  report.check("the region size the refusal suggests, sent back at an offset, renders within max_edge",
    fitted?.isError === false && fittedBox !== undefined && Math.max(fittedBox.width, fittedBox.height) <= HINT_EDGE,
    { suggested, box: fittedBox, error: fitted?.envelope.error });

  const wide = await detail(ids.wide, [CENTRE]);
  report.check("an uncropped fixture renders at its displayed size", sameSize(wide.render, 1000, 600), wide.render);
  const wideSizes = sizes(wide.render, await planned(ids.wide));
  report.check("the uncropped render is the size get_crop plans with", wideSizes.equal, wideSizes);

  const turned = await detail(ids.turned, [CENTRE]);
  report.check("orient_6 renders at its displayed size", sameSize(turned.render, 600, 1000), turned.render);
  const turnedSizes = sizes(turned.render, await planned(ids.turned));
  report.check("the orient_6 render is the size get_crop plans with", turnedSizes.equal, turnedSizes);

  const midState = await state();
  await data("set_crop", { photo_id: ids.wide, rectangle: CROP });
  const cropped = await detail(ids.wide, [CENTRE]);
  report.check("a cropped fixture renders at its cropped displayed size", sameSize(cropped.render, 500, 420), cropped.render);
  const croppedSizes = sizes(cropped.render, await planned(ids.wide));
  report.check("the cropped render is the size get_crop plans with", croppedSizes.equal, croppedSizes);
  await data("set_crop", { photo_id: ids.wide, rectangle: CROP, angle: ANGLE });
  const angled = await detail(ids.wide, [CENTRE]);
  const angledSizes = sizes(angled.render, await planned(ids.wide));
  report.check(`render against get_crop with a crop at ${ANGLE} degrees is recorded`, true, angledSizes);
  await data("set_crop", { photo_id: ids.wide, rectangle: { left: 0, top: 0, right: 1, bottom: 1 } });
  const upright = String((await data("create_virtual_copies", { photo_ids: [ids.raw], copy_name: "LRMCP live detail upright" })).copies[0].copy_photo_id);
  copies.push(upright);
  await data("set_develop_settings", { photo_id: upright, settings: UPRIGHT });
  const transformed = await detail(upright, [CENTRE]);
  const uprightSizes = sizes(transformed.render, await planned(upright));
  report.check("render against get_crop with Upright and a vertical transform is recorded", true, { ...uprightSizes, settings: UPRIGHT });
  await data("remove_photos_from_catalog", { photo_ids: copies.splice(0), confirm: true });

  fs.rmSync(captureDirectory, { recursive: true, force: true });
  fs.mkdirSync(captureDirectory);
  const raw = await detail(ids.raw, [{ x: 0.45, y: 0.45, width: 0.05, height: 0.05 }], 2048);
  report.check("the raw renders whole", raw.render.width * raw.render.height > 20_000_000, { render: raw.render, ms: raw.ms, peak_temporary_bytes: raw.peakTemporaryBytes });
  report.check("render against get_crop on the raw is recorded", true, sizes(raw.render, await planned(ids.raw)));
  const captured = fs.readdirSync(captureDirectory);
  const tables = captured.length > 0 ? jpegQuantTables(fs.readFileSync(path.join(captureDirectory, captured[0]))) : [];
  report.check("the written render's quantisation tables are recorded (not judged: no Adobe top-tier reference exists; the quality is the constructed LR_jpeg_quality 1, pinned offline)",
    tables.length > 0, { captured, tables });
  report.check("the reply states output sharpening off", raw.render.output_sharpening === "off", { render: raw.render, read_from_file: false });

  const after = await state();
  report.check("photo count and selection unchanged", after.count === before.count && JSON.stringify(after.selection) === JSON.stringify(before.selection),
    { before: { count: before.count, selection: before.selection }, after: { count: after.count, selection: after.selection } });
  report.check("develop settings unchanged by the detail renders", JSON.stringify(midState.settings) === JSON.stringify(before.settings),
    { before: before.settings, after_renders: midState.settings });
  report.check("crop restored after the cropped render", JSON.stringify(after.settings) === JSON.stringify(before.settings), { after: after.settings });
  const left = fs.existsSync(detailDirectory) ? fs.readdirSync(detailDirectory, { recursive: true }).map(String) : [];
  report.check("no render folder or file is left behind", left.length === 0, { directory: detailDirectory, left });
  report.finish({ ids, timings_ms: { board: board.ms, wide: wide.ms, turned: turned.ms, cropped: cropped.ms, angled: angled.ms, upright: transformed.ms, raw: raw.ms } });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  removePlanted();
  fs.rmSync(captureDirectory, { recursive: true, force: true });
  await session.stop();
}
