import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { withRenderedFile } from "./photo-detail.js";
import { MAX_IMAGE_BYTES, PREVIEW_SIZES, previewEdge, type PreviewSize } from "./preview-sizes.js";
import { decodeJpeg } from "./rendered-image.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface RenderPhotoArgs {
  photo_id: Input;
  size?: PreviewSize;
}

export const RENDITION_JPEG_QUALITY = 80;
const DEFAULT_SIZE = PREVIEW_SIZES.review;

export async function renderPhoto(
  args: RenderPhotoArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const reply = await dispatcher.call("render_source",
    { photo_id: args.photo_id, long_edge: previewEdge(args.size ?? DEFAULT_SIZE), tool: "render_photo" }, budgetMs, options);
  return withRenderedFile(reply, (file, source) => {
    if (file.length > MAX_IMAGE_BYTES) {
      throw new Error(`Lightroom's rendition is ${file.length} bytes, over the ${MAX_IMAGE_BYTES / 1024 / 1024} MiB image limit; ask for a smaller size`);
    }
    const { width, height } = decodeJpeg(file);
    return {
      photo_id: String(source.photo_id), width, height, bytes: file.length, jpeg_quality: RENDITION_JPEG_QUALITY,
      left_on_photo: source.left_on_photo, image: { mime_type: "image/jpeg", data: file.toString("base64") },
    };
  });
}
