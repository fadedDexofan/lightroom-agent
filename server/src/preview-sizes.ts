import type { JSONObject } from "@modelcontextprotocol/server";

export const PREVIEW_SIZES = { cull: 864, review: 1728 } as const;

export type PreviewSize = number | keyof typeof PREVIEW_SIZES;

export function previewEdge(size: PreviewSize): number {
  return Math.floor(typeof size === "string" ? PREVIEW_SIZES[size] : size);
}

export function previewSizeSchema(description: string): JSONObject {
  return {
    description,
    oneOf: [
      { type: "number", minimum: 64, maximum: 2048 },
      { type: "string", enum: Object.keys(PREVIEW_SIZES) },
    ],
  };
}
