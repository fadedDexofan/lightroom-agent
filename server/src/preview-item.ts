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
  | { failed: ItemFailure }
  | { blocked: ItemFailure };

export type CompletedItem = Exclude<PreviewItem, { blocked: ItemFailure }>;

const OPEN_IN_DEVELOP = "active_in_develop";

type PluginItemFailure = ItemFailure & { cause?: string };

export interface PreviewRequest {
  action: string;
  input: Input;
  size?: number;
}

const LIBRARY_RENDER_ACTION = "render_preview_in_library";

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
    return cause === OPEN_IN_DEVELOP ? { blocked: failure as ItemFailure } : { failed: failure as ItemFailure };
  }
  const preview = parts.data as RenderedPreview | undefined;
  if (!preview) return { failed: { photo_id: String(input), reason: "Plugin returned no preview" } };
  return { preview: { ...preview, photo_id: String(preview.photo_id) } };
}

export async function fallbackItem(
  dispatcher: Pick<Dispatcher, "call">,
  { action, input, size }: PreviewRequest,
  timeoutMs: number,
  options: CallOptions | undefined,
): Promise<CompletedItem> {
  const params = size === undefined ? { action, photo_ids: [input] } : { action, photo_ids: [input], size };
  let item: PreviewItem;
  try {
    item = itemOf(input, await dispatcher.call(LIBRARY_RENDER_ACTION, params, timeoutMs, options));
  } catch (error) {
    if (options?.signal?.aborted) throw error;
    return { failed: { photo_id: String(input), reason: reasonOf(error) } };
  }
  return "blocked" in item ? { failed: item.blocked } : item;
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
  accept: (preview: RenderedPreview, fail: (failure: ItemFailure) => void, position: number) => boolean | void,
): Promise<PreviewBatch> {
  const deadline = performance.now() + previewStartLimitMs(request.budgetMs);
  const batch: PreviewBatch = { failed: [], notFound: [], remaining: [], warnings: [] };
  const fail = (failure: ItemFailure) => { batch.failed.push(failure); };
  const unfinished: number[] = [];
  const deferred: number[] = [];
  const settle = (item: CompletedItem, position: number): boolean => {
    if ("notFound" in item) batch.notFound.push(item.notFound);
    else if ("failed" in item) fail(item.failed);
    else return accept(item.preview, fail, position) !== false;
    return true;
  };
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
    if ("blocked" in item) { deferred.push(reached); continue; }
    if ("failed" in item && performance.now() >= deadline) break;
    if (!settle(item, reached)) break;
  }
  let finished = reached === inputs.length;
  for (const index of deferred) {
    const left = deadline - performance.now();
    if (!finished || left <= 0) { unfinished.push(index); continue; }
    const item = await fallbackItem(dispatcher, { action: request.action, input: inputs[index], size: request.size },
      left + PREVIEW_REPLY_RESERVE_MS, options);
    if (!settle(item, index)) { unfinished.push(index); finished = false; }
  }
  for (let index = reached; index < inputs.length; index++) unfinished.push(index);
  batch.remaining = unfinished.sort((a, b) => a - b).map((index) => inputs[index]);
  return batch;
}

export function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
