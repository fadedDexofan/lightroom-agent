export type Input = string | number;

export type OnePhoto = readonly [Input];
export type ItemFailure = { photo_id: string; reason: string } | { path: string; reason: string };

export interface ReplyParts {
  data?: unknown;
  failed?: ItemFailure[];
  unknown?: ItemFailure[];
  not_found?: Input[];
  remaining?: Input[];
  written?: string[];
  problem?: string;
  warnings?: string[];
}

export interface PluginReply {
  result?: ReplyParts;
  error?: string;
  effect?: "none" | "unknown";
}

type Lists = Pick<ReplyParts, "failed" | "unknown" | "not_found" | "remaining">;

export type ToolResult =
  | { outcome: "done"; data: unknown; warnings?: string[] }
  | ({ outcome: "partial"; data: unknown; error: string; warnings?: string[] } & Lists)
  | ({ outcome: "failed"; error: string; warnings?: string[] } & Lists)
  | ({ outcome: "unknown"; data?: unknown; error: string; warnings?: string[] } & Lists);

const LIST_KEYS = ["failed", "unknown", "not_found", "remaining"] as const;

function lists(parts: ReplyParts): Lists {
  return Object.fromEntries(LIST_KEYS.flatMap((key) => (parts[key]?.length ? [[key, parts[key]]] : []))) as Lists;
}

function summary(present: Lists, parts: ReplyParts): string {
  const counts = [
    present.failed && `${present.failed.length} failed`,
    present.unknown && `${present.unknown.length} with an unknown outcome (read their state before retrying)`,
    present.not_found && `${present.not_found.length} not found`,
    present.remaining && `${present.remaining.length} still to process (resend remaining)`,
  ].filter(Boolean);
  const written = parts.written?.length ? `written before this stopped: ${parts.written.join(", ")}` : undefined;
  return [counts.join(", "), parts.problem, written].filter(Boolean).join("; ");
}

function warningsOf(parts: ReplyParts): { warnings?: string[] } {
  return parts.warnings?.length ? { warnings: parts.warnings } : {};
}

export function finishReply(readOnly: boolean, reply: PluginReply): ToolResult {
  if (reply.error !== undefined) {
    return { outcome: readOnly || reply.effect === "none" ? "failed" : "unknown", error: reply.error };
  }
  const parts = reply.result ?? {};
  const present = lists(parts);
  const error = summary(present, parts);
  const hasData = parts.data !== undefined;
  if (present.unknown || parts.written?.length) {
    return { outcome: "unknown", ...(hasData ? { data: parts.data } : {}), error, ...present, ...warningsOf(parts) };
  }
  if (!hasData && error) return { outcome: "failed", error, ...present, ...warningsOf(parts) };
  if (error) return { outcome: "partial", data: parts.data, error, ...present, ...warningsOf(parts) };
  return { outcome: "done", data: parts.data, ...warningsOf(parts) };
}

export function finishLost(readOnly: boolean, message: string, sent: boolean): ToolResult {
  return { outcome: readOnly || !sent ? "failed" : "unknown", error: message };
}

interface TextBlock {
  type: "text";
  text: string;
}

interface ImageBlock {
  type: "image";
  data: string;
  mimeType: string;
}

export interface ToolResponse {
  content: [TextBlock, ...(TextBlock | ImageBlock)[]];
  isError?: boolean;
  [key: string]: unknown;
}

interface ImagePayload {
  image: { data: string; mime_type: string };
  [key: string]: unknown;
}

function isImagePayload(value: unknown): value is ImagePayload {
  if (typeof value !== "object" || value === null || !("image" in value)) return false;
  const { image } = value;
  return (
    typeof image === "object" &&
    image !== null &&
    "data" in image &&
    typeof image.data === "string" &&
    "mime_type" in image &&
    typeof image.mime_type === "string"
  );
}

function withoutImages(data: unknown, images: ImageBlock[]): unknown {
  if (isImagePayload(data)) {
    const { image, ...rest } = data;
    images.push({ type: "image", data: image.data, mimeType: image.mime_type });
    return rest;
  }
  if (typeof data !== "object" || data === null || Array.isArray(data)) return data;
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => [
      key,
      !Array.isArray(value)
        ? value
        : value.map((item: unknown) => {
            if (!isImagePayload(item)) return item;
            const { image, ...rest } = item;
            images.push({ type: "image", data: image.data, mimeType: image.mime_type });
            return { ...rest, image_index: images.length };
          }),
    ]),
  );
}

export function toolResponse(result: ToolResult): ToolResponse {
  const images: ImageBlock[] = [];
  const shown =
    "data" in result && result.data !== undefined ? { ...result, data: withoutImages(result.data, images) } : result;
  return {
    content: [{ type: "text", text: JSON.stringify(shown) }, ...images],
    ...(result.outcome === "done" ? {} : { isError: true }),
  };
}

export function refusedResponse(message: string): ToolResponse {
  return toolResponse({ outcome: "failed", error: message });
}

export function unknownToolResponse(name: string): ToolResponse {
  return refusedResponse(`Unknown tool "${name}". Only listed tools can be called.`);
}
