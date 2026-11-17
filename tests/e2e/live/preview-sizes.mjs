#!/usr/bin/env node
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { decodeJpegBase64 } from "./lib/preview.mjs";
import { createReport } from "./lib/proof.mjs";

const report = createReport("preview sizes delivered at the requested edge, single and batch (lr16-compat 14)");
const { session, marker } = await openLiveSession();

try {
  for (const key of ["arw_14bit", "wide_plain"]) {
    for (const [size, edge] of [["cull", 864], ["review", 1728], [1000, 1000]]) {
      const answer = await session.toolOrThrow("get_photo_preview", { photo_id: requireFixtureId(marker, key), size });
      const pixels = decodeJpegBase64(answer.image.data);
      const longest = Math.max(pixels.w, pixels.h);
      report.check(`${key} size ${size} arrives at ${edge}`, longest === edge, { decoded: `${pixels.w}x${pixels.h}`, reply: answer.data });
    }
  }
  const ids = ["arw_14bit", "wide_plain"].map((key) => String(requireFixtureId(marker, key)));
  for (const [size, edge] of [["cull", 864], ["review", 1728]]) {
    const answer = await session.toolOrThrow("get_photo_previews", { photo_ids: ids, size });
    const edges = answer.images.map((image) => {
      const pixels = decodeJpegBase64(image.data);
      return Math.max(pixels.w, pixels.h);
    });
    report.check(`get_photo_previews size ${size} arrives at ${edge} for every photo`, edges.length === ids.length && edges.every((value) => value === edge), { edges });
  }
  report.finish();
} finally {
  await session.stop();
}
