#!/usr/bin/env node
import assert from "node:assert/strict";
import jpeg from "../../../server/node_modules/jpeg-js/index.js";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
const ids = ["wide_plain", "pano", "orient_6"].map(key => requireFixtureId(marker, key));
const photoId = ids[0];
let original, originalReason;
try {
  const response = await session.rpc("tools/call", { name: "get_photo_previews", arguments: { photo_ids: ids } });
  assert.equal(response.isError, undefined);
  const envelope = JSON.parse(response.content[0].text);
  const data = envelope.data;
  const images = response.content.filter(block => block.type === "image");
  assert.equal(envelope.outcome, "done");
  assert.equal(images.length, 3);
  assert.deepEqual(data.previews.map(item => item.photo_id), ids.map(String));
  for (const [index, image] of images.entries()) {
    const pixels = jpeg.decode(Buffer.from(image.data, "base64"), { useTArray: true });
    assert.ok(Math.max(pixels.width, pixels.height) <= 2000);
    assert.equal(data.previews[index].image_index, index + 1);
    console.log(JSON.stringify({ photo_id: ids[index], width: pixels.width, height: pixels.height }));
  }
  original = await session.photoMetadata(photoId);
  originalReason = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data.photos[0].reason ?? "";
  await session.toolOrThrow("set_rating_and_flag", { photo_ids: [photoId], flag: "reject" });
  await session.toolOrThrow("set_color_label", { photo_ids: [photoId], label: "yellow" });
  await session.toolOrThrow("set_ai_metadata", { photo_ids: [photoId], reason: "Live batch-preview cull verification" });
  const metadata = await session.photoMetadata(photoId);
  assert.equal(metadata.flag, "reject");
  assert.equal(metadata.color_label, "yellow");
  const ai = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data;
  assert.equal(ai.photos[0].reason, "Live batch-preview cull verification");
  console.log("pass batch previews, reject flag, yellow label and private reason");
} finally {
  try {
    if (original && originalReason !== undefined) {
      await session.toolOrThrow("set_rating_and_flag", { photo_ids: [photoId], flag: original.flag });
      await session.toolOrThrow("set_color_label", { photo_ids: [photoId], label: original.color_label });
      await session.toolOrThrow("set_ai_metadata", { photo_ids: [photoId], reason: originalReason });
      const restored = await session.photoMetadata(photoId);
      assert.equal(restored.flag, original.flag);
      assert.equal(restored.color_label, original.color_label);
      const ai = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data;
      assert.equal(ai.photos[0].reason ?? "", originalReason);
      console.log("pass exact flag, label and reason baseline restored");
    }
  } finally {
    await session.stop();
  }
}
