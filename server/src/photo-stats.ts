import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { jpegOf, previewBatch, reasonOf } from "./preview-item.js";
import { areaAverage, decodeJpeg } from "./rendered-image.js";
import type { Input, PluginReply } from "./tool-result.js";

const BINS = 64;
const STATS_PREVIEW_SIZE = 512;
const LONG_EDGE = 512;
const rounded = (value: number) => Math.round(value * 1e6) / 1e6;

export function photoStats(encoded: Buffer) {
  const { width, height, data } = decodeJpeg(encoded);
  const luma = new Float64Array(width * height);
  const histogram = Array<number>(BINS).fill(0);
  let shadows = 0, highlights = 0, sum = 0;
  for (let i = 0; i < luma.length; i++) {
    const value = 0.2126 * data[i * 4] + 0.7152 * data[i * 4 + 1] + 0.0722 * data[i * 4 + 2];
    luma[i] = value;
    histogram[(value / 4) | 0]++;
    if (value <= 1) shadows++;
    if (value >= 254) highlights++;
    sum += value;
  }
  const scale = LONG_EDGE / Math.max(width, height);
  const targetWidth = Math.max(3, Math.round(width * scale));
  const targetHeight = Math.max(3, Math.round(height * scale));
  const resized = areaAverage(width, height, targetWidth, targetHeight, (pixel) => luma[pixel]);
  let laplacianSum = 0, squares = 0, count = 0;
  for (let y = 1; y < targetHeight - 1; y++) {
    for (let x = 1; x < targetWidth - 1; x++) {
      const i = y * targetWidth + x;
      const value = resized[i - 1] + resized[i + 1] + resized[i - targetWidth]
        + resized[i + targetWidth] - 4 * resized[i];
      laplacianSum += value;
      squares += value * value;
      count++;
    }
  }
  return {
    width, height,
    histogram: histogram.map((value) => rounded(value / luma.length)),
    mean_luminance: rounded(sum / luma.length),
    shadow_fraction: rounded(shadows / luma.length),
    highlight_fraction: rounded(highlights / luma.length),
    sharpness: rounded(Math.max(0, squares / count - (laplacianSum / count) ** 2)),
  };
}

export async function getPhotoStats(
  dispatcher: Pick<Dispatcher, "call">,
  photoIds: Input[],
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const results: ({ photo_id: string } & ReturnType<typeof photoStats>)[] = [];
  const batch = await previewBatch(dispatcher, photoIds, { action: "render_preview", size: STATS_PREVIEW_SIZE, budgetMs }, options,
    (preview, fail) => {
      try {
        results.push({ photo_id: preview.photo_id, ...photoStats(jpegOf(preview)) });
      } catch (error) {
        fail({ photo_id: preview.photo_id, reason: reasonOf(error) });
      }
    });
  return {
    result: {
      ...(results.length ? { data: { results } } : {}),
      failed: batch.failed, not_found: batch.notFound, remaining: batch.remaining,
      ...(batch.warnings.length ? { warnings: batch.warnings } : {}),
    },
  };
}
