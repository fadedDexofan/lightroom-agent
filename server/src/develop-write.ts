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

type StoredRow =
  | { photo_id: string; settings: Record<string, unknown> }
  | { photo_id: string; failed: string }
  | { not_found: true }
  | { remaining: true };

type Judged =
  | { photo_id: Input; settings: Record<string, unknown>; known?: string }
  | { photo_id: Input; refused: string; known?: string }
  | { photo_id: Input; unread: string; known: string }
  | { photo_id: Input; notFound: true }
  | { photo_id: Input; remaining: true };

const NOT_FOUND_WHEN_READ = "not found when its stored settings were read";

export async function beforeWrite(read: Promise<PluginReply>): Promise<PluginReply> {
  try {
    const reply = await read;
    return reply.error === undefined
      ? reply
      : { ...reply, error: `${reply.error}; nothing was written`, effect: "none" };
  } catch (error) {
    return { error: `${error instanceof Error ? error.message : String(error)}; nothing was written`, effect: "none" };
  }
}

async function storedRows(
  inputs: Input[],
  keys: string[],
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<{ rows: StoredRow[] } | { reply: PluginReply }> {
  const reply = await beforeWrite(
    dispatcher.call("read_settings_by_input", { photo_ids: inputs, keys }, budgetMs, options),
  );
  if (reply.error !== undefined) return { reply };
  const rows = (reply.result?.data as { rows?: StoredRow[] } | undefined)?.rows;
  if (rows?.length !== inputs.length) {
    return {
      reply: {
        error: "Lightroom did not return one row of stored settings per photo; nothing was written",
        effect: "none",
      },
    };
  }
  return { rows };
}

function judged(photoId: Input, settings: Record<string, unknown>, row: StoredRow): Judged {
  if ("remaining" in row) return { photo_id: photoId, remaining: true };
  if ("not_found" in row) return { photo_id: photoId, notFound: true };
  if ("failed" in row) {
    return {
      photo_id: photoId,
      unread: `its stored settings were not read: ${row.failed}; nothing was written`,
      known: row.photo_id,
    };
  }
  const refused = refusalFor(settings, row.settings);
  return refused
    ? { photo_id: photoId, refused, known: row.photo_id }
    : { photo_id: photoId, settings, known: row.photo_id };
}

function judgedWithoutRead(photoId: Input, settings: Record<string, unknown>): Judged {
  const refused = refusalFor(settings, {});
  return refused ? { photo_id: photoId, refused } : { photo_id: photoId, settings };
}

async function judgedAll(
  items: { photo_id: Input; settings: Record<string, unknown> }[],
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<{ judged: Judged[] } | { reply: PluginReply }> {
  const unread = items.map(({ settings }) => unreadKeys(settings));
  const reading = items.flatMap((item, index) => (unread[index].length ? [index] : []));
  const stored = reading.length
    ? await storedRows(
        reading.map((index) => items[index].photo_id),
        [...new Set(unread.flat())],
        dispatcher,
        budgetMs,
        options,
      )
    : { rows: [] };
  if ("reply" in stored) return stored;
  const rowOf = new Map(reading.map((index, at) => [index, stored.rows[at]]));
  return {
    judged: items.map(({ photo_id, settings }, index) => {
      const row = rowOf.get(index);
      return row ? judged(photo_id, settings, row) : judgedWithoutRead(photo_id, settings);
    }),
  };
}

export function roundingNote(rounded: Rounded[], photoId?: Input): string[] {
  if (!rounded.length) return [];
  return [
    `Rounded to the precision Lightroom keeps${photoId === undefined ? "" : ` on photo ${photoId}`}: ` +
      rounded.map(({ key, requested, written }) => `${key} ${requested} -> ${written}`).join(", "),
  ];
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
  photoId: Input,
  settings: Record<string, unknown>,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const read = await judgedAll([{ photo_id: photoId, settings }], dispatcher, budgetMs, options);
  if ("reply" in read) return read.reply;
  const [item] = read.judged;
  if ("remaining" in item) return { result: { remaining: [photoId] } };
  if ("notFound" in item) return { result: { not_found: [photoId] } };
  if ("unread" in item) return { result: { failed: [{ photo_id: item.known, reason: item.unread }] } };
  if ("refused" in item) return { error: item.refused, effect: "none" };
  return await dispatcher.call(
    "write_develop_settings",
    { photo_id: photoId, settings },
    deadline - performance.now(),
    options,
  );
}

export async function setDevelopSettings(
  args: DevelopWriteArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const { settings, rounded } = roundToPrecision(args.settings);
  const reply = await writeDevelopSettings(args.photo_id, settings, dispatcher, budgetMs, options);
  return withWarnings(reply, roundingNote(rounded));
}

function lostItem(item: Judged, reason: string) {
  if ("known" in item && item.known !== undefined) return { photo_id: item.known, reason };
  return typeof item.photo_id === "number" || /^\d+$/.test(item.photo_id)
    ? { photo_id: String(item.photo_id), reason }
    : { path: item.photo_id, reason };
}

function lostSplit(photos: Judged[], reason: string): PluginReply {
  const failed = photos.flatMap((photo) => {
    if ("refused" in photo) return [lostItem(photo, photo.refused)];
    return "unread" in photo ? [lostItem(photo, photo.unread)] : [];
  });
  const unknown = photos.flatMap((photo) =>
    "settings" in photo ? [lostItem(photo, `the write was sent and its reply was lost (${reason})`)] : [],
  );
  const notFound = photos.flatMap((photo) => ("notFound" in photo ? [photo.photo_id] : []));
  const remaining = photos.flatMap((photo) => ("remaining" in photo ? [photo.photo_id] : []));
  return { result: { failed, unknown, not_found: notFound, remaining } };
}

export async function setDevelopSettingsBatch(
  args: DevelopBatchArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const items = args.photos.map(({ photo_id, settings }) => ({ photo_id, ...roundToPrecision(settings) }));
  const read = await judgedAll(items, dispatcher, budgetMs, options);
  if ("reply" in read) return read.reply;
  const photos = read.judged.map((item) => {
    if ("remaining" in item) return { photo_id: item.photo_id, remaining: true };
    if ("notFound" in item) return { photo_id: item.photo_id, refused: NOT_FOUND_WHEN_READ };
    if ("unread" in item) return { photo_id: item.photo_id, refused: item.unread };
    if ("refused" in item) return { photo_id: item.photo_id, refused: item.refused };
    return { photo_id: item.photo_id, settings: item.settings };
  });
  const warnings = items.flatMap(({ photo_id, rounded }) => roundingNote(rounded, photo_id));
  let reply: PluginReply;
  try {
    reply = await dispatcher.call("write_develop_settings_batch", { photos }, deadline - performance.now(), options);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    if (error instanceof PluginNotSentError) return { error: `${reason}; nothing was written`, effect: "none" };
    return lostSplit(read.judged, reason);
  }
  return withWarnings(reply, warnings);
}
