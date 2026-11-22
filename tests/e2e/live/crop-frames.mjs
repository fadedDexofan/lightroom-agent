#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { MARKER_DISCS } from "./lib/patterns.mjs";
import { changeCentroid, colorCentroid, fetchStablePixels, measureChange, regionDeltas } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const SIZE = 1728;
const MAX_ERROR = 0.002;
const MAX_ASPECT_ERROR = 0.005;
const ANGLE = 8;
const RADIAL = { width: 0.12, height: 0.12, rotation: 0, feather: 0 };
const BOOST = { local_Exposure: 2 };
const LINEAR_REACH = 0.15;
const LEVEL_DIFFERENCE = 0.01;
const FULL_FRAME = { left: 0, top: 0, right: 1, bottom: 1 };
const RED = MARKER_DISCS.find((disc) => disc.name === "red").color;
const ORIENT_WIDTH = 1000;
const ORIENT_HEIGHT = 600;

const report = createReport("masks and crops in the displayed frame (lr16-compat 06, edit-breadth 07)");
const { session, marker } = await openLiveSession();
const id = (key) => String(requireFixtureId(marker, key));
const answer = (name, args) => session.toolOrThrow(name, args, { timeoutMs: 120_000 });
const data = async (name, args) => (await answer(name, args)).data;
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const touched = new Set();

async function redDisc(photoId) {
  const pixels = await fetchStablePixels(session, photoId, { size: SIZE });
  const disc = colorCentroid(pixels, RED);
  if (!disc) throw new Error(`no red disc visible on photo ${photoId}`);
  return { ...disc, preview: report.preview(`photo ${photoId} disc`, pixels) };
}

async function radialLands(label, photoId, crop) {
  touched.add(photoId);
  await data("set_crop", { photo_id: photoId, ...crop });
  const target = await redDisc(photoId);
  let created;
  const pixels = await measureChange(
    session,
    photoId,
    async () => {
      created = await answer("create_gradient_mask", {
        photo_id: photoId,
        shape: "radial",
        center: { x: target.x, y: target.y },
        ...RADIAL,
        adjustments: BOOST,
      });
    },
    { size: SIZE },
  );
  const rendered = changeCentroid(pixels.before, pixels.after);
  const error = rendered ? distance(rendered, target) : null;
  report.check(
    `${label}: a radial at the disc's displayed position renders on it`,
    error !== null && error <= MAX_ERROR,
    {
      target,
      rendered,
      error,
      warnings: created.envelope.warnings ?? [],
      previews: {
        before: report.preview(`${label} radial before`, pixels.before),
        after: report.preview(`${label} radial after`, pixels.after),
      },
    },
  );
  await data("delete_masks", { photo_id: photoId, all: true });
  return target;
}

async function linearIsLevel(label, photoId, target) {
  const pixels = await measureChange(
    session,
    photoId,
    async () => {
      await answer("create_gradient_mask", {
        photo_id: photoId,
        shape: "linear",
        start: { x: target.x - 0.05, y: target.y },
        end: { x: target.x + 0.05, y: target.y },
        adjustments: BOOST,
      });
    },
    { size: SIZE },
  );
  const box = (name, x, y) => ({ name, x0: x - 0.01, y0: y - 0.01, x1: x + 0.01, y1: y + 0.01 });
  const deltas = regionDeltas(pixels.before, pixels.after, [
    box("start", target.x - LINEAR_REACH, target.y),
    box("end", target.x + LINEAR_REACH, target.y),
    box("above", target.x, target.y - LINEAR_REACH),
    box("below", target.x, target.y + LINEAR_REACH),
  ]);
  report.check(
    `${label}: a horizontal linear gradient renders horizontal`,
    deltas.start > deltas.end + 0.05 && Math.abs(deltas.above - deltas.below) < LEVEL_DIFFERENCE,
    deltas,
  );
  await data("delete_masks", { photo_id: photoId, all: true });
}

try {
  const straight = id("markers_1");
  const target = await radialLands("markers_1 cropped at 8°", straight, {
    rectangle: { left: 0.15, top: 0.1, right: 0.92, bottom: 0.9 },
    angle: ANGLE,
  });
  await linearIsLevel("markers_1 cropped at 8°", straight, target);

  await data("set_develop_settings", { photo_id: straight, settings: { PerspectiveUpright: 4 } });
  const warped = await answer("create_gradient_mask", {
    photo_id: straight,
    shape: "radial",
    center: { x: target.x, y: target.y },
    ...RADIAL,
    adjustments: BOOST,
  });
  report.check("markers_1 with Upright 4: the write carries a warning", (warped.envelope.warnings ?? []).length > 0, {
    warnings: warped.envelope.warnings ?? [],
  });
  await data("delete_masks", { photo_id: straight, all: true });
  await data("set_develop_settings", { photo_id: straight, settings: { PerspectiveUpright: 0 } });

  for (const orientation of [6, 8]) {
    await radialLands(`markers_${orientation} cropped off-centre at 8°`, id(`markers_${orientation}`), {
      rectangle: { left: 0.1, top: 0.15, right: 0.8, bottom: 0.85 },
      angle: ANGLE,
    });
  }

  for (const orientation of [1, 6, 8]) {
    const photoId = id(`orient_${orientation}`);
    touched.add(photoId);
    const crop = await data("set_crop", {
      photo_id: photoId,
      aspect: { width: 4, height: 5 },
      center: { x: 0.5, y: 0.5 },
    });
    const pixels = await fetchStablePixels(session, photoId, { size: SIZE });
    const aspect = pixels.w / pixels.h;
    const centre = {
      x: (crop.rectangle.left + crop.rectangle.right) / 2,
      y: (crop.rectangle.top + crop.rectangle.bottom) / 2,
    };
    report.check(
      `orient_${orientation}: a 4:5 crop renders at 4:5 around the centre`,
      Math.abs(aspect / 0.8 - 1) <= MAX_ASPECT_ERROR &&
        distance(centre, { x: 0.5, y: 0.5 }) <= MAX_ERROR &&
        !crop.adjusted,
      {
        preview: `${pixels.w}x${pixels.h}`,
        aspect,
        rectangle: crop.rectangle,
        size: crop.size,
        adjusted: crop.adjusted ?? null,
      },
    );
  }
  const nested = id("orient_1");
  touched.add(nested);
  const base = { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 };
  const turnedBox = ({ rectangle, angle }) => {
    const radians = (Math.abs(angle) * Math.PI) / 180;
    const width = (rectangle.right - rectangle.left) * ORIENT_WIDTH;
    const height = (rectangle.bottom - rectangle.top) * ORIENT_HEIGHT;
    const cx = ((rectangle.left + rectangle.right) / 2) * ORIENT_WIDTH;
    const cy = ((rectangle.top + rectangle.bottom) / 2) * ORIENT_HEIGHT;
    const halfX = (width * Math.cos(radians) + height * Math.sin(radians)) / 2;
    const halfY = (width * Math.sin(radians) + height * Math.cos(radians)) / 2;
    return {
      left: (cx - halfX) / ORIENT_WIDTH,
      right: (cx + halfX) / ORIENT_WIDTH,
      top: (cy - halfY) / ORIENT_HEIGHT,
      bottom: (cy + halfY) / ORIENT_HEIGHT,
    };
  };
  const within = (outer, inner) =>
    inner.left >= outer.left - 1e-4 &&
    inner.right <= outer.right + 1e-4 &&
    inner.top >= outer.top - 1e-4 &&
    inner.bottom <= outer.bottom + 1e-4;

  await data("set_crop", { photo_id: nested, rectangle: base });
  const current = await data("get_crop", { photo_id: nested });
  const fit = await data("set_crop", {
    photo_id: nested,
    relative_to: "crop",
    aspect: { width: 1, height: 1 },
    center: { x: 0.95, y: 0.5 },
    angle: ANGLE,
  });
  report.check(
    "relative_to crop: a turned aspect fit near the edge stays inside the current crop",
    within(current.rectangle, turnedBox(fit)),
    { current: current.rectangle, result: fit.rectangle, angle: fit.angle, turned_box: turnedBox(fit) },
  );

  await data("set_crop", { photo_id: nested, rectangle: base });
  const whole = await session.tool("set_crop", {
    photo_id: nested,
    relative_to: "crop",
    rectangle: { left: 0, top: 0, right: 1, bottom: 1 },
    angle: ANGLE,
  });
  await data("set_crop", { photo_id: nested, rectangle: base });
  const steep = await session.tool("set_crop", {
    photo_id: nested,
    relative_to: "crop",
    rectangle: { left: 0, top: 0, right: 1, bottom: 1 },
    angle: 40,
  });
  report.check(
    "relative_to crop: a turned rectangle is held to the photo's edges, not the crop's",
    !whole.isError && !within(base, turnedBox(whole.data)) && steep.isError,
    {
      at_8: whole.isError ? whole.text : { rectangle: whole.data.rectangle, turned_box: turnedBox(whole.data) },
      at_40: steep.isError ? steep.text : steep.data,
    },
  );
  report.finish();
} finally {
  for (const photoId of touched) {
    await session.tool("delete_masks", { photo_id: photoId, all: true });
    await session.tool("set_crop", { photo_id: photoId, rectangle: FULL_FRAME });
  }
  await session.stop();
}
