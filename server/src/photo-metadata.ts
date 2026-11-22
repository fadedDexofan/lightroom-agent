import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { reasonOf } from "./preview-item.js";
import type { Input, ItemFailure, PluginReply } from "./tool-result.js";

export interface PhotoMetadataArgs {
  photo_ids: Input[];
  lens_profile?: boolean;
}

type PhotoRecord = { photo_id: string; [field: string]: unknown };

function photosOf(reply: PluginReply): PhotoRecord[] {
  return (reply.result?.data as { photos?: PhotoRecord[] } | undefined)?.photos ?? [];
}

export async function getPhotoMetadata(
  args: PhotoMetadataArgs,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const reply = await dispatcher.call("read_photo_metadata", { photo_ids: args.photo_ids }, budgetMs, options);
  const photos = photosOf(reply);
  if (!args.lens_profile || reply.error !== undefined || photos.length === 0) return reply;
  let lens: PluginReply;
  try {
    lens = await dispatcher.call(
      "read_lens_profiles",
      { photo_ids: [...new Set(photos.map((photo) => photo.photo_id))] },
      deadline - performance.now(),
      options,
    );
  } catch (error) {
    if (options?.signal?.aborted) throw error;
    lens = { error: reasonOf(error) };
  }
  const parts = reply.result ?? {};
  const failed: ItemFailure[] = [...(parts.failed ?? [])];
  if (lens.error !== undefined) {
    const reason = `the lens profile was not read: ${lens.error}`;
    for (const id of new Set(photos.map((photo) => photo.photo_id))) failed.push({ photo_id: id, reason });
    return { ...reply, result: { ...parts, failed } };
  }
  failed.push(...(lens.result?.failed ?? []));
  for (const id of lens.result?.not_found ?? [])
    failed.push({ photo_id: String(id), reason: "not found when its lens profile was read" });
  const profiles = new Map(photosOf(lens).map((photo) => [photo.photo_id, { ...(photo.lens_profile as object) }]));
  const merged = photos.map((photo) =>
    profiles.has(photo.photo_id) ? { ...photo, lens_profile: profiles.get(photo.photo_id) } : photo,
  );
  return { ...reply, result: { ...parts, failed, data: { ...(parts.data as object), photos: merged } } };
}
