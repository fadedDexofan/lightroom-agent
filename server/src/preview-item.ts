import type { CallOptions, Dispatcher } from "./dispatcher.js";
import type { Input, ItemFailure, PluginReply } from "./tool-result.js";

export interface RenderedPreview {
  photo_id: string;
  image?: { data?: unknown; mime_type?: unknown };
  [key: string]: unknown;
}

export type PreviewItem =
  | { preview: RenderedPreview }
  | { notFound: Input }
  | { failed: ItemFailure };

const OPEN_IN_DEVELOP = "active_in_develop";

type PluginItemFailure = ItemFailure & { cause?: string };

export interface PreviewRequest {
  action: string;
  input: Input;
  size?: number;
}

const WAY_OUT = " Switch Lightroom to Library and ask again; to see the photo now, call render_photo, which returns its image"
  + " by an export and leaves one Export history step and the exported mark on the photo (not available in read-only mode).";

export function jpegOf(preview: RenderedPreview): Buffer {
  if (preview.image?.mime_type !== "image/jpeg" || typeof preview.image.data !== "string") {
    throw new Error("Plugin returned no JPEG preview");
  }
  return Buffer.from(preview.image.data, "base64");
}

export async function previewItem(
  dispatcher: Pick<Dispatcher, "call">,
  { action, input, size }: PreviewRequest,
  timeoutMs: number,
  options: CallOptions | undefined,
): Promise<PreviewItem> {
  const params = size === undefined ? { photo_ids: [input] } : { photo_ids: [input], size };
  return itemOf(input, await dispatcher.call(action, params, timeoutMs, options));
}

function itemOf(input: Input, response: PluginReply): PreviewItem {
  if (response.error !== undefined) return { failed: { photo_id: String(input), reason: response.error } };
  const parts = response.result ?? {};
  if (parts.not_found?.length) return { notFound: input };
  if (parts.failed?.length) {
    const { cause, ...failure } = parts.failed[0] as PluginItemFailure;
    return { failed: cause === OPEN_IN_DEVELOP ? { ...failure, reason: `${failure.reason}.${WAY_OUT}` } : failure };
  }
  const preview = parts.data as RenderedPreview | undefined;
  if (!preview) return { failed: { photo_id: String(input), reason: "Plugin returned no preview" } };
  return { preview: { ...preview, photo_id: String(preview.photo_id) } };
}

export const PREVIEW_REPLY_RESERVE_MS = 10_000;

export const previewStartLimitMs = (budgetMs: number) => budgetMs - PREVIEW_REPLY_RESERVE_MS;

export interface PreviewBatch {
  failed: ItemFailure[];
  notFound: Input[];
  remaining: Input[];
  warnings: string[];
}

export function batchReply(batch: PreviewBatch, data: unknown): PluginReply {
  return {
    result: {
      ...(data !== undefined ? { data } : {}),
      failed: batch.failed, not_found: batch.notFound, remaining: batch.remaining,
      ...(batch.warnings.length ? { warnings: batch.warnings } : {}),
    },
  };
}

export async function previewBatch(
  dispatcher: Pick<Dispatcher, "call">,
  inputs: readonly Input[],
  request: { action: string; size?: number; budgetMs: number },
  options: CallOptions | undefined,
  accept: (preview: RenderedPreview, fail: (failure: ItemFailure) => void) => boolean | void,
): Promise<PreviewBatch> {
  const deadline = performance.now() + previewStartLimitMs(request.budgetMs);
  const batch: PreviewBatch = { failed: [], notFound: [], remaining: [], warnings: [] };
  const fail = (failure: ItemFailure) => { batch.failed.push(failure); };
  let reached = 0;
  for (; reached < inputs.length; reached++) {
    if (options?.signal?.aborted) throw new Error("Request cancelled");
    const left = deadline - performance.now();
    if (left <= 0) break;
    let item: PreviewItem;
    try {
      item = await previewItem(dispatcher, { action: request.action, input: inputs[reached], size: request.size },
        left + PREVIEW_REPLY_RESERVE_MS, options);
    } catch (error) {
      if (options?.signal?.aborted) throw error;
      batch.warnings.push(`Stopped at ${String(inputs[reached])}: ${reasonOf(error)}`);
      break;
    }
    if ("failed" in item && performance.now() >= deadline) break;
    if ("notFound" in item) batch.notFound.push(item.notFound);
    else if ("failed" in item) fail(item.failed);
    else if (accept(item.preview, fail) === false) break;
  }
  batch.remaining = inputs.slice(reached);
  return batch;
}

export function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
