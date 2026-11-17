import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { keysRefusedFor, roundToPrecision, rulesTouchedBy, writtenElsewhereText, type Rounded } from "./develop-keys.js";
import type { Input, PluginReply } from "./tool-result.js";

export interface DevelopWriteArgs {
  photo_id: Input;
  settings: Record<string, unknown>;
}

interface StoredRead {
  photos?: { settings?: Record<string, unknown> }[];
}

export async function beforeWrite(read: Promise<unknown>): Promise<PluginReply> {
  try {
    const reply = await read as PluginReply;
    return reply.error === undefined ? reply : { ...reply, error: `${reply.error}; nothing was written`, effect: "none" };
  } catch (error) {
    return { error: `${error instanceof Error ? error.message : String(error)}; nothing was written`, effect: "none" };
  }
}

export async function storedValues(
  photoId: Input, keys: string[], dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<{ values: Record<string, unknown> } | { reply: PluginReply }> {
  if (!keys.length) return { values: {} };
  const reply = await beforeWrite(dispatcher.call("get_develop_settings", { photo_ids: [photoId], keys }, budgetMs, options));
  const settings = (reply.result?.data as StoredRead | undefined)?.photos?.[0]?.settings;
  return settings ? { values: settings } : { reply };
}

export function roundingNote(rounded: Rounded[]): string[] {
  if (!rounded.length) return [];
  return ["Rounded to the precision Lightroom keeps: "
    + rounded.map(({ key, requested, written }) => `${key} ${requested} -> ${written}`).join(", ")];
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
  const rules = rulesTouchedBy(settings);
  const unread = [...new Set(rules.flatMap((rule) => rule.reads))].filter((key) => !(key in settings));
  const stored = await storedValues(photoId, unread, dispatcher, budgetMs, options);
  if ("reply" in stored) return stored.reply;
  const values = { ...stored.values, ...settings };
  const broken = rules.filter((rule) => !rule.holds(values));
  if (broken.length) {
    return { error: `Refused before writing: ${broken.map((rule) => rule.text).join("; ")}`, effect: "none" };
  }
  return await dispatcher.call("write_develop_settings", { photo_id: photoId, settings }, deadline - performance.now(),
    options) as PluginReply;
}

export async function setDevelopSettings(
  args: DevelopWriteArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const elsewhere = keysRefusedFor("set_develop_settings", Object.keys(args.settings));
  if (elsewhere.length) return { error: `Refused before writing: ${writtenElsewhereText(elsewhere)}`, effect: "none" };
  const { settings, rounded } = roundToPrecision(args.settings);
  const reply = await writeDevelopSettings(args.photo_id, settings, dispatcher, budgetMs, options);
  return withWarnings(reply, roundingNote(rounded));
}
