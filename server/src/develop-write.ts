import { PluginNotSentError, type CallOptions, type Dispatcher } from "./dispatcher.js";
import { roundToPrecision, rulesTouchedBy, type Rounded } from "./develop-keys.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface DevelopWriteArgs {
  photo_id: Input;
  settings: Record<string, unknown>;
}

export interface DevelopBatchArgs {
  photos: DevelopWriteArgs[];
}

interface StoredRead {
  photos?: { settings?: Record<string, unknown> }[];
}

export async function beforeWrite(read: Promise<PluginReply>): Promise<PluginReply> {
  try {
    const reply = await read;
    return reply.error === undefined ? reply : { ...reply, error: `${reply.error}; nothing was written`, effect: "none" };
  } catch (error) {
    return { error: `${error instanceof Error ? error.message : String(error)}; nothing was written`, effect: "none" };
  }
}

async function storedValues(
  photoId: Input, keys: string[], dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<{ values: Record<string, unknown> } | { reply: PluginReply }> {
  if (!keys.length) return { values: {} };
  const reply = await beforeWrite(dispatcher.call("get_develop_settings", { photo_ids: [photoId], keys }, budgetMs, options));
  const settings = (reply.result?.data as StoredRead | undefined)?.photos?.[0]?.settings;
  return settings ? { values: settings } : { reply };
}

export function roundingNote(rounded: Rounded[], photoId?: Input): string[] {
  if (!rounded.length) return [];
  return [`Rounded to the precision Lightroom keeps${photoId === undefined ? "" : ` on photo ${photoId}`}: `
    + rounded.map(({ key, requested, written }) => `${key} ${requested} -> ${written}`).join(", ")];
}

function unreadKeys(settings: Record<string, unknown>): string[] {
  return [...new Set(rulesTouchedBy(settings).flatMap((rule) => rule.reads))].filter((key) => !(key in settings));
}

function refusalFor(settings: Record<string, unknown>, stored: Record<string, unknown>): string | undefined {
  const values = { ...stored, ...settings };
  const broken = rulesTouchedBy(settings).filter((rule) => !rule.holds(values));
  return broken.length ? `Refused before writing: ${broken.map((rule) => rule.text).join("; ")}` : undefined;
}

export function withWarnings(reply: PluginReply, warnings: string[]): PluginReply {
  if (!warnings.length || reply.error !== undefined) return reply;
  const parts = reply.result ?? {};
  return { ...reply, result: { ...parts, warnings: [...(parts.warnings ?? []), ...warnings] } };
}

export async function writeDevelopSettings(
  photoId: Input, settings: Record<string, unknown>, dispatcher: Pick<Dispatcher, "call">, budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const stored = await storedValues(photoId, unreadKeys(settings), dispatcher, budgetMs, options);
  if ("reply" in stored) return stored.reply;
  const refusal = refusalFor(settings, stored.values);
  if (refusal) return { error: refusal, effect: "none" };
  return await dispatcher.call("write_develop_settings", { photo_id: photoId, settings }, deadline - performance.now(),
    options);
}

export async function setDevelopSettings(
  args: DevelopWriteArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const { settings, rounded } = roundToPrecision(args.settings);
  const reply = await writeDevelopSettings(args.photo_id, settings, dispatcher, budgetMs, options);
  return withWarnings(reply, roundingNote(rounded));
}

async function storedByInput(
  inputs: Input[], keys: string[], dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<{ values: Map<Input, Record<string, unknown>> } | { reply: PluginReply }> {
  const values = new Map<Input, Record<string, unknown>>();
  if (!inputs.length || !keys.length) return { values };
  const reply = await beforeWrite(dispatcher.call("get_develop_settings", { photo_ids: inputs, keys }, budgetMs, options));
  const photos = (reply.result?.data as StoredRead | undefined)?.photos;
  if (!photos) return { reply };
  const missing = new Set((reply.result?.not_found ?? []).map(String));
  let next = 0;
  for (const input of inputs) {
    if (missing.has(String(input))) continue;
    values.set(input, photos[next++]?.settings ?? {});
  }
  return { values };
}

export async function setDevelopSettingsBatch(
  args: DevelopBatchArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const items = args.photos.map(({ photo_id, settings }) => ({ photo_id, ...roundToPrecision(settings) }));
  const unread = items.map(({ settings }) => unreadKeys(settings));
  const reading = items.filter((_, index) => unread[index].length > 0).map(({ photo_id }) => photo_id);
  const stored = await storedByInput(reading, [...new Set(unread.flat())], dispatcher, budgetMs, options);
  if ("reply" in stored) return stored.reply;
  const photos = items.map(({ photo_id, settings }) => {
    const refused = refusalFor(settings, stored.values.get(photo_id) ?? {});
    return refused ? { photo_id, refused } : { photo_id, settings };
  });
  const warnings = items.flatMap(({ photo_id, rounded }) => roundingNote(rounded, photo_id));
  let reply: PluginReply;
  try {
    reply = await dispatcher.call("write_develop_settings_batch", { photos }, deadline - performance.now(), options);
  } catch (error) {
    if (options?.signal?.aborted) throw error;
    const reason = error instanceof Error ? error.message : String(error);
    if (error instanceof PluginNotSentError) return { error: `${reason}; nothing was written`, effect: "none" };
    return { result: {
      failed: photos.flatMap((photo) => ("refused" in photo ? [{ photo_id: String(photo.photo_id), reason: photo.refused as string }] : [])),
      unknown: photos.flatMap((photo) => ("refused" in photo ? [] : [{
        photo_id: String(photo.photo_id), reason: `the write was sent and its reply was lost (${reason})`,
      }])),
    } };
  }
  return withWarnings(reply, warnings);
}
