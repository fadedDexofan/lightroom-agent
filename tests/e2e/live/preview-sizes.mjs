#!/usr/bin/env node
import { isDeepStrictEqual } from "node:util";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { decodeJpegBase64 } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const LONG_EDGE = { arw_14bit: 6000, wide_plain: 1000 };
const report = createReport("preview sizes delivered at the requested edge, single and batch (lr16-compat 14)");
const { session, marker } = await openLiveSession();

try {
  for (const key of ["arw_14bit", "wide_plain"]) {
    for (const [size, edge] of [
      ["cull", 864],
      ["review", 1728],
      [1000, 1000],
    ]) {
      const answer = await session.toolOrThrow("get_photo_preview", { photo_id: requireFixtureId(marker, key), size });
      const pixels = decodeJpegBase64(answer.image.data);
      const longest = Math.max(pixels.w, pixels.h);
      const expected = Math.min(edge, LONG_EDGE[key]);
      report.check(`${key} size ${size} arrives at ${expected}`, longest === expected, {
        decoded: `${pixels.w}x${pixels.h}`,
        reply: answer.data,
        long_edge: LONG_EDGE[key],
      });
    }
  }
  const ids = ["arw_14bit", "wide_plain"].map((key) => String(requireFixtureId(marker, key)));
  for (const [size, edge] of [
    ["cull", 864],
    ["review", 1728],
  ]) {
    const answer = await session.toolOrThrow("get_photo_previews", { photo_ids: ids, size });
    const edges = answer.images.map((image) => {
      const pixels = decodeJpegBase64(image.data);
      return Math.max(pixels.w, pixels.h);
    });
    const expected = ["arw_14bit", "wide_plain"].map((key) => Math.min(edge, LONG_EDGE[key]));
    report.check(
      `get_photo_previews size ${size} arrives at ${expected.join(" and ")}`,
      isDeepStrictEqual(edges, expected),
      { edges, expected },
    );
  }
  report.finish();
} finally {
  await session.stop();
}
