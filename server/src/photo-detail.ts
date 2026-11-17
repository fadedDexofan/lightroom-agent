import { readFile, rm } from "node:fs/promises";
import { basename, dirname } from "node:path";
import jpeg from "jpeg-js";
import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { beforeWrite } from "./develop-write.js";
import { cutPixels, decodeJpeg, pixelBox, type NormalizedRegion } from "./rendered-image.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface DetailArgs {
  photo_id: Input;
  regions: NormalizedRegion[];
  max_edge?: number;
}

interface RenderSource {
  photo_id: string | number;
  path: string;
  source: string;
  left_on_photo: string[];
}

export const DEFAULT_DETAIL_EDGE = 1024;
export const MAX_DETAIL_EDGE = 2048;
const CROP_JPEG_QUALITY = 95;
export const DETAIL_RENDER_FOLDER = "lightroom-mcp-detail";
const RENDER = { jpeg_quality: 100, color_space: "sRGB", output_sharpening: "off" } as const;

const floor4 = (value: number) => Math.floor(value * 10_000) / 10_000;

function overLimit(regions: NormalizedRegion[], width: number, height: number, limit: number): string | undefined {
  const boxes = regions.map((region) => pixelBox(region, width, height));
  const over = boxes.findIndex((box) => Math.max(box.width, box.height) > limit);
  if (over < 0) return undefined;
  return `region ${over + 1} is ${boxes[over].width}x${boxes[over].height} px, over max_edge ${limit}; `
    + `this photo allows regions up to width ${floor4((limit - 1) / width)} and height ${floor4((limit - 1) / height)}`;
}

export async function getPhotoDetail(
  args: DetailArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const limit = args.max_edge ?? DEFAULT_DETAIL_EDGE;
  const crop = await beforeWrite(dispatcher.call("get_crop", { photo_id: args.photo_id }, budgetMs, options));
  const frame = (crop.result?.data as { size?: { width: number; height: number } } | undefined)?.size;
  if (crop.error !== undefined || !frame) return crop;
  const predicted = overLimit(args.regions, frame.width, frame.height, limit);
  if (predicted) {
    return { error: `${predicted} (cropped frame ${frame.width}x${frame.height}); nothing was rendered`, effect: "none" };
  }
  const reply = await dispatcher.call("render_detail_source", { photo_id: args.photo_id },
    deadline - performance.now(), options) as PluginReply;
  const source = reply.result?.data as RenderSource | undefined;
  if (reply.error !== undefined || !source) return reply;
  const left = `; the render left ${source.left_on_photo.join(" and ")} on the photo`;
  try {
    const image = decodeJpeg(await readFile(source.path));
    const rendered = overLimit(args.regions, image.width, image.height, limit);
    if (rendered) return { error: `${rendered} (render ${image.width}x${image.height})${left}` };
    const boxes = args.regions.map((region) => pixelBox(region, image.width, image.height));
    const regions = boxes.map((box) => ({
      box,
      image: {
        mime_type: "image/jpeg",
        data: jpeg.encode({ width: box.width, height: box.height, data: cutPixels(image, box) }, CROP_JPEG_QUALITY)
          .data.toString("base64"),
      },
    }));
    return {
      result: {
        data: {
          photo_id: String(source.photo_id),
          render: {
            width: image.width, height: image.height, ...RENDER, source: source.source, left_on_photo: source.left_on_photo,
          },
          crop_jpeg_quality: CROP_JPEG_QUALITY,
          regions,
        },
      },
    };
  } catch (error) {
    return { error: `${error instanceof Error ? error.message : String(error)}${left}` };
  } finally {
    const folder = dirname(source.path);
    if (basename(dirname(folder)) === DETAIL_RENDER_FOLDER) await rm(folder, { recursive: true, force: true });
  }
}
