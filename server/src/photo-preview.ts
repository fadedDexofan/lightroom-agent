import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { PREVIEW_SIZES, previewEdge, type PreviewSize } from "./preview-sizes.js";
import { batchReply, fallbackItem, jpegOf, previewBatch, previewItem, reasonOf, type CompletedItem, type RenderedPreview } from "./preview-item.js";
import { cutPixels, decodeJpeg, encodeWithin, pixelBox, scaleToEdge, type NormalizedRegion } from "./rendered-image.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface PreviewArgs {
  photo_id: Input;
  size?: PreviewSize;
  region?: NormalizedRegion;
}

export interface PreviewBatchArgs {
  photo_ids: Input[];
  size?: PreviewSize;
}

interface FittedPreview {
  photo_id: string;
  requested_size: number;
  width: number;
  height: number;
  bytes: number;
  scaled_by_server: boolean;
  image: { mime_type: "image/jpeg"; data: string };
}

const DEFAULT_SIZE = PREVIEW_SIZES.cull;
const DEFAULT_BATCH_SIZE = 256;
const MAX_REGION_SOURCE = 2048;
const MAX_BYTES = 3.5 * 1024 * 1024;
const MAX_EDGE = 2000;
const BATCH_BUDGET_BYTES = 8 * 1024 * 1024;

function regionSourceEdge(edge: number, region: NormalizedRegion): number {
  return Math.min(MAX_REGION_SOURCE, Math.ceil(edge / Math.max(region.width, region.height)));
}

function fitted(preview: RenderedPreview, requestedSize: number, image: { width: number; height: number }, encoded: Buffer,
  scaled: boolean): FittedPreview {
  return {
    photo_id: preview.photo_id, requested_size: requestedSize, width: image.width, height: image.height,
    bytes: encoded.length, scaled_by_server: scaled, image: { mime_type: "image/jpeg", data: encoded.toString("base64") },
  };
}

function fitPreview(preview: RenderedPreview, edge: number): FittedPreview {
  const source = jpegOf(preview);
  const image = decodeJpeg(source);
  const target = Math.min(edge, MAX_EDGE);
  if (Math.max(image.width, image.height) <= target && source.length <= MAX_BYTES) {
    return fitted(preview, edge, image, source, false);
  }
  const scaled = Math.max(image.width, image.height) > target ? scaleToEdge(image, target) : image;
  const encoded = encodeWithin(scaled, MAX_BYTES);
  if (!encoded) throw new Error("Preview exceeds the 3.5 MiB byte limit even at JPEG quality 30");
  return fitted(preview, edge, scaled, encoded, scaled !== image);
}

function cropPreview(preview: RenderedPreview, region: NormalizedRegion, requestedSize: number): FittedPreview {
  const decoded = decodeJpeg(jpegOf(preview));
  const source = Math.max(decoded.width, decoded.height) > MAX_EDGE ? scaleToEdge(decoded, MAX_EDGE) : decoded;
  const box = pixelBox(region, source.width, source.height);
  const encoded = encodeWithin({ width: box.width, height: box.height, data: cutPixels(source, box) }, MAX_BYTES);
  if (!encoded) throw new Error("Region preview exceeds the 3.5 MiB byte limit");
  return fitted(preview, requestedSize, box, encoded, source !== decoded);
}

function partsOf(item: CompletedItem, fit: (preview: RenderedPreview) => FittedPreview): PluginReply {
  if ("notFound" in item) return { result: { not_found: [item.notFound] } };
  if ("failed" in item) return { result: { failed: [item.failed] } };
  try {
    return { result: { data: fit(item.preview) } };
  } catch (error) {
    return { result: { failed: [{ photo_id: item.preview.photo_id, reason: reasonOf(error) }] } };
  }
}

export async function renderPreview(
  args: PreviewArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const edge = previewEdge(args.size ?? DEFAULT_SIZE);
  const { region } = args;
  const requested = region ? regionSourceEdge(edge, region) : edge;
  const deadline = performance.now() + budgetMs;
  const request = { action: "render_preview", input: args.photo_id, size: requested };
  const first = await previewItem(dispatcher, request, budgetMs, options);
  const item = "blocked" in first ? await fallbackItem(dispatcher, request, deadline - performance.now(), options) : first;
  if (options?.signal?.aborted) throw new Error("Request cancelled");
  return partsOf(item, region ? (preview) => cropPreview(preview, region, requested) : (preview) => fitPreview(preview, edge));
}

export async function getPhotoPreviews(
  args: PreviewBatchArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const edge = previewEdge(args.size ?? DEFAULT_BATCH_SIZE);
  const previews: (FittedPreview & { position: number })[] = [];
  let bytes = 0;
  const batch = await previewBatch(dispatcher, args.photo_ids, { action: "render_preview", size: edge, budgetMs }, options,
    (rendered, fail, position) => {
      let preview: FittedPreview;
      try {
        preview = fitPreview(rendered, edge);
      } catch (error) {
        fail({ photo_id: rendered.photo_id, reason: reasonOf(error) });
        return;
      }
      if (bytes + preview.bytes > BATCH_BUDGET_BYTES) return false;
      bytes += preview.bytes;
      previews.push({ ...preview, position });
    });
  const ordered = previews.sort((a, b) => a.position - b.position).map(({ position: _position, ...preview }) => preview);
  return batchReply(batch, ordered.length ? { previews: ordered } : undefined);
}
