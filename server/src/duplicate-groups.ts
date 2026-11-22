import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { batchReply, jpegOf, previewBatch, reasonOf } from "./preview-item.js";
import { areaAverage, decodeJpeg } from "./rendered-image.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface DuplicateGroupArgs {
  photo_ids: Input[];
  time_window_seconds?: number;
  max_hamming_distance?: number;
}
interface Sample {
  photo_id: string;
  capture_time: number;
  hash: boolean[];
}

function hashPreview(encoded: Buffer): boolean[] {
  const { width, height, data } = decodeJpeg(encoded);
  const cells = areaAverage(
    width,
    height,
    9,
    8,
    (pixel) => 0.2126 * data[pixel * 4] + 0.7152 * data[pixel * 4 + 1] + 0.0722 * data[pixel * 4 + 2],
  );
  return Array.from({ length: 64 }, (_, i) => {
    const offset = Math.floor(i / 8) * 9 + (i % 8);
    return cells[offset] > cells[offset + 1];
  });
}

export async function findDuplicateGroups(
  args: DuplicateGroupArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const window = args.time_window_seconds ?? 5;
  const distance = args.max_hamming_distance ?? 10;
  const samples: Sample[][] = [];
  const inputs = [...new Map(args.photo_ids.map((id) => [String(id), id])).values()];
  const batch = await previewBatch(
    dispatcher,
    inputs,
    { action: "render_duplicate_preview", budgetMs },
    options,
    (preview, fail) => {
      const { photo_id } = preview;
      const capture_time = preview.capture_time as number;
      let hash: boolean[];
      try {
        hash = hashPreview(jpegOf(preview));
      } catch (error) {
        fail({ photo_id, reason: reasonOf(error) });
        return;
      }
      if (samples.some((group) => group.some((member) => member.photo_id === photo_id))) return;
      const sample: Sample = { photo_id, capture_time, hash };
      const group = samples.find((group) =>
        group.every(
          (member) =>
            Math.abs(member.capture_time - sample.capture_time) <= window &&
            member.hash.reduce((sum, bit, i) => sum + Number(bit !== sample.hash[i]), 0) <= distance,
        ),
      );
      if (group) group.push(sample);
      else samples.push([sample]);
    },
  );
  const photos = samples.flat().map(({ photo_id, capture_time }) => ({ photo_id, capture_time }));
  return batchReply(
    batch,
    photos.length
      ? {
          groups: samples
            .filter((group) => group.length >= 2)
            .map((group) => ({ photo_ids: group.map((sample) => sample.photo_id) })),
          photos,
          time_window_seconds: window,
          max_hamming_distance: distance,
        }
      : undefined,
  );
}
