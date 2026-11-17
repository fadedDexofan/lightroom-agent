import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { outOfRange, roundToPrecision } from "./develop-keys.js";
import { beforeWrite, roundingNote, withWarnings, writeDevelopSettings } from "./develop-write.js";
import type { Input, PluginReply } from "./tool-result.js";

interface Rectangle { left: number; top: number; right: number; bottom: number }

export interface CropArgs {
  photo_id: Input;
  rectangle?: Rectangle;
  aspect?: { width: number; height: number };
  center?: { x: number; y: number };
  scale?: number;
  angle?: number;
  relative_to?: "photo" | "crop";
}

interface PlannedCrop {
  photo_id: string;
  settings: Record<string, number>;
  rectangle: Rectangle;
  angle: number;
  size: { width: number; height: number };
}

export async function setCrop(
  args: CropArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const deadline = performance.now() + budgetMs;
  const requested = roundToPrecision({ CropAngle: args.angle ?? 0 });
  const plan = await beforeWrite(dispatcher.call("plan_crop", { ...args, angle: requested.settings.CropAngle }, budgetMs, options));
  if (plan.error !== undefined || plan.result?.data === undefined) return plan;
  const planned = plan.result?.data as PlannedCrop;
  const { settings } = roundToPrecision(planned.settings);
  const outside = outOfRange(settings);
  if (outside.length) {
    const needs = outside.map(({ key, value, range }) => `${key} ${value}, outside the range ${range[0]} to ${range[1]} Lightroom keeps`);
    return { error: `This frame needs ${needs.join("; ")}; nothing was written`, effect: "none" };
  }
  const written = await writeDevelopSettings(args.photo_id, settings, dispatcher, deadline - performance.now(), options);
  if (written.error !== undefined) return written;
  const parts = written.result ?? {};
  const stored = parts.data as { settings?: Record<string, unknown>; adjusted?: unknown[] } | undefined;
  const data = {
    photo_id: planned.photo_id,
    rectangle: planned.rectangle,
    angle: planned.angle,
    size: planned.size,
    settings: stored?.settings ?? {},
    ...(stored?.adjusted ? { adjusted: stored.adjusted } : {}),
  };
  return withWarnings({ result: { ...parts, data } }, [...(plan.result?.warnings ?? []), ...roundingNote(requested.rounded)]);
}
