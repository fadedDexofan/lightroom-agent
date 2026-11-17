import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { DEVELOP_KEYS, LOCAL_KEYS, type DevelopKey, type LocalKey } from "./develop-keys.js";
import type { Input, PluginReply } from "./tool-result.js";

type Range = readonly [number, number];

export interface DescribeArgs {
  photo_id: Input;
  mask_id?: string;
}

interface LiveRanges {
  photo_id: string;
  lightroom: { version: string; build?: string };
  process_version?: string;
  ranges: Record<string, Range>;
  local_ranges?: Record<string, Range>;
}

const NO_MASK = "Local ranges need mask_id: Lightroom reports them only while a mask on the photo is selected";

function differs(table: Range | "photo", live: Range | undefined): { differs?: true } {
  if (table === "photo" || live === undefined) return {};
  return Math.abs(table[0] - live[0]) > 1e-9 || Math.abs(table[1] - live[1]) > 1e-9 ? { differs: true } : {};
}

function describeKey(key: DevelopKey, ranges: Record<string, Range>) {
  const kind = { key: key.name, kind: key.kind };
  switch (key.kind) {
    case "number": {
      const live = ranges[key.name];
      return { ...kind, range: key.range, live: live ?? null, ...differs(key.range, live) };
    }
    case "enum":
      return { ...kind, values: key.values, ...(key.labels ? { labels: key.labels } : {}) };
    default:
      return kind;
  }
}

function describeLocal(key: LocalKey, ranges: Record<string, Range>) {
  const live = ranges[key.name];
  return { key: key.name, range: key.range, live: live ?? null, ...differs(key.range, live) };
}

export async function describeDevelopKeys(
  args: DescribeArgs, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions,
): Promise<PluginReply> {
  const keys = DEVELOP_KEYS.filter((key) => key.kind === "number").map((key) => key.name);
  const request = args.mask_id === undefined
    ? { photo_id: args.photo_id, keys }
    : { photo_id: args.photo_id, keys, mask_id: args.mask_id, local_keys: LOCAL_KEYS.map((key) => key.name) };
  const reply = await dispatcher.call("read_develop_ranges", request, budgetMs, options) as PluginReply;
  if (reply.error !== undefined || reply.result?.data === undefined) return reply;
  const live = reply.result?.data as LiveRanges;
  const data = {
    photo_id: live.photo_id,
    lightroom: live.lightroom,
    process_version: live.process_version,
    keys: DEVELOP_KEYS.map((key) => describeKey(key, live.ranges)),
    local: LOCAL_KEYS.map((key) => describeLocal(key, live.local_ranges ?? {})),
  };
  const warnings = [...(reply.result?.warnings ?? []), ...(args.mask_id === undefined ? [NO_MASK] : [])];
  return { result: { data, ...(warnings.length ? { warnings } : {}) } };
}
