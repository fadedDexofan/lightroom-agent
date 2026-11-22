import type { JSONObject, Tool } from "@modelcontextprotocol/server";
import type { Toolset } from "./toolsets.js";
import type { CallOptions, Dispatcher } from "./dispatcher.js";
import { findDuplicateGroups } from "./duplicate-groups.js";
import { getPhotoStats } from "./photo-stats.js";
import { DEFAULT_DETAIL_EDGE, getPhotoDetail, MAX_DETAIL_EDGE } from "./photo-detail.js";
import { DEVELOP_KEYS, DEVELOP_RULES, developKeyNamesSchema, developSettingsSchema, isPointCurve, keysRefusedFor, localAdjustmentsSchema, pointCurveRuleText, pointCurveSchema, writtenElsewhereText } from "./develop-keys.js";
import { setCrop } from "./crop.js";
import { describeDevelopKeys } from "./describe-develop-keys.js";
import { setDevelopSettings, setDevelopSettingsBatch } from "./develop-write.js";
import { getPhotoPreviews, renderPreview } from "./photo-preview.js";
import { RENDITION_JPEG_QUALITY, renderPhoto } from "./photo-render.js";
import { previewStartLimitMs } from "./preview-item.js";
import { MAX_IMAGE_BYTES, previewSizeSchema } from "./preview-sizes.js";
import { TIMEOUT_MS_BY_DURATION } from "./tool-durations.js";
import { getPhotoMetadata } from "./photo-metadata.js";
import type { PluginReply } from "./tool-result.js";
import {
  COLOR_LABEL_NAMES,
  LANDSCAPE_MASK_CATEGORY_NAMES,
  MASK_CURVE_CHANNEL_NAMES,
  MASK_TYPE_NAMES,
  PEOPLE_MASK_PART_NAMES,
  PHOTO_FLAG_NAMES,
  STORED_MASK_DECIMAL_PLACES,
} from "./lightroom-tables.js";

type InputSchema = Tool["inputSchema"];

export type DevelopUse = "drives" | "settings" | "reads";

export interface PluginAction {
  name: string;
  plugin: string;
  develop?: DevelopUse;
}

export interface ToolContract {
  name: string;
  toolset: Toolset;
  title: string;
  annotations: {
    readOnlyHint: boolean;
    destructiveHint?: boolean;
    openWorldHint: false;
  };
  description: string;
  run: { plugin: string } | { server: ServerTool };
  duration?: "long";
  develop?: DevelopUse;
  inputSchema: InputSchema;
  rules?: readonly ArgumentRule[];
  alwaysLoad?: true;
}

export type ToolArgs = Readonly<Record<string, unknown>>;

export interface ArgumentRule {
  text: string;
  holds: (args: ToolArgs) => boolean;
  where?: (args: ToolArgs) => string | undefined;
}

export type ServerTool = (
  args: unknown,
  dispatcher: Pick<Dispatcher, "call">,
  budgetMs: number,
  options?: CallOptions,
) => Promise<PluginReply>;

const serverTool = <A>(
  run: (args: A, dispatcher: Pick<Dispatcher, "call">, budgetMs: number, options?: CallOptions) => Promise<PluginReply>,
): ServerTool => (args, dispatcher, budgetMs, options) => run(args as A, dispatcher, budgetMs, options);

const anyGiven = (...keys: string[]) => (args: ToolArgs) => keys.some((key) => args[key] !== undefined);

const exclusiveWithMaskId: ArgumentRule = {
  text: "adjustments cannot be used with mask_id",
  holds: (args) => args.mask_id === undefined || args.adjustments === undefined,
};

const CURVE_KEYS = DEVELOP_KEYS.filter((key) => key.kind === "curve").map((key) => key.name);
const WRITTEN_ELSEWHERE = writtenElsewhereText(DEVELOP_KEYS.filter((key) => key.writtenBy !== undefined));
const settingsOf = (args: ToolArgs) => (args.settings ?? {}) as Record<string, unknown>;

const developSettingsRules: readonly ArgumentRule[] = [
  {
    text: `settings must leave out the keys another tool writes: ${WRITTEN_ELSEWHERE}`,
    holds: (args) => keysRefusedFor("set_develop_settings", Object.keys(settingsOf(args))).length === 0,
  },
  {
    text: pointCurveRuleText("a ToneCurvePV2012 curve"),
    holds: (args) => CURVE_KEYS.every((key) => settingsOf(args)[key] === undefined || isPointCurve(settingsOf(args)[key])),
  },
];

const eachPhotoRule = (rule: ArgumentRule): ArgumentRule => ({
  text: `in each photo, ${rule.text}`,
  holds: (args) => (args.photos as { settings: unknown }[]).every((photo) => rule.holds(photo as ToolArgs)),
  where: (args) => {
    const index = (args.photos as { settings: unknown }[]).findIndex((photo) => !rule.holds(photo as ToolArgs));
    return index < 0 ? undefined : `photo ${index + 1} (photos[${index}])`;
  },
});

const photosOnceRule: ArgumentRule = {
  text: "each photo_id appears once",
  holds: (args) => {
    const ids = (args.photos as { photo_id: unknown }[]).map((photo) => String(photo.photo_id));
    return new Set(ids).size === ids.length;
  },
};

const copyListRule: ArgumentRule = {
  text: `refused in a named settings list: ${WRITTEN_ELSEWHERE}`,
  holds: (args) => !Array.isArray(args.settings) || keysRefusedFor("copy_develop_settings", args.settings as string[]).length === 0,
};

const isCalendarDate = (value: unknown) => {
  if (typeof value !== "string") return true;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
};

const searchDateRules: readonly ArgumentRule[] = [
  {
    text: "start_date and end_date must be real calendar dates",
    holds: (args) => isCalendarDate(args.start_date) && isCalendarDate(args.end_date),
  },
  {
    text: "start_date must be on or before end_date",
    holds: (args) => typeof args.start_date !== "string" || typeof args.end_date !== "string" || args.start_date <= args.end_date,
  },
];

const presetSelectorRule: ArgumentRule = { text: "give preset_uuid or preset_name", holds: anyGiven("preset_uuid", "preset_name") };

const locationProperties = {
  sublocation: {
    type: "string",
    description: "Sublocation: a venue, landmark or neighbourhood (e.g. 'Sydney Opera House')",
  },
  city: { type: "string", description: "City" },
  state_province: { type: "string", description: "State or province" },
  country: { type: "string", description: "Country name" },
  iso_country_code: {
    type: "string",
    description: "ISO 3166 country code (e.g. 'US', 'AU')",
  },
};

const metadataProperties = {
  title: { type: "string", description: "Title" },
  caption: { type: "string", description: "Caption (IPTC description)" },
  headline: { type: "string", description: "Headline" },
  creator: { type: "string", description: "Creator (photographer)" },
  copyright: { type: "string", description: "Copyright notice, e.g. '© 2026 Jane Doe'" },
  rights_usage_terms: { type: "string", description: "Rights usage terms" },
  copyright_info_url: { type: "string", description: "Copyright info URL, e.g. a licensing page" },
  creator_url: { type: "string", description: "Creator's website (IPTC creator contact info)" },
  alt_text: { type: "string", description: "Short accessibility description" },
  extended_description: { type: "string", description: "Extended accessibility description" },
};

const atLeastOneOf = (properties: Readonly<Record<string, unknown>>): ArgumentRule => {
  const names = Object.keys(properties);
  return { text: `give at least one of ${names.join(", ")}`, holds: anyGiven(...names) };
};

const subtractNeedsMaskId: ArgumentRule = {
  text: 'mode "subtract" needs mask_id: a new mask has nothing to subtract from',
  holds: (args) => args.mode !== "subtract" || args.mask_id !== undefined,
};

const nameOnlyForNewMask: ArgumentRule = {
  text: "name applies to a new mask; omit it when mask_id adds to an existing mask",
  holds: (args) => args.name === undefined || args.mask_id === undefined,
};

type Rectangle = { left: number; top: number; right: number; bottom: number };
const rectangleOf = (args: ToolArgs) => args.rectangle as Rectangle | undefined;

const cropRules: readonly ArgumentRule[] = [
  { text: "give either rectangle or aspect", holds: (args) => (args.rectangle === undefined) !== (args.aspect === undefined) },
  {
    text: "center and scale apply to aspect, not to rectangle",
    holds: (args) => args.rectangle === undefined || (args.center === undefined && args.scale === undefined),
  },
  { text: "rectangle left must be less than right", holds: (args) => { const r = rectangleOf(args); return !r || r.left < r.right; } },
  { text: "rectangle top must be less than bottom", holds: (args) => { const r = rectangleOf(args); return !r || r.top < r.bottom; } },
];

const MAX_BULK_PHOTO_IDS = 1000;
const MAX_METADATA_PHOTO_IDS = 100;
const MAX_DENOISE_PHOTO_IDS = 100;
const MAX_KEYWORDS = 1000;
const MAX_MASK_DELETE_IDS = 100;
const MAX_MASK_BATCH_PHOTO_IDS = 200;

const CREATE_MASK_TYPES = [...MASK_TYPE_NAMES, "people", "landscape"] as const;
const MASK_COMBINE_OPERATIONS = ["add", "subtract", "intersect"] as const;


const normalizedPoint = (description: string) => ({
  type: "object",
  additionalProperties: false,
  properties: {
    x: { type: "number", minimum: 0, maximum: 1, description: "Horizontal position, 0 = left edge, 1 = right edge" },
    y: { type: "number", minimum: 0, maximum: 1, description: "Vertical position, 0 = top edge, 1 = bottom edge" },
  },
  required: ["x", "y"],
  description,
});

const gradientGeometryProperties = {
  start: normalizedPoint("Linear only: where the effect is full strength"),
  end: normalizedPoint("Linear only: where the effect has faded to nothing"),
  center: normalizedPoint("Radial only: center of the ellipse"),
  width: {
    type: "number",
    exclusiveMinimum: 0,
    maximum: 2,
    description: "Radial only: ellipse width as a fraction of the preview width (not pixels), measured before rotation",
  },
  height: {
    type: "number",
    exclusiveMinimum: 0,
    maximum: 2,
    description: "Radial only: ellipse height as a fraction of the preview height (not pixels), measured before rotation",
  },
  rotation: {
    type: "number",
    minimum: -360,
    maximum: 360,
    description:
      "Radial only: clockwise rotation in degrees around the center, in the photo's pixel space (default 0). Lightroom keeps a turn past 45 degrees as the same ellipse with width and height swapped and the rotation turned back by 90 degrees, so results report that form",
  },
  feather: {
    type: "number",
    minimum: 0,
    maximum: 100,
    description: "Radial only: edge softness, 0 hard to 100 soft (default 50)",
  },
  area: {
    type: "string",
    enum: ["inside", "outside"],
    description: "Radial only: apply the effect inside (default) or outside the ellipse",
  },
} satisfies JSONObject;

const LINEAR_GRADIENT_FIELDS = ["start", "end"];
const RADIAL_GRADIENT_FIELDS = ["center", "width", "height", "rotation", "feather", "area"];

const gradientFieldsOfItsShape: ArgumentRule = {
  text: 'start and end apply only to shape "linear"; center, width, height, rotation, feather and area only to shape "radial"',
  holds: (args) => !anyGiven(...(args.shape === "linear" ? RADIAL_GRADIENT_FIELDS : LINEAR_GRADIENT_FIELDS))(args),
};

const linearNeedsEnds: ArgumentRule = {
  text: 'shape "linear" needs start and end',
  holds: (args) => args.shape !== "linear" || (args.start !== undefined && args.end !== undefined),
};

const radialNeedsEllipse: ArgumentRule = {
  text: 'shape "radial" needs center, width and height',
  holds: (args) => args.shape !== "radial" || (args.center !== undefined && args.width !== undefined && args.height !== undefined),
};

const RANGE_TYPES = ["luminance", "color", "depth"];

const rangeValuesOfItsType: ArgumentRule = {
  text: "luminance, color and depth each apply only to the type of the same name",
  holds: (args) => !anyGiven(...RANGE_TYPES.filter((type) => type !== args.type))(args),
};

const rangeNeedsItsValues: ArgumentRule = {
  text: 'type "luminance" needs luminance, type "depth" needs depth, and type "color" needs color.sample or copy_sample_from',
  holds: (args) => args.type === "color"
    ? (args.color as { sample?: unknown } | undefined)?.sample !== undefined || args.copy_sample_from !== undefined
    : args[args.type as string] !== undefined,
};

const copyOnlyForColor: ArgumentRule = {
  text: 'copy_sample_from applies only to type "color"',
  holds: (args) => args.copy_sample_from === undefined || args.type === "color",
};

const sampleOrCopy: ArgumentRule = {
  text: "color.sample and copy_sample_from both give the sample; give one of them",
  holds: (args) => args.copy_sample_from === undefined || (args.color as { sample?: unknown } | undefined)?.sample === undefined,
};

const MIN_RANGE_BAND_WIDTH = 0.01;
const storedUnits = (value: number) => Math.round(value * 10 ** STORED_MASK_DECIMAL_PLACES);

const rangeBandWideEnough = (type: string): ArgumentRule => ({
  text: `${type}.max must be at least ${MIN_RANGE_BAND_WIDTH} above ${type}.min: Lightroom replaces a narrower band with its default`,
  holds: (args) => {
    const band = args.type === type ? args[type] as { min: number; max: number } | undefined : undefined;
    return !band || storedUnits(band.max) - storedUnits(band.min) >= storedUnits(MIN_RANGE_BAND_WIDTH);
  },
});

const depthNarrowerThanScene: ArgumentRule = {
  text: "depth min 0 with max 1 covers the whole scene, which Lightroom stores as its default depth range and the tool cannot tell from a photo without a depth map; narrow the range",
  holds: (args) => {
    const band = args.type === "depth" ? args.depth as { min: number; max: number } | undefined : undefined;
    return !band || !(band.min === 0 && band.max === 1);
  },
};

const brushStrokeProperties = {
  strokes: {
    type: "array",
    minItems: 1,
    maxItems: 50,
    description:
      "Strokes to paint, in order. Each stroke is a path of points; Lightroom fills dabs along the path. A stroke adds paint unless it sets erase, which removes the paint earlier strokes of the same brush left under it",
    items: {
      type: "object",
      additionalProperties: false,
      properties: {
        points: {
          type: "array",
          minItems: 1,
          maxItems: 1000,
          items: normalizedPoint("A point on the stroke path"),
          description: "Path of the stroke, at least one point; a single point is one dab",
        },
        radius: {
          type: "number",
          exclusiveMinimum: 0,
          maximum: 1,
          description: "Brush size as a fraction of the longer edge of the preview (default 0.14, Lightroom's default brush; 0.04 is clearly narrower). It is the radius of the brush at feather 100: a lower feather keeps the brush size and the tool stores the smaller radius Lightroom stores for it",
        },
        feather: {
          type: "number",
          minimum: 0,
          maximum: 100,
          description: "Edge softness like Lightroom's Feather slider: 0 is a hard edge, 100 the default soft brush. Intermediate values interpolate between brushes authored in Lightroom (accurate within a fraction of a percent)",
        },
        density: {
          type: "number",
          minimum: 0.01,
          maximum: 1,
          description: "Density, 0.01 to 1 (default 1): the most opacity the stroke can reach however often it is stamped",
        },
        erase: {
          type: "boolean",
          description: "Erase instead of add (default false): the stroke removes the paint that earlier strokes of the same brush left under it. It is stored as a stroke with density 0, so it cannot erase a different brush or mask, and a stroke over unpainted area changes nothing",
        },
        flow: {
          type: "number",
          minimum: 0.01,
          maximum: 1,
          description: "Flow, 0.01 to 1 (default 1); each stroke can carry its own",
        },
      },
      required: ["points"],
    },
  },
} satisfies JSONObject;




const eraseHasNoDensity: ArgumentRule = {
  text: "density does not apply to an erase stroke: erasing removes the paint it covers",
  holds: (args) => !(args.strokes as { erase?: boolean; density?: number }[]).some((stroke) => stroke.erase === true && stroke.density !== undefined),
};

const maskIdSchema = (description: string) => ({
  type: "string",
  minLength: 1,
  description,
});

const maskCurveProperties = Object.fromEntries(
  MASK_CURVE_CHANNEL_NAMES.map((channel) => [
    channel,
    pointCurveSchema(channel === "main" ? "the RGB (luminance) curve" : `the ${channel} channel curve`),
  ]),
);

const maskCurveRule: ArgumentRule = {
  text: pointCurveRuleText("each curve"),
  holds: (args) => Object.values((args.curves ?? {}) as Record<string, unknown>).every(isPointCurve),
};

const swatchNumber = (description: string, minimum: number, maximum: number) => ({
  type: "number",
  minimum,
  maximum,
  description,
});

const swatchRange = (description: string) => ({
  type: "object",
  additionalProperties: false,
  properties: {
    LowerNone: swatchNumber("Outer left limit", 0, 1),
    LowerFull: swatchNumber("Inner left limit", 0, 1),
    UpperFull: swatchNumber("Inner right limit", 0, 1),
    UpperNone: swatchNumber("Outer right limit", 0, 1),
  },
  required: ["LowerNone", "LowerFull", "UpperFull", "UpperNone"],
  description,
});

const SWATCH_RANGES = ["HueRange", "SatRange", "LumRange"] as const;
const SWATCH_RANGE_EDGES = ["LowerNone", "LowerFull", "UpperFull", "UpperNone"] as const;

const swatchRangesOrderedRule: ArgumentRule = {
  text: `each swatch range orders ${SWATCH_RANGE_EDGES.join(" <= ")} (Lightroom drops every swatch of the mask otherwise)`,
  holds: (args) => {
    const swatch = (args.swatch ?? {}) as Record<string, Record<string, number> | undefined>;
    return SWATCH_RANGES.every((name) => {
      const range = swatch[name];
      return range === undefined
        || SWATCH_RANGE_EDGES.every((edge, position) => position === 0 || range[SWATCH_RANGE_EDGES[position - 1]] <= range[edge]);
    });
  },
};

const pointColorSwatchProperties = {
  SrcHue: swatchNumber("Source color hue, 0 to 6", 0, 6),
  SrcSat: swatchNumber("Source color saturation, 0 to 1", 0, 1),
  SrcLum: swatchNumber("Source color luminance, 0 to 1", 0, 1),
  HueShift: swatchNumber("Hue shift, -1 to 1 (default 0)", -1, 1),
  SatScale: swatchNumber("Saturation shift, -1 to 1 (default 0)", -1, 1),
  LumScale: swatchNumber("Luminance shift, -1 to 1 (default 0)", -1, 1),
  RangeAmount: swatchNumber("Range amount, 0 to 1 (default 0.5)", 0, 1),
  Variance: swatchNumber("Variance, -1 to 1 (default 0)", -1, 1),
  HueRange: swatchRange("Hue range limits, each 0 to 1"),
  SatRange: swatchRange("Saturation range limits, each 0 to 1"),
  LumRange: swatchRange("Luminance range limits, each 0 to 1"),
};

const stringArray = (description: string, maxItems?: number) => ({
  type: "array",
  items: { type: "string" },
  minItems: 1,
  ...(maxItems ? { maxItems } : {}),
  description,
});

export const PHOTO_ID_PATTERN = "^(?:[1-9][0-9]*$|/|[A-Za-z]:[\\\\/]|\\\\\\\\)";

const PHOTO_ID = { type: ["integer", "string"], minimum: 1, pattern: PHOTO_ID_PATTERN };

const photoIdSchema = (description: string): JSONObject => ({ ...PHOTO_ID, description });

const photoIdArray = (description: string): JSONObject => ({
  type: "array",
  items: PHOTO_ID,
  minItems: 1,
  maxItems: MAX_BULK_PHOTO_IDS,
  description,
});

const dateStringSchema = (description: string) => ({
  type: "string",
  pattern: "^\\d{4}-\\d{2}-\\d{2}$",
  description,
});

const collectionNameSchema = {
  type: "string",
  minLength: 1,
  description:
    "Collection path from list_collections, or a bare name. A listed path always picks that collection; a bare name of a nested collection must be unique.",
};

const developSettingsProperty = developSettingsSchema();

const developSettingKeyItems = developKeyNamesSchema();

const presetSelectorProperties = {
  preset_name: { type: "string", minLength: 1, description: "Develop preset name" },
  preset_uuid: { type: "string", minLength: 1, description: "Develop preset UUID (preferred)" },
  preset_folder: { type: "string", minLength: 1, description: "Preset folder for disambiguation" },
  preset_scope: {
    type: "string",
    enum: ["lightroom", "plugin"],
    description: "Lightroom-visible preset or plugin-managed checkpoint",
  },
};

const presetSelectorSchema: InputSchema = {
  type: "object",
  additionalProperties: false,
  properties: presetSelectorProperties,
};

const nestedPresetSelectorSchema = {
  ...presetSelectorSchema,
  anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
};

const PHOTO_ROW_FIELDS =
  "Include each photo file path (default false). Rows always include photo_id, filename, rating (0 = unrated), flag, color_label and date_time_original, and stack (position, is_collapsed, top_photo_id) for a stacked photo.";

const searchFilterProperties = {
  filename: { type: "string", description: "Search by filename (partial match)" },
  keywords: stringArray("Search by keywords"),
  rating: {
    type: "integer",
    description: "Filter by star rating (0-5)",
    minimum: 0,
    maximum: 5,
  },
  start_date: dateStringSchema("Start date (YYYY-MM-DD)"),
  end_date: dateStringSchema("End date (YYYY-MM-DD)"),
  camera: { type: "string", pattern: "\\S", description: "Exact camera name indexed by Lightroom" },
  lens: { type: "string", pattern: "\\S", description: "Exact lens name indexed by Lightroom" },
  iso: { type: "number", exclusiveMinimum: 0, maximum: Number.MAX_VALUE, description: "Exact ISO speed rating" },
  focal_length: { type: "number", exclusiveMinimum: 0, maximum: Number.MAX_VALUE, description: "Exact focal length in millimeters (not the 35mm equivalent)" },
  flag: { type: "string", enum: [...PHOTO_FLAG_NAMES], description: "Filter by pick flag" },
  color_label: { type: "string", enum: [...COLOR_LABEL_NAMES], description: "Filter by Library color label" },
  edited: { type: "boolean", description: "Whether the photo has develop adjustments" },
  file_type: { type: "string", enum: ["DNG", "RAW", "JPG", "TIFF", "PNG", "PSD", "VIDEO", "PSB", "AVIF", "JXL"], description: "Lightroom file format; camera raw formats use RAW" },
  folder: { type: "string", pattern: "\\S", description: "Folder text, including parent folders shown in Lightroom's Folders panel (contains all words)" },
};

const NORMALIZED_REGION_PROPERTIES = {
  x: { type: "number", minimum: 0, exclusiveMaximum: 1 },
  y: { type: "number", minimum: 0, exclusiveMaximum: 1 },
  width: { type: "number", exclusiveMinimum: 0, maximum: 1 },
  height: { type: "number", exclusiveMinimum: 0, maximum: 1 },
};

const fitsFrame = (region: { x: number; y: number; width: number; height: number }) =>
  region.x + region.width <= 1 && region.y + region.height <= 1;

export const PLUGIN_ACTIONS: readonly PluginAction[] = [
  { name: "read_photo_metadata", plugin: "HandlerMetadata.getPhotoMetadata" },
  { name: "read_lens_profiles", plugin: "HandlerLensProfile.read", develop: "reads" },
  { name: "render_preview", plugin: "HandlerPreview.renderPreview" },
  { name: "render_duplicate_preview", plugin: "HandlerPreview.renderDuplicatePreview" },
  { name: "render_source", plugin: "HandlerExport.renderSource" },
  { name: "read_settings_by_input", plugin: "HandlerRawDevelopSettings.byInput", develop: "reads" },
  { name: "write_develop_settings", plugin: "HandlerDevelop.setDevelopSettings", develop: "settings" },
  { name: "write_develop_settings_batch", plugin: "HandlerDevelop.setDevelopSettingsBatch", develop: "settings" },
  { name: "plan_crop", plugin: "HandlerCrop.plan", develop: "reads" },
  { name: "read_develop_ranges", plugin: "HandlerDevelopKeys.ranges", develop: "drives" },
];

export const DEFAULT_PAGE_LIMIT = 100;
export const STYLE_SUMMARY_MIN_RATING = 4;
export const STYLE_SUMMARY_PHOTO_LIMIT = 200;
export const CATALOG_WRITE_WAIT_SECONDS = 10;
export const AI_MASK_COMPUTE_WAIT_SECONDS = 15;
export const AUTO_CHANGE_WAIT_SECONDS = 8;
export const RESET_LANDING_WAIT_SECONDS = 4;
export const NEW_MASK_SAVE_WAIT_SECONDS = 8;
const DEVELOP_READ_BACK = "After the write the tool waits for Lightroom to normalise it (about a second) and reads the written table keys back: a value stored differently is listed in adjusted ({photo_id, key, requested, stored}) and makes the outcome partial; a key the photo held before and Lightroom no longer shows makes the photo unknown; a key the photo stores neither before nor after the write (a raw's Temperature and Tint on a JPEG) is listed in not_stored ({photo_id, keys}) with a warning and does not change the outcome.";
const AI_COMPUTE_CHANGED_MORE = "unless Update AI Settings also changed other settings of the photo (it can refresh stale Lens Blur depth, Enhance filters, Remove areas or an adaptive profile, which are not rolled back): then it is unknown and names them";
const ABSOLUTE_PATH_RULE = "~/ is expanded; only the platform's separator between names (/ on macOS, \\ on Windows); no ., .. or empty names";

const pagingProperties = (items: string) => ({
  limit: { type: "integer", minimum: 0, description: `Max ${items} to return (default ${DEFAULT_PAGE_LIMIT})` },
  offset: { type: "integer", minimum: 0, description: `Number of ${items} to skip (default 0)` },
});

const NO_THUMBNAIL_IN_DEVELOP = "The photo open in Develop gets no thumbnail, since Lightroom's thumbnail there can be stale or an enlarged low-resolution copy: it fails at once, naming render_photo.";
const PREVIEW_CACHE_ENLARGES = "Lightroom's preview cache can answer with an enlargement of a smaller cached preview, most often on a cropped photo, without saying so; judge fine sharpness with get_photo_detail.";
const PREVIEW_START_LIMIT = `${previewStartLimitMs(TIMEOUT_MS_BY_DURATION.quick) / 1000} s`;

export const TOOL_CONTRACTS: ToolContract[] = [
  {
    name: "search_photos",
    toolset: "core",
    alwaysLoad: true,
    title: "Search photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerSearch.searchPhotos" },
    rules: searchDateRules,
    description:
      "Search photos using intersecting Library filters (paginated): filename, keywords, rating, capture date, camera, lens, ISO, focal length, flag, color label, edited status, file type and folder. Provide at least one filter to improve performance on large catalogs. The hidden photos of a collapsed stack are not searched; a warning names the stack tops on the page.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: PHOTO_ROW_FIELDS },
        ...searchFilterProperties,
        ...pagingProperties("photos"),
      },
    },
  },
  {
    name: "get_selected_photos",
    toolset: "core",
    title: "Get selected photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerSelection.getSelectedPhotos" },
    description: "Get currently selected photos in Lightroom (or filmstrip if no selection). Paginated.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: PHOTO_ROW_FIELDS },
        ...pagingProperties("photos"),
      },
    },
  },
  {
    name: "summarize_develop_settings",
    toolset: "develop",
    title: "Summarize develop settings",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerStyleSummary.summarize" },
    description:
      `Summarize numeric Develop settings by camera model and ISO (1-400, 401-1600, 1601-6400, 6401+, unknown). Select rating >= min_rating (default ${STYLE_SUMMARY_MIN_RATING}; 0=all); exported_only requires raw isExported true. Reads at most max_photos settings (default/max ${STYLE_SUMMARY_PHOTO_LIMIT}); export filtering batches flags for all rating matches. Returns count and SDK-key median/min/max per group, scanned/matched/truncated. Excludes crop, perspective, Temperature/Tint, nonfinite/nonnumeric/all-zero settings. Alphabetical keys fill 6000 characters/group; settings_omitted counts size exclusions. Read-only.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        min_rating: { type: "integer", minimum: 0, maximum: 5, default: STYLE_SUMMARY_MIN_RATING, description: "Minimum star rating, inclusive" },
        exported_only: { type: "boolean", default: false, description: "Require an exported photo as well as the minimum rating; a get_photo_detail call marks its photo exported too" },
        max_photos: { type: "integer", minimum: 1, maximum: STYLE_SUMMARY_PHOTO_LIMIT, default: STYLE_SUMMARY_PHOTO_LIMIT, description: "Maximum photos whose Develop settings are read" },
      },
    },
  },
  {
    name: "get_photo_metadata",
    toolset: "core",
    title: "Get photo metadata",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { server: serverTool(getPhotoMetadata) },
    description:
      "Read 1-100 photos, field names in snake_case: rating (0 = unrated), flag and color_label in the set_rating_and_flag/set_color_label values, keywords/nested keyword_paths, EXIF, title/caption/headline, GPS latitude/longitude/altitude, IPTC sublocation/city/state_province/country/iso_country_code, copyright and accessibility alt_text/extended_description (omitted when empty); develop settings are read with get_develop_settings. photo_id and related ids are catalog-local strings. is_virtual_copy marks copies; optional virtual_copy holds master_photo_id and copy_name, or a master's copy_photo_ids. Optional folder stack holds position (top=1), is_collapsed, top_photo_id and ordered member_photo_ids.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          ...photoIdArray("1 to 100 photo IDs or file paths; returns photos in request order; unknown identifiers are not_found. Repeated identifiers produce repeated entries."),
          maxItems: MAX_METADATA_PHOTO_IDS,
        },
        lens_profile: {
          type: "boolean",
          description: "Add lens_profile to each found photo: the lens profile in its saved develop settings, as Lightroom stores it: enabled (a boolean here; get_develop_settings returns the stored LensProfileEnable 0/1), setup (LensDefaults, Auto or Custom), name, filename, embedded, distortion_scale and vignetting_scale (0-200, 100 is the profile's own amount); a key the photo does not carry is left out; a photo with none of them gets {}. A photo whose group could not be read (the read failed, the photo left the catalog meanwhile, or the call got no Develop turn) keeps its metadata and is listed in failed, so the outcome is partial. Reading develop settings waits for the Develop calls before it, as every read of a photo's develop state does; without lens_profile this tool does not wait.",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "get_photo_preview",
    toolset: "core",
    alwaysLoad: true,
    title: "Get photo preview",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { server: serverTool(renderPreview) },
    description:
      `Lightroom-rendered JPEG with Develop edits (raw supported). region crops the rendered frame after develop crop/rotation: normalized x/y/width/height, origin top-left, x right, y down. width/height/bytes are actual; requested_size is the edge asked of Lightroom; scaled_by_server is true when the server scaled Lightroom's larger image down. Lightroom sometimes answers that it has no preview pixels for a photo, typically right after a change; the call asks again for about ${previewStartLimitMs(TIMEOUT_MS_BY_DURATION.quick) / 1000} s and, if it still has none, fails with that reason: ask again later. ${NO_THUMBNAIL_IN_DEVELOP} ${PREVIEW_CACHE_ENLARGES} See size for cost/edge rules.`,
    rules: [{
      text: "region must fit within the rendered frame (x + width and y + height at most 1)",
      holds: (args) => {
        const region = args.region as { x: number; y: number; width: number; height: number } | undefined;
        return !region || fitsFrame(region);
      },
    }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        size: previewSizeSchema("Longest edge returned: cull is 864, review 1728, sizes Lightroom 16.0 renders itself for 3:2 raws, so they usually arrive without resampling; numeric 64-2048 means exactly that edge; default cull, the frequent call. The server scales a larger Lightroom image down to this edge, at most 2000px, within 3.5 MiB; a smaller image is returned as Lightroom made it. cull is for choosing among frames, review for a whole-frame look at rendering, tone and mask edges. Image tokens grow with pixel area (Claude: about width x height / 750) and repeat each turn in history."),
        region: {
          type: "object",
          additionalProperties: false,
          description: "Rectangle within the rendered preview, including its develop crop and displayed orientation. Pixel bounds round outward. Region calls request a larger source by dividing size by the longest normalized side, capped at 2048; requested_size reports that source request. A source over 2000px is scaled to 2000px before the crop; otherwise its pixels are cut as Lightroom rendered them.",
          properties: NORMALIZED_REGION_PROPERTIES,
          required: ["x", "y", "width", "height"],
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_photo_detail",
    toolset: "core",
    title: "Get photo detail",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    duration: "long",
    run: { server: serverTool(getPhotoDetail) },
    description:
      "Cut 1-4 regions from a full-resolution render of a photo with its current Develop settings, one rendered pixel per returned pixel, to judge sharpness of a detail such as the nearest eye. The render is a temporary export (JPEG quality 100, sRGB, output sharpening off, no catalog add), deleted before the call returns (one left by a timed-out or cancelled call, by a later detail call); it takes seconds, and a render that starts while another export or detail render runs is refused, not queued. Its first step reads the cropped frame and waits for the Develop calls before it, as every read of a photo's develop state does; the render runs alongside them. Each call adds one Export history step to the photo and marks it exported, so summarize_develop_settings' exported_only counts it; Develop settings and pixels stay unchanged unless Lightroom's AI Updates Recommended dialog is answered with \"Update affected photos\" checked, which first updates the AI masks, and no cached preview, selection or module changes. Returns photo_id, crop_jpeg_quality (95), per region its pixel box in the render and the image (JPEG 95), plus render {width, height, jpeg_quality, color_space, output_sharpening, source, left_on_photo}: source says how the render was made, a string (\"export\" today); left_on_photo says what the render left on the photo, a list of phrases (\"one Export history step\", \"the exported mark\"). A region larger than max_edge, measured against the cropped frame get_crop reports, is refused before the render with the largest normalized size this photo allows; nothing is scaled. A call refused before the render (unknown photo, the cropped frame not read, region over max_edge, export running) is failed with nothing left; an error once the render started is unknown and names the export and what it leaves on the photo.",
    rules: [{
      text: "every region must fit within the rendered frame (x + width and y + height at most 1)",
      holds: (args) => (args.regions as { x: number; y: number; width: number; height: number }[]).every(fitsFrame),
    }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        regions: {
          type: "array",
          minItems: 1,
          maxItems: 4,
          description: "Rectangles in the displayed frame after develop crop and rotation, normalized like get_photo_preview's region; pixel bounds round outward",
          items: { type: "object", additionalProperties: false, properties: NORMALIZED_REGION_PROPERTIES, required: ["x", "y", "width", "height"] },
        },
        max_edge: {
          type: "integer",
          minimum: 64,
          maximum: MAX_DETAIL_EDGE,
          description: `Largest region edge in pixels (default ${DEFAULT_DETAIL_EDGE}). Keep it within what your model receives without downscaling; the server cannot know that limit.`,
        },
      },
      required: ["photo_id", "regions"],
    },
  },
  {
    name: "render_photo",
    toolset: "core",
    title: "Render photo",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    run: { server: serverTool(renderPhoto) },
    description:
      `Render one photo's whole frame, after crop and rotation, with its current Develop settings by a temporary export (JPEG quality ${RENDITION_JPEG_QUALITY}, sRGB, output sharpening off, no catalog add) at the requested long edge, never enlarged; any photo, the one open in Develop included, whose thumbnail the preview tools refuse. Returns photo_id, width, height, bytes, jpeg_quality, left_on_photo and the image, which is Lightroom's JPEG unchanged: a rendition over ${MAX_IMAGE_BYTES / 1024 / 1024} MiB is not re-encoded but answered unknown, so ask for a smaller size. Each call adds one Export history step to the photo and marks it exported (left_on_photo: "one Export history step", "the exported mark"); Develop settings and pixels stay unchanged unless the AI Updates dialog updates the masks (below). Call it once per edit, not on every check. Like other writes it first commits a slider change pending in Develop, then renders the saved settings the export reads: a slider still moving or an AI update still pending may be missing. It runs alongside Develop calls. While this plug-in's export_photos, get_photo_detail or another render_photo runs, it is refused, not queued, with nothing written; an export started from Lightroom's own menu does not take that lock, and the lock lapses 300 s after the running export last started a photo, though a still-open export session or dialog can make the next rendition wait or time out. A photo with outdated AI masks opens Lightroom's AI Updates Recommended dialog, which blocks the call until dismissed: Export with "Update affected photos" unchecked renders the existing AI computation; checked, it first updates the AI masks, which can visibly change the photo; Cancel stops before rendering, so no Export step is created, but the call is unknown and names the possible trace; a timeout while the dialog is open is unknown. A call refused before the render (unknown photo, export running) is failed with nothing left; an error once the render started is unknown and names the export and what it leaves on the photo.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        size: previewSizeSchema("Long edge of the rendition: cull is 864, review 1728, the default; numeric 64-2048 means that edge. A photo whose cropped frame is smaller is rendered at its own size. Image tokens grow with pixel area (Claude: about width x height / 750) and repeat each turn in history."),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_photo_previews",
    toolset: "core",
    title: "Get batch photo previews",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { server: serverTool(getPhotoPreviews) },
    description:
      `Get JPEG thumbnails for 1–20 photos in input order for culling. Each preview names its photo_id and 1-based image_index, with width, height, bytes and scaled_by_server as in get_photo_preview; a photo that cannot be rendered is failed, the others still arrive; a photo Lightroom answers it has no preview pixels for is asked again within the time, which can leave the photos after it remaining. Total budget 8 MiB. Photos not reached by ${PREVIEW_START_LIMIT} or beyond the budget are remaining; resend them. ${NO_THUMBNAIL_IN_DEVELOP} ${PREVIEW_CACHE_ENLARGES} Catalog unchanged.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          type: "array", items: photoIdSchema("Photo ID or file path"), minItems: 1, maxItems: 20,
          description: "Between 1 and 20 IDs or paths, in image order",
        },
        size: previewSizeSchema("Longest edge returned: cull (864) or review (1728) as in get_photo_preview, or a number 64-2048; default 256. A larger Lightroom image is scaled down to it, at most 2000px"),
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "find_duplicate_groups",
    toolset: "core",
    title: "Find duplicate groups",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { server: serverTool(findDuplicateGroups) },
    description:
      `Group near-duplicates/bursts from up to 100 IDs/paths using 64-bit dHash of current JPEG previews (minimum edge 64) and raw capture time. Every pair must meet inclusive time_window_seconds (default 5) and max_hamming_distance (default 10). Input-order groups omit singletons and repeated photos. Similarity does not rank frames. photos gives raw capture_time in Lightroom seconds (second precision, no timezone normalization). No hash cache or catalog changes. At ${PREVIEW_START_LIMIT} returns the groups so far and the unreached inputs as remaining; preview and missing-time failures are failed with reasons. ${NO_THUMBNAIL_IN_DEVELOP} Resend remaining together with the originals to grow groups.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { type: "array", items: photoIdSchema("Photo ID or file path"), minItems: 1, maxItems: 100, description: "Between 1 and 100 IDs or paths" },
        time_window_seconds: { type: "number", minimum: 0, maximum: 86400, description: "Maximum capture gap in seconds (default 5)" },
        max_hamming_distance: { type: "integer", minimum: 0, maximum: 64, description: "Maximum differing dHash bits (default 10)" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "get_photo_stats",
    toolset: "core",
    title: "Get photo statistics",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { server: serverTool(getPhotoStats) },
    description:
      `Measure current rendered JPEG previews for up to 20 photos; results by photo_id, failures as failed, photos not started within ${PREVIEW_START_LIMIT} as remaining. histogram: 64 normalized Rec.709 luma bins (0-255, four levels/bin); mean_luminance same scale; shadow_fraction <=1, highlight_fraction >=254. sharpness: four-neighbor Laplacian variance after area resampling to 512px long edge (enlarges small previews); higher=sharper. These measure JPEG previews, not raw clipping/full-resolution focus. ${NO_THUMBNAIL_IN_DEVELOP} Catalog unchanged.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          type: "array",
          items: photoIdSchema("Photo ID or file path"),
          minItems: 1,
          maxItems: 20,
          description: "Between 1 and 20 photo IDs or file paths, in result order",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_gps",
    toolset: "core",
    title: "Set GPS",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerMetadata.setGps" },
    rules: [{
      text: "altitude cannot be combined with clear_altitude",
      holds: (args) => args.altitude === undefined || args.clear_altitude !== true,
    }],
    description:
      "Replace GPS coordinates in decimal degrees. Altitude stays unless altitude or clear_altitude is given. Returns updated (photos written); unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        latitude: {
          type: "number",
          minimum: -90,
          maximum: 90,
          description: "Latitude in decimal degrees (north positive)",
        },
        longitude: {
          type: "number",
          minimum: -180,
          maximum: 180,
          description: "Longitude in decimal degrees (east positive)",
        },
        altitude: {
          type: "number",
          minimum: -20000,
          maximum: 100000,
          description: "Altitude in metres (optional)",
        },
        clear_altitude: {
          type: "boolean",
          description: "Remove the photos' altitude (default false). Cannot be combined with altitude.",
        },
      },
      required: ["photo_ids", "latitude", "longitude"],
    },
  },
  {
    name: "set_location",
    toolset: "core",
    title: "Set location",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerMetadata.setLocation" },
    rules: [atLeastOneOf(locationProperties)],
    description:
      "Set IPTC location fields from get_photo_metadata. Omitted fields stay, empty strings clear. GPS stays (use set_gps). Returns updated (photos written) and fields; unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        ...locationProperties,
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_metadata",
    toolset: "core",
    title: "Set metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerMetadata.setMetadata" },
    rules: [atLeastOneOf(metadataProperties)],
    description:
      "Set IPTC text from get_photo_metadata. Omitted fields stay, empty strings clear. Copyright status is unwritable. Returns updated (photos written) and fields; unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        ...metadataProperties,
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_ai_metadata",
    toolset: "core",
    title: "Set AI metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerAiMetadata.setAiMetadata" },
    description:
      "Store an AI score and reason in private per-photo plug-in metadata in this catalog. Provide score, reason or both. Score is an integer from 0 to 100; reason is at most 1024 characters. Omitted fields stay unchanged; an empty string clears a field. Does not change IPTC, XMP, keywords, or export metadata. Returns updated (photos written); unknown IDs are not_found.",
    rules: [{ text: "give score or reason", holds: anyGiven("score", "reason") }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        score: { oneOf: [{ type: "integer", minimum: 0, maximum: 100 }, { const: "" }] },
        reason: { type: "string", maxLength: 1024 },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "get_ai_metadata",
    toolset: "core",
    title: "Get AI metadata",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerAiMetadata.getAiMetadata" },
    description:
      "Read private per-photo AI scores and reasons in one batch (up to 1000 IDs or paths). Returns photos with photo_id, numeric score and reason, one per distinct photo; unset fields are omitted. Unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { photo_ids: photoIdArray("Array of photo IDs or file paths") },
      required: ["photo_ids"],
    },
  },
  {
    name: "list_folders",
    toolset: "core",
    title: "List folders",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerFolders.listFolders" },
    description: "List catalog folders in tree order as a paginated flat list of full paths, names and photo_count (direct photos only, excluding subfolders). Default limit 100.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...pagingProperties("folders"),
      },
    },
  },
  {
    name: "get_folder_photos",
    toolset: "core",
    title: "Get folder photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerFolders.getFolderPhotos" },
    description: "List photos in a catalog folder by its full path from list_folders (paginated). Subfolders are excluded by default.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        folder_path: { type: "string", minLength: 1, description: "Full folder path from list_folders" },
        include_subfolders: { type: "boolean", description: "Include photos in subfolders (default false)" },
        ...pagingProperties("photos"),
      },
      required: ["folder_path"],
    },
  },
  {
    name: "list_collections",
    toolset: "core",
    title: "List collections",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerCollections.listCollections" },
    description: "List all collections in the catalog (paginated): name (the path through collection sets that the collection tools take), is_smart and photo_count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...pagingProperties("collections"),
      },
    },
  },
  {
    name: "create_collection",
    toolset: "core",
    title: "Create collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    run: { plugin: "HandlerCollections.createCollection" },
    description: "Create a collection; returns its path.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", pattern: "\\S", description: "Collection name" },
        parent: {
          type: "string",
          description:
            "Parent collection set path (optional), levels separated by ' / ' as in list_collections (e.g. 'Trips / 2026'). Missing sets are created; existing ones are reused, matching names ignoring case as Lightroom does. Omit it for a top-level collection; an empty level or a level with leading or trailing spaces or slashes is rejected.",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "create_smart_collection",
    toolset: "core",
    title: "Create smart collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    run: { plugin: "HandlerCollections.createSmartCollection" },
    description: "Save intersecting search_photos filters as an auto-updating smart collection; at least one filter. Creates missing parent sets; rejects existing sibling names. Returns its path.",
    rules: [{ text: "give at least one search filter", holds: anyGiven(...Object.keys(searchFilterProperties)) }, ...searchDateRules],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", pattern: "\\S", description: "Smart collection name" },
        parent: { type: "string", description: "Parent collection set path, with levels separated by ' / ' (e.g. 'Trips / 2026')" },
        ...searchFilterProperties,
      },
      required: ["name"],
    },
  },
  {
    name: "add_to_collection",
    toolset: "core",
    title: "Add to collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    run: { plugin: "HandlerCollections.addToCollection" },
    description:
      "Add photos to a regular collection; a smart collection is refused. Returns added (the photos that were not members and are now) and already_in_collection (ids of photos that were members already, left as they were); unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: collectionNameSchema,
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["collection_name", "photo_ids"],
    },
  },
  {
    name: "get_collection_photos",
    toolset: "core",
    title: "Get collection photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerCollections.getCollectionPhotos" },
    description:
      "List the photos in a collection, regular or smart (paginated). Use a path from list_collections when names repeat; an ambiguous bare name is rejected.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: PHOTO_ROW_FIELDS },
        collection_name: collectionNameSchema,
        ...pagingProperties("photos"),
      },
      required: ["collection_name"],
    },
  },
  {
    name: "remove_from_collection",
    toolset: "core",
    title: "Remove from collection",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerCollections.removeFromCollection" },
    description:
      "Remove photos from a regular collection; catalog and other memberships stay. Returns removed (unique members) and not_in_collection (photo_ids that were not members); unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: collectionNameSchema,
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["collection_name", "photo_ids"],
    },
  },
  {
    name: "delete_collection",
    toolset: "core",
    title: "Delete collection",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerCollections.deleteCollection" },
    description:
      "Delete a collection; photos stay in the catalog. Returns photo_count, the photos it held.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: collectionNameSchema,
      },
      required: ["collection_name"],
    },
  },
  {
    name: "set_keywords",
    toolset: "core",
    title: "Set keywords",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerOrganization.setKeywords" },
    rules: [{ text: "give add_keywords or remove_keywords", holds: anyGiven("add_keywords", "remove_keywords") }],
    description:
      "Add/remove keyword names or parent-first '|' paths from list_keywords, ignoring case. Missing names create top-level keywords; paths create missing levels unless create_missing=false. Returns updated (photos written); unknown IDs are not_found; a call matching no photo creates no keyword.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        add_keywords: stringArray(
          "Keywords to add: plain names or 'Parent|Child' hierarchy paths",
          MAX_KEYWORDS,
        ),
        remove_keywords: stringArray(
          "Keywords to remove: a plain name removes every keyword with that name, a 'Parent|Child' path removes only that one",
          MAX_KEYWORDS,
        ),
        create_missing: {
          type: "boolean",
          description:
            "Default true. When false, nothing is created: every keyword to add must already exist, a plain name must match exactly one keyword anywhere in the hierarchy, and the call fails without changing anything if any keyword is unknown or ambiguous.",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "remove_keyword_subtree",
    toolset: "core",
    title: "Remove keyword subtree",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerOrganization.removeKeywordSubtree" },
    rules: [{
      text: "give photo_ids or catalog_wide true, not both",
      holds: (args) => (args.catalog_wide === true) !== (args.photo_ids !== undefined),
    }],
    description:
      "Detach a parent keyword and every descendant from photo_ids, or all tagged photos with catalog_wide=true. Matches paths ignoring case; unknown parent fails unchanged. Preserves unrelated and same-named keywords elsewhere. Keyword nodes stay in the catalog and list_keywords. Use a dedicated parent such as 'AI Keywords' with set_keywords to undo a tagging batch. Returns updated (photos changed) and removed (keyword assignments removed); unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        parent: {
          type: "string",
          pattern: "\\S",
          description: "Parent-first keyword path, for example 'AI Keywords' or 'Tags|AI Keywords'",
        },
        photo_ids: photoIdArray("Photos to detach the subtree from; omit when catalog_wide is true"),
        catalog_wide: {
          type: "boolean",
          description: "Explicitly detach the subtree from every photo in the catalog; cannot accompany photo_ids",
        },
      },
      required: ["parent"],
    },
  },
  {
    name: "list_keywords",
    toolset: "core",
    title: "List keywords",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerKeywords.listKeywords" },
    description:
      "List paginated parent-first keyword paths ('Places|Europe|Paris'), synonyms and include_on_export (paginated). Pass paths to set_keywords; narrow large trees with parent/query or request paths_only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        parent: {
          type: "string",
          pattern: "\\S",
          description: "Only list keywords below this keyword path (optional)",
        },
        query: {
          type: "string",
          pattern: "\\S",
          description: "Only list keywords whose name or a synonym contains this text, ignoring case (optional)",
        },
        paths_only: {
          type: "boolean",
          description: "Return each keyword as just its path string instead of an object (default false)",
        },
        ...pagingProperties("keywords"),
      },
    },
  },
  {
    name: "rename_keyword",
    toolset: "core",
    title: "Rename keyword",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerKeywords.renameKeyword" },
    description:
      "Rename in place; tagged photos update, parent/children/synonyms stay. Case-insensitive sibling conflicts fail; case-only renames work. Returns old_path, new_path and photo_count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        keyword: {
          type: "string",
          pattern: "\\S",
          description: "Keyword from list_keywords: a unique plain name or a 'Parent|Child' path",
        },
        new_name: {
          type: "string",
          pattern: "^[^|]*[^|\\s][^|]*$",
          description: "New name for that keyword (a single name, not a path: no '|')",
        },
      },
      required: ["keyword", "new_name"],
    },
  },
  {
    name: "undo_last_step",
    toolset: "core",
    title: "Undo last step",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerUndo.undoLastStep" },
    description:
      "Undo one shared Lightroom history step (confirm:true), including a user/other plug-in action after your edit. Ownership is unknown: call only if undoing the current last step is acceptable. Lightroom can merge recent plug-in writes, even across photos, into one step. Returns undone, can_undo and message.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        confirm: {
          type: "boolean",
          const: true,
          description: "Accept undoing the latest step in Lightroom's shared history",
        },
      },
      required: ["confirm"],
    },
  },
  {
    name: "set_rating_and_flag",
    toolset: "core",
    alwaysLoad: true,
    title: "Set rating and flag",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerOrganization.setRatingAndFlag" },
    description: "Set rating, flag, or both in one write. Returns updated (photos written); unknown IDs are not_found; get_photo_metadata and photo rows report rating (0 = unrated) and flag in the same values.",
    rules: [{ text: "give rating or flag", holds: anyGiven("rating", "flag") }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        rating: {
          type: "integer",
          description: "Star rating (0-5); supply rating, flag, or both",
          minimum: 0,
          maximum: 5,
        },
        flag: {
          type: "string",
          enum: [...PHOTO_FLAG_NAMES],
          description: "pick, reject, or none (unflagged)",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_color_label",
    toolset: "core",
    title: "Set color label",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    run: { plugin: "HandlerOrganization.setColorLabel" },
    description:
      "Set a color label or none to clear; get_photo_metadata and photo rows report color_label in the same values; an unlabelled photo reads none. Returns updated (photos written); unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        label: {
          type: "string",
          enum: [...COLOR_LABEL_NAMES],
          description: "Color name, or none to clear the label",
        },
      },
      required: ["photo_ids", "label"],
    },
  },
  {
    name: "remove_photos_from_catalog",
    toolset: "core",
    title: "Remove photos from catalog",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerRemoveFromCatalog.removePhotos" },
    description:
      "Remove up to 100 IDs/paths from catalog, losing catalog edits/metadata; files remain on disk (confirm:true). Include every virtual copy with its master; a photo in a collapsed stack is refused until the stack is expanded in Lightroom; a path shared with copies is refused; use numeric IDs. Deduplicates; returns removed; unknown IDs are not_found. Opens Library grid on the photos' folders (else All Photographs), restores module/sources/surviving selection; Library stays in grid view.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths to remove from the catalog"), maxItems: 100 },
        confirm: { type: "boolean", enum: [true], description: "Explicit consent to lose these photos' catalog edits and metadata" },
      },
      required: ["photo_ids", "confirm"],
    },
  },
  {
    name: "import_photos",
    toolset: "core",
    title: "Import photos",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    duration: "long",
    run: { plugin: "HandlerImport.importPhotos" },
    description:
      "Import a photo or a folder recursively. A JPEG with a non-DNG raw file of exactly the same name (only the extension's case may differ) stays the raw's sidecar: folders leave it out and report skipped_sidecar_jpegs; importing that JPEG alone fails and names the raw. Other JPEGs import as their own photos. Files already in the catalog are left unchanged and counted in already_in_catalog. A file whose folder, or whose name within its folder, differs only in case from one in the catalog fails, because Lightroom matches both case-insensitively; on a case-insensitive volume such a name is the same file and counts in already_in_catalog. Lightroom and Photos library packages are skipped. Returns imported, already_in_catalog, added_to_collection, skipped_by_extension, skipped_sidecar_jpegs and skipped_package_files; a file that fails is failed {path, reason} when nothing was written for it (a busy catalog included) and unknown when something was, naming it (a copy or folder copy_to made, or the photo addPhoto may have added); a single-file source raises instead, with the same class; files not reached before the time budget are remaining; photos not added to the collection make the result partial. A failed file leaves the catalog and disk unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_path: { type: "string", description: `Absolute path of the photo or folder to import; ${ABSOLUTE_PATH_RULE}. Folder imports accept camera raw (CR3, RAF, ORF, RW2, NEF, ARW, DNG and other Camera Raw formats), JPEG, HEIC/HEIF, AVIF, JPEG XL, TIFF, PNG and PSD/PSB; other files are skipped by extension.` },
        collection_name: {
          ...collectionNameSchema,
          description: `${collectionNameSchema.description} Imported and already cataloged photos are added to it; an unknown or smart collection fails before importing (optional).`,
        },
        copy_to: {
          type: "string",
          description: `Absolute path of a folder to copy files and sidecars into, keeping subfolders, and import the copies; ${ABSOLUTE_PATH_RULE} (optional)`,
        },
        separate_jpegs: {
          type: "boolean",
          description: "Also add a JPEG that would stay a raw file's sidecar as its own photo (default false)",
        },
      },
      required: ["source_path"],
    },
  },
  {
    name: "export_photos",
    toolset: "core",
    title: "Export photos",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    run: { plugin: "HandlerExport.exportPhotos" },
    description:
      "Export photos, optionally with a saved export preset; format/quality/width/height override only those preset settings. Skips the preset's collision prompt and after-export action. While get_photo_detail or another export runs, the call is refused, not queued: failed with nothing exported; call again once it finishes. A photo with outdated AI settings can open Lightroom's AI Updates dialog, which blocks until dismissed. Returns written files {photo_id, path}, skipped photo_ids (on_existing skip), destination and preset; a photo whose export failed before its session started is failed, and one whose session failed after it started (Cancel in \"AI Updates Recommended\" included) is unknown, naming the export and what it leaves on the photo (one Export history step and the exported mark); both keep the files already written; photos not reached before the time budget are remaining. Argument and overwrite refusals change nothing.",
    rules: [
      { text: "give destination or export_preset", holds: anyGiven("destination", "export_preset") },
      {
        text: "export_preset_folder needs export_preset",
        holds: (args) => args.export_preset_folder === undefined || args.export_preset !== undefined,
      },
    ],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths to export"),
        destination: {
          type: "string",
          pattern: "^[^\\u0000-\\u001f]*[^\\s\\u0000-\\u001f][^\\u0000-\\u001f]*$",
          description:
            `Absolute path of the export folder, created if missing; ${ABSOLUTE_PATH_RULE}, no control characters. Optional if export_preset has a fixed destination`,
        },
        export_preset: {
          type: "string",
          minLength: 1,
          description: "Export preset title, file name, id or file path (list_export_presets)",
        },
        export_preset_folder: {
          type: "string",
          minLength: 1,
          description: "Folder of an ambiguous export_preset",
        },
        format: {
          type: "string",
          description: "Export format (jpeg, png, tiff, original)",
          enum: ["jpeg", "png", "tiff", "original"],
        },
        quality: {
          type: "number",
          description: "JPEG quality (0-100), default 90; with a preset it overrides the preset's quality and turns off its file size limit",
          minimum: 0,
          maximum: 100,
        },
        width: { type: "integer", minimum: 1, description: "Max width in pixels (optional)" },
        height: { type: "integer", minimum: 1, description: "Max height in pixels (optional)" },
        on_existing: {
          type: "string",
          description:
            "What to do when the destination already holds a file with that name (default rename). Lightroom never prompts. overwrite is refused into any catalog folder.",
          enum: ["rename", "overwrite", "skip"],
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "list_export_presets",
    toolset: "core",
    title: "List export presets",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerExport.listExportPresets" },
    description:
      "List saved export presets (not Lightroom's built-ins) with folder, file, id, format, quality, size, file_naming and destination. Only usable: true (Hard Drive) presets work with export_photos; others give unusable_reason.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        folder: {
          type: "string",
          pattern: "\\S",
          description: "Only this folder",
        },
      },
    },
  },
  {
    name: "export_photo_metadata",
    toolset: "core",
    title: "Export photo metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    run: { plugin: "HandlerExport.exportPhotoMetadata" },
    description:
      "Export up to 1000 photos to disk JSON: file/capture time/dimensions/rating/flag/color_label/title/caption/GPS/location/keywords/keyword_paths (version 2 file, snake_case keys, string photo_id), no develop settings. Omitted photo_ids uses selection, or filmstrip if none. Prefer over per-photo get_photo_metadata. Returns exported count and destination; unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths (default: current selection)"),
        destination: {
          type: "string",
          pattern: "^[^\\u0000-\\u001f]*\\.[jJ][sS][oO][nN]$",
          description: `Absolute path of the .json file to write; ${ABSOLUTE_PATH_RULE}`,
        },
        overwrite: {
          type: "boolean",
          description: "Replace the file if it already exists (default false: fail instead)",
        },
      },
      required: ["destination"],
    },
  },
  {
    name: "list_develop_presets",
    toolset: "develop",
    title: "List develop presets",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerDevelop.listDevelopPresets" },
    description: "List Lightroom-visible Develop presets and plugin-managed checkpoints (paginated). Filter by name or folder before paging. Returns name, folder, scope and uuid; use get_develop_preset for backing-file metadata. count is the total matches; has_more indicates another page.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...pagingProperties("presets"),
        query: { type: "string", minLength: 1, description: "Keep presets whose name contains this text, ignoring case" },
        folder: { type: "string", minLength: 1, description: "Exact, case-sensitive folder name, including Plugin Develop Presets for checkpoints" },
      },
    },
  },
  {
    name: "get_develop_preset",
    toolset: "develop",
    title: "Get develop preset",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerDevelop.getDevelopPreset" },
    description:
      "Read the settings and backing-file metadata for one exact Develop preset. Use preset_uuid or provide folder/scope when names are duplicated.",
    rules: [presetSelectorRule],
    inputSchema: presetSelectorSchema,
  },
  {
    name: "compare_develop_presets",
    toolset: "develop",
    title: "Compare develop presets",
    annotations: { readOnlyHint: true, openWorldHint: false },
    run: { plugin: "HandlerDevelop.compareDevelopPresets" },
    description:
      "Compare two Develop presets and return a deterministic per-setting diff for iterative style matching",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        base: { ...nestedPresetSelectorSchema, description: "Approved historical/base preset" },
        candidate: { ...nestedPresetSelectorSchema, description: "Candidate preset checkpoint" },
      },
      required: ["base", "candidate"],
    },
  },
  {
    name: "create_develop_preset",
    toolset: "develop",
    title: "Create develop preset",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerDevelop.createDevelopPreset" },
    description:
      "Capture selected settings as a versioned plugin Develop checkpoint, hidden from Develop; export for handoff. Returns preset identity/file, visible_in_develop:false and a checkpoint note.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Source photo ID or file path"),
        preset_name: {
          type: "string",
          minLength: 1,
          description: "Unique versioned checkpoint name; existing plugin names are refused",
        },
        settings: {
          type: "array",
          items: developSettingKeyItems,
          minItems: 1,
          maxItems: DEVELOP_KEYS.length,
          uniqueItems: true,
          description: "Explicit SDK setting keys from set_develop_settings to capture from the source photo",
        },
      },
      required: ["photo_id", "preset_name", "settings"],
    },
  },
  {
    name: "export_develop_preset",
    toolset: "develop",
    title: "Export develop preset",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    run: { plugin: "HandlerDevelop.exportDevelopPreset" },
    description:
      "Copy one exact custom or plugin-managed Develop preset backing file to a destination directory. Provide preset_uuid or preset_name. Existing files are never overwritten; built-in presets without backing files cannot be exported.",
    rules: [presetSelectorRule],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...presetSelectorProperties,
        destination_dir: {
          type: "string",
          minLength: 1,
          description: `Absolute path of the destination folder, created when missing; ${ABSOLUTE_PATH_RULE}`,
        },
        filename: {
          type: "string",
          minLength: 1,
          description: "Optional leaf filename. Extension must match the Lightroom backing file.",
        },
      },
      required: ["destination_dir"],
    },
  },
  {
    name: "apply_develop_preset",
    toolset: "develop",
    title: "Apply develop preset",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerDevelop.applyDevelopPreset" },
    description:
      `Apply an exact Develop preset; provide preset_uuid or preset_name. Returns applied (the photos the read-back confirmed), resolved preset identity and ai_updated (the photos whose AI masks from the preset Lightroom computed); unknown photos are not_found. With AI masks, each photo's AI masks are computed right after the preset is applied to it, and a photo starts only while the time budget still covers its apply, an AI compute wait of up to ${AI_MASK_COMPUTE_WAIT_SECONDS} s and the read-back; the preset's own masks are the entries that were not on the photo before the apply (a reapplied preset replaces its mask with a new one, so it is judged too): a photo where anything is still computing ${AI_MASK_COMPUTE_WAIT_SECONDS} s after the compute, or whose preset AI masks Lightroom could not compute, keeps the preset, has nothing rolled back and is unknown with the reason: check its masks in Develop before writing to it. An existing AI mask whose result Lightroom's photo-wide recompute changed, or one already failed before the preset, is named in a warning and does not decide. Earlier versions refuse an AI preset before writing; non-AI presets apply normally. A photo whose apply stopped is failed when nothing was written to it (a busy catalog) and unknown otherwise, naming what was written; either one stops the batch and the photos after it are listed in remaining. Photos not reached within the time budget are listed in remaining; resend exactly those. ${DEVELOP_READ_BACK}`,
    rules: [presetSelectorRule],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        dry_run: {
          type: "boolean",
          default: false,
          description: "Preview without writes or AI recomputation. Returns setting_totals across all targets and details for at most 5 targets within a 12,000-character detail budget; detail_truncated marks omitted detail. Missing path detail has a 4,000-character budget and is trimmed further to keep the reply within 20,000 characters: missing_count and one-based missing_indices identify all missing inputs, and missing_truncated flags an incomplete missing list. Tables are summarized by entry count and strings over 128 characters by length and prefix. Preset previews compare only declared settings whose current values the SDK exposes. preview_scope is readable_declared_preset_settings; unknown_current_totals counts unreadable values per key, which are excluded from changes and setting_totals. unknown_effects explicitly excludes SDK-generated values including GrainSeed and preset bookkeeping. These effects are not predicted.",
        },
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        ...presetSelectorProperties,
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "copy_develop_settings",
    toolset: "develop",
    title: "Copy develop settings",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerDevelop.copyDevelopSettings" },
    rules: [copyListRule],
    description:
      `Copy Develop settings; omitted settings includes the masks, which replace each target's masks through the guarded mask write (admission, the format check of the masks it writes, read-back, rollback). A source without masks removes the target's masks, and masks_removed lists {photo_id, count}; when neither has masks the masks are left alone. A raw's white balance does not travel to a non-raw target, which stores no Temperature or Tint: not_stored and a warning name them. A full copy leaves out FilterList, Lightroom's per-image Enhance results (Denoise, Raw Details, Super Resolution and any other filter it stores there), so each target keeps its own; when the source has filters a warning names them. In a full copy that copies or removes masks, a target on another process version first gets the source's in a history step of its own, "Set Process Version N" (a dry run lists ProcessVersion for it), and its masks are admitted under that version; when neither has masks, the process version is part of the copy's step. Admission under that version, a target mask Lightroom has not named yet and the format of the copied masks are decided before the process version is written: a refusal decided before writing leaves the target unchanged; an unknown item names what was written: read the target. A target whose guarded mask write refuses keeps its previous masks and gets none of the other settings: it is failed when nothing was written to it; when its process version was written first, that write stays after the masks are restored, so it is unknown and names it: read it before retrying. They travel without what Lightroom computed for the source photo (digests, model version, frame size, origin, reference point, image area, sync id, failure); Lightroom computes them in place for each target's own frame before its other settings are written, and a target whose copied AI mask Lightroom could not compute gets none of the other settings and its previous masks back (failed when nothing else was written to it, otherwise unknown naming what was); when that restore cannot be confirmed it is unknown and asks for its masks to be checked in Develop; a target still computing at the limit is unknown, and nothing more is written to it. data holds what happened and is present only when a copy was confirmed by its read-back (with none, adjusted values are named in the error): copied counts the confirmed copies, masks_removed lists theirs, and, when AI masks were copied, computed lists the confirmed targets whose AI masks Lightroom computed. A copied AI mask Lightroom reports finding nothing for ends failed (ErrorReason) and the target gets its previous masks back, or is unknown when that restore cannot be confirmed; it is failed when nothing else was written to it, otherwise unknown naming what was, ${AI_COMPUTE_CHANGED_MORE}; a computed mask's digest does not prove it covers anything useful, so verify one by setting an adjustment on it and comparing previews. Unknown targets are not_found. A target whose copy stopped is failed when nothing was written to it; otherwise it is unknown, naming what was written, and a read-back that shows a named key changed makes it unknown. Photos not reached within the time budget are listed in remaining; resend exactly those. ${DEVELOP_READ_BACK}`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        dry_run: {
          type: "boolean",
          default: false,
          description: "Preview without writes or AI recomputation. Returns setting_totals across all targets and details for at most 5 targets within a 12,000-character detail budget; detail_truncated marks omitted detail. Missing path detail has a 4,000-character budget and is trimmed further to keep the reply within 20,000 characters: missing_count and one-based missing_indices identify all missing inputs, and missing_truncated flags an incomplete missing list. Tables are summarized by entry count and strings over 128 characters by length and prefix. In a full copy a target whose masks the write replaces or removes shows a MaskGroupBasedCorrections change with the entry counts before and after.",
        },
        source_id: photoIdSchema("Source photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
        settings: {
          type: "array",
          items: developSettingKeyItems,
          minItems: 1,
          maxItems: DEVELOP_KEYS.length,
          description:
            "Optional whitelist of SDK setting keys from set_develop_settings. Omit to copy all.",
        },
      },
      required: ["source_id", "target_ids"],
    },
  },
  {
    name: "match_photo_style",
    toolset: "develop",
    title: "Match reference photo style",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerDevelop.matchPhotoStyle" },
    description:
      `Apply the reference photo's global look (tone, color, curves, detail, noise, grain, vignette) after confirming a Develop snapshot per target. A target whose treatment (color or black and white) differs from the reference is failed and left unchanged: convert it with set_treatment first. Leaves out keys that describe the photo rather than a look (crop, perspective and Upright, white balance, lens corrections), keys another tool writes (ConvertToGrayscale) and local adjustments/AI masks. Reference cannot be a target, including path aliases. No pixel adaptation. Returns matched and results (photo_id, snapshot id/name, settings_changed) for the targets the read-back confirmed; a target whose step stopped is failed when nothing was written for it (the snapshot refused, rolled back or the catalog busy) and unknown otherwise, naming what was written and any recovery snapshot it kept; unknown IDs are not_found. Restore with apply_develop_snapshot. Photos not reached within the time budget are listed in remaining; resend exactly those. ${DEVELOP_READ_BACK}`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        reference_id: photoIdSchema("Reference photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
      },
      required: ["reference_id", "target_ids"],
    },
  },
  {
    name: "set_develop_settings",
    toolset: "develop",
    title: "Set develop settings",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { server: serverTool(setDevelopSettings) },
    description:
      `Set Develop settings directly on a photo by Lightroom SDK name; each key's kind and range are in the settings schema. The Crop* keys are in the frame Lightroom stores, not as the photo is displayed: read the frame with get_crop and set it with set_crop. A value outside its range is refused before anything is written (Lightroom would otherwise clamp it or reset the setting to its default). A number finer than Lightroom keeps is rounded to that precision before the write and a warning names it. Returns photo_id and the stored settings. ${DEVELOP_READ_BACK} Temperature and Tint ranges depend on the photo. Point curves via ToneCurvePV2012, ToneCurvePV2012Red, ToneCurvePV2012Green and ToneCurvePV2012Blue, at most 16 points; a written curve replaces any extended (HDR) curve of that channel, and the read-back compares the curve Lightroom renders, its extended one first. Color Grading: the shadow and highlight wheels' hue and saturation are stored under the SplitToning names, balance as SplitToningBalance. Checked against the values being written and those already stored, refused before writing: ${DEVELOP_RULES.map((rule) => rule.text).join("; ")}.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        settings: {
          ...developSettingsProperty,
          description:
            "SDK setting key/value pairs (e.g., {\"Exposure2012\": 0.5, \"SaturationAdjustmentOrange\": -10})",
        },
      },
      required: ["photo_id", "settings"],
    },
    rules: developSettingsRules,
  },
  {
    name: "set_develop_settings_batch",
    toolset: "develop",
    title: "Set develop settings on many photos",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    duration: "long",
    run: { server: serverTool(setDevelopSettingsBatch) },
    description:
      `Set each of 1-50 photos its own Develop settings in one call, by the keys, ranges, rounding and rules of set_develop_settings, which apply to each photo against its own stored values. Each entry gets its own outcome: one whose settings break a rule against its photo's stored values is failed with the rule, a photo listed twice (also by id and by path) is failed for both entries, and nothing is written to either; an entry whose stored settings could not be read is failed, one not in the catalog is not_found, and one whose stored settings were not read within the time budget is remaining; the others are written. Returns results [{photo_id, settings as stored}] in request order. ${DEVELOP_READ_BACK} One read-back wait serves the whole batch; a written photo the read-back could not reach within the time budget is unknown. A photo starts only while the budget left covers its catalog wait, the read-back and the reply, about 20 s, so a batch that gets its turn with less left, for instance after waiting for other Develop calls, writes nothing and lists every photo in remaining. Photos not started before the time budget ends are remaining; resend exactly those.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photos: {
          type: "array",
          minItems: 1,
          maxItems: 50,
          description: "Photos and their own settings, in result order",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              photo_id: photoIdSchema("Photo ID or file path"),
              settings: { ...developSettingsProperty, description: "SDK setting key/value pairs for this photo" },
            },
            required: ["photo_id", "settings"],
          },
        },
      },
      required: ["photos"],
    },
    rules: [photosOnceRule, ...developSettingsRules.map(eachPhotoRule)],
  },
  {
    name: "describe_develop_keys",
    toolset: "develop",
    title: "Describe develop keys",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "drives",
    run: { server: serverTool(describeDevelopKeys) },
    description:
      "Describe every develop key the tools know for one photo on the running Lightroom: its kind and enum values, the range set_develop_settings and the mask tools enforce, and for number keys the range Lightroom reports for this photo (live, null when it reports none), marked differs where the two disagree. Local sliders get their live range only with mask_id, a mask on the photo, because Lightroom reports them only for a selected mask. Also returns Lightroom's version and build and the photo's process version.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks, to read the live ranges of the local sliders"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "set_crop",
    toolset: "develop",
    title: "Set crop",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { server: serverTool(setCrop) },
    rules: cropRules,
    description:
      "Crop one photo to a frame: either a rectangle, or an aspect ratio with the largest frame that fits around a centre (optionally scaled down), each with an optional straighten angle. The frame is stated in the photo as displayed before any crop, or with relative_to \"crop\" inside the current crop as a preview shows it (its angle then adds to the current one). The tool converts the frame to Lightroom's crop keys for every orientation, refuses a frame whose corners would leave the photo after the angle (naming the largest frame that fits), a tall or wide frame at a large angle whose turned corners would cross in Lightroom's crop keys, and a total angle outside -45 to 45, all before writing; then it writes, reads the keys back and returns the frame as get_crop reads it (rectangle in the photo as displayed before any crop, total angle, size in pixels) and the stored keys. Upright, Transform and manual distortion are not undone: with one active the frame can sit up to about 0.05 of the photo away near the edges and a warning says so.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        rectangle: {
          type: "object",
          additionalProperties: false,
          properties: {
            left: { type: "number", minimum: 0, maximum: 1 },
            top: { type: "number", minimum: 0, maximum: 1 },
            right: { type: "number", minimum: 0, maximum: 1 },
            bottom: { type: "number", minimum: 0, maximum: 1 },
          },
          required: ["left", "top", "right", "bottom"],
          description: "The frame, normalized 0 to 1 in the reference frame relative_to selects (origin top-left, y down); with an angle it is the frame before turning, around its centre. Checked only against the photo's edges, so with relative_to crop and an angle it may reach past the current crop. Not with aspect",
        },
        aspect: {
          type: "object",
          additionalProperties: false,
          properties: {
            width: { type: "number", exclusiveMinimum: 0 },
            height: { type: "number", exclusiveMinimum: 0 },
          },
          required: ["width", "height"],
          description: "Pixel aspect ratio of the result, e.g. {width: 4, height: 5} for 4:5 or {width: 1.91, height: 1}. Not with rectangle",
        },
        center: {
          type: "object",
          additionalProperties: false,
          properties: {
            x: { type: "number", exclusiveMinimum: 0, exclusiveMaximum: 1 },
            y: { type: "number", exclusiveMinimum: 0, exclusiveMaximum: 1 },
          },
          required: ["x", "y"],
          description: "With aspect: centre of the frame, normalized in the reference frame relative_to selects (default its centre)",
        },
        scale: {
          type: "number",
          exclusiveMinimum: 0,
          maximum: 1,
          description: "With aspect: fraction of the largest frame that fits around the centre inside the reference frame relative_to selects (default 1); with relative_to crop the frame always stays inside the current crop",
        },
        angle: {
          type: "number",
          minimum: -45,
          maximum: 45,
          description: "Straighten angle in degrees, default 0: positive turns the frame clockwise over the photo, so the picture turns counter-clockwise in the result",
        },
        relative_to: {
          type: "string",
          enum: ["photo", "crop"],
          description: "Frame the rectangle, centre and largest fit refer to: photo (default) is the photo as displayed before any crop; crop is the current crop as a preview shows it",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_crop",
    toolset: "develop",
    title: "Get crop",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerCrop.read" },
    description:
      "Read one photo's current crop as set_crop states it: the rectangle in the photo as displayed before any crop, the straighten angle and the cropped frame's width and height in pixels, for every orientation. An uncropped photo reads as the whole frame. Reads the catalog without opening Develop.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_lens_blur",
    toolset: "develop",
    title: "Get Lens Blur",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerLensBlur.get" },
    description: "Read Lens Blur active/amount/cat_eye/highlights_boost/focal_range near/far/focal_range_raw (four SDK values)/bokeh (Process Version 3+). No computed blur returns active:false and unavailable controls.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path") },
      required: ["photo_id"],
    },
  },
  {
    name: "get_develop_settings",
    toolset: "develop",
    title: "Get develop settings",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerRawDevelopSettings.get" },
    description:
      "Read develop settings as stored, from the catalog (no Develop or selection change), by the same SDK names set_develop_settings writes. One photo without keys: its top-level names, types and table sizes. With keys: photos[{photo_id, settings by name, absent: names the photo does not carry}] (MaskGroupBasedCorrections whole). A ToneCurvePV2012 channel answers the curve Lightroom renders: its extended (HDR) curve when the photo has one; name ExtendedToneCurvePV2012 and its channel keys to read that field as stored. The only develop read. Photos past the time or 1 MB reply limit are remaining; a photo whose own reply exceeds 1 MB is failed.",
    rules: [{
      text: "keys is required when photo_ids names more than one photo",
      holds: (args) => (args.photo_ids as unknown[]).length === 1 || args.keys !== undefined,
    }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths (a path names the master)"), maxItems: MAX_METADATA_PHOTO_IDS },
        keys: {
          type: "array",
          description:
            "Exact top-level setting names. Values JSON cannot hold come as {\"$lua\": type, value}: non-finite numbers, functions, userdata; tables with gaps or mixed keys as {\"$lua\": \"table\", entries: [[key, value], ...]}. An empty table is [].",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: 200,
          uniqueItems: true,
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_lens_blur",
    toolset: "develop",
    title: "Set Lens Blur",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerLensBlur.set" },
    rules: [{
      text: "focal_range needs near <= far",
      holds: (args) => { const focal = args.focal_range as { near: number; far: number } | undefined; return !focal || focal.near <= focal.far; },
    }],
    description: "Set any subset of Lens Blur active/amount/cat_eye/highlights_boost/focal_range/bokeh (Process Version 3+). Enables first to compute depth; active:false disables after adjustments. Values outside the schema ranges fail before writing. focal_range near/far: 0..100; Lightroom supplies outer falloff. Returns readback; unsaved values stop with earlier changes retained. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      minProperties: 2,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        active: { type: "boolean" },
        amount: { type: "number", minimum: 0, maximum: 100 },
        cat_eye: { type: "number", minimum: 0, maximum: 100 },
        highlights_boost: { type: "number", minimum: 0, maximum: 100 },
        focal_range: {
          type: "object",
          additionalProperties: false,
          properties: {
            near: { type: "number", minimum: 0, maximum: 100 },
            far: { type: "number", minimum: 0, maximum: 100 },
          },
          required: ["near", "far"],
        },
        bokeh: { type: "string", enum: ["Circle", "SoapBubble", "Blade", "Ring", "Anamorphic"] },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "set_process_version",
    toolset: "develop",
    title: "Set process version",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerDevelop.setProcessVersion" },
    description:
      "Set Version 1–6 (confirm:true; appearance can change). Downgrades of photos with masks fail to preserve guarded editing. Opens each in Develop; restore_selection defaults true. Returns results per photo, status changed or unchanged with previous_version and new_version. Max 100; stops starting photos when one more would not fit its time budget; resend remaining.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        version: { type: "string", enum: ["Version 1", "Version 2", "Version 3", "Version 4", "Version 5", "Version 6"] },
        confirm: { type: "boolean", const: true },
        restore_selection: { type: "boolean", description: "Restore module, view source and selection (default true)" },
      },
      required: ["photo_ids", "version", "confirm"],
    },
  },
  {
    name: "create_virtual_copies",
    toolset: "develop",
    title: "Create virtual copies",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerVirtualCopies.create" },
    description: "Create one virtual copy per distinct photo (max 25), named copy_name if given. Returns copies (photo_id/master_photo_id/copy_photo_id); copies made before a failure stay in data. A photo whose new copy has another master, or whose copy cannot be read back, is unknown, and its reason names every copy Lightroom created for it. Edit via copy_photo_id; repeats add more.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 25 },
        copy_name: { type: "string", pattern: "\\S", description: "Name for each new virtual copy" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_treatment",
    toolset: "develop",
    title: "Set treatment",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerTreatment.set" },
    description: "Switch photos to black_and_white or color through Lightroom's own conversion: on a raw it also swaps the profile (Adobe Color and Adobe Monochrome) and removes or restores the HSL keys. Lightroom's command acts on the selection, so the tool selects each photo alone while it runs and restores the selection afterwards; a dispatch Lightroom dropped (it can refuse one while Library is starting) is sent once more, and a photo still unchanged after that is unknown. Returns per photo convert_to_grayscale as read back and profile {before, after}; compare the two, since the conversion can change the profile and no tool writes a profile back. GrayMixer* keys act only on a black and white photo.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        treatment: { type: "string", enum: ["color", "black_and_white"] },
      },
      required: ["photo_ids", "treatment"],
    },
  },
  {
    name: "list_develop_snapshots",
    toolset: "develop",
    title: "List develop snapshots",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerSnapshots.list" },
    description: "List a photo's develop snapshots with their ids and names. A virtual copy's snapshots are listed on its master and on every copy of it.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "create_develop_snapshot",
    toolset: "develop",
    title: "Create develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerSnapshots.create" },
    description: "Save the current develop settings as a named snapshot. Duplicate names are rejected unless replace is true.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        name: { type: "string", pattern: "\\S", description: "Snapshot name" },
        replace: { type: "boolean", description: "Replace the existing snapshot with this name (default false)" },
      },
      required: ["photo_id", "name"],
    },
  },
  {
    name: "apply_develop_snapshot",
    toolset: "develop",
    title: "Apply develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerSnapshots.apply" },
    description: "Restore a photo's develop settings from one of the snapshots listed for it; only the photo named changes, not its master or other copies. Opens the photo in Develop; shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        snapshot_id: { type: "string", minLength: 1, description: "Snapshot id returned for this photo" },
      },
      required: ["photo_id", "snapshot_id"],
    },
  },
  {
    name: "delete_develop_snapshot",
    toolset: "develop",
    title: "Delete develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerSnapshots.delete" },
    description: "Delete one snapshot listed for the photo. Snapshots are stored per master, so deleting one through a virtual copy deletes it for the master and every copy. Opens the photo in Develop; shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        snapshot_id: { type: "string", minLength: 1, description: "Snapshot id returned for this photo" },
      },
      required: ["photo_id", "snapshot_id"],
    },
  },
  {
    name: "apply_auto_adjustments",
    toolset: "develop",
    title: "Apply auto adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerDevelop.applyAutoAdjustments" },
    description:
      `Apply Auto Tone, Auto White Balance or both to up to 100 photos. Set tone or white_balance true (omitted=false). Opens each in Develop and waits for settled settings; shared restoration rules apply. Returns results per photo, status applied once the changed values hold for a second. Lightroom gives no completion signal for Auto, so a photo where no change is seen within ${AUTO_CHANGE_WAIT_SECONDS} s is unknown: Auto may still land (or had nothing to change), so read its settings before writing to it. Stops starting photos when one more would not fit its time budget; resend remaining.`,
    rules: [{ text: "tone or white_balance must be true", holds: (args) => args.tone === true || args.white_balance === true }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        tone: { type: "boolean", description: "Apply Lightroom Auto Tone (default false)" },
        white_balance: { type: "boolean", description: "Apply Lightroom Auto White Balance (default false)" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "reset_develop_adjustments",
    toolset: "develop",
    title: "Reset develop adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerDevelop.resetDevelopAdjustments" },
    description:
      `Reset all Develop edits, including crop/masks, on up to 100 photos (confirm:true); recover through Lightroom History. Opens each in Develop; shared restoration rules apply. Returns results per photo, status reset, only when a read of the saved settings ${RESET_LANDING_WAIT_SECONDS} s after the reset (none sooner: a read while Lightroom applies a reset can void it) shows at least one of the photo's edits changed: a develop slider, the crop, Upright, the camera profile or Look, or fewer masks, spots or Enhance filters. Otherwise the photo is unknown: Lightroom may not have reset it, or it had no such edit; read it before writing to it. A photo that stopped being the active one in Develop before the reset is failed and nothing is reset. Stops starting photos when one more would not fit its time budget, or on cancel; resend remaining.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        confirm: { type: "boolean", enum: [true], description: "Confirm discarding all develop adjustments" },
      },
      required: ["photo_ids", "confirm"],
    },
  },
  {
    name: "apply_denoise",
    toolset: "develop",
    title: "Apply denoise",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "drives",
    run: { plugin: "HandlerDevelop.applyDenoise" },
    description:
      "Enable/change AI Denoise through Develop, not a develop key. Activates each photo; shared restoration rules apply. Activity Center computes in background. Same amount leaves the photo unchanged; other settings stay. Max 100 photos; stops starting photos when one more would not fit its time budget; resend remaining. Returns results per photo, status applied, amount_changed with previous_amount, or unchanged. A change Lightroom shows but does not save in time makes the photo unknown, naming the amount writes, even when the amount is set back and the panel shows it: read its Denoise state before retrying.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          ...photoIdArray("Photo IDs or file paths"),
          maxItems: MAX_DENOISE_PHOTO_IDS,
        },
        amount: {
          type: "integer",
          minimum: 1,
          maximum: 100,
          description: "Denoise amount, as on the Develop panel slider (Lightroom's default is 50)",
        },
        restore_selection: {
          type: "boolean",
          description:
            "Put the user's module, view source and selection back afterwards (default true). Pass false when calling in back-to-back batches: restoring loads one more photo per call.",
        },
      },
      required: ["photo_ids", "amount"],
    },
  },
  {
    name: "list_spots",
    toolset: "develop",
    title: "List Remove spots",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerSpots.list" },
    description: "List Remove spots: count, 1-based index and complete SDK params including nested fields. Indices shift after deletion. Preserves the active tool.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path") },
      required: ["photo_id"],
    },
  },
  {
    name: "update_spot",
    toolset: "develop",
    title: "Update Remove spot opacity",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerSpots.update" },
    description: "Set one Heal spot params.Opacity (uppercase, 0..1) by 1-based list_spots index. Preserves other fields/spots; sends complete selected-spot table and reads back: an Opacity Lightroom does not keep is rolled back and the call is unknown, naming the spot writes; other spots or the spot count changing during the write is unknown, with nothing written back. Returns index/changed/SDK params. Opens Remove if needed; restores previous tool and shared Develop state.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        index: { type: "integer", minimum: 1 },
        params: { type: "object", additionalProperties: false,
          properties: { Opacity: { type: "number", minimum: 0, maximum: 1 } }, required: ["Opacity"] },
      },
      required: ["photo_id", "index", "params"],
    },
  },
  {
    name: "delete_spot",
    toolset: "develop",
    title: "Delete Remove spot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerSpots.delete" },
    description: "Delete Remove spot by 1-based list_spots index (confirm:true). Returns deleted_index, remaining count/spots; later indices shift. Invalid index fails unchanged. Opens Remove if needed; restores previous tool and shared Develop state.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path"),
        index: { type: "integer", minimum: 1 }, confirm: { type: "boolean", const: true } },
      required: ["photo_id", "index", "confirm"],
    },
  },
  {
    name: "list_masks",
    toolset: "masks",
    title: "List masks",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerMasks.listMasks" },
    description:
      "List a photo's masks from its saved settings, without opening Develop, newest first as Lightroom's Masks panel shows them: id/name/hidden and tools (the mask's components) with id/type/inverted. type is gradient, radialGradient, brush, rangeMask (subtype luminance, color or depth) or aiSelection (subtype subject, sky, background, people or landscape, as create_mask names them; people and landscape add part, the people part or landscape category). A component of an encoding this server does not know is listed with its stored kind as type and no subtype. Range tools include stored luminance/depth min/max/falloffs, or a color range's samples (x/y/l/a/b, one per sample Lightroom stored) and amount; use a sample's rankings with create_range_mask, one sample per range. UI-created masks appear only after Lightroom saves them to the catalog. An empty list means the photo's saved settings hold no masks. Ids remain valid on that photo while masks stay unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_mask_write_admission",
    toolset: "masks",
    title: "Get mask write admission",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerMaskAdmission.get" },
    description:
      "Whether guarded mask writes are admitted here: running Lightroom version/build, certified build/time/checks, throwaway-catalog flag, refusal reason. photo_id adds process version, mask count and where the existing masks leave the tested format (reported only: a guarded write leaves those masks as Lightroom stored them). No Develop.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
    },
  },
  {
    name: "create_gradient_mask",
    toolset: "masks",
    title: "Create gradient mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerGradientMasks.createGradientMask" },
    description:
      "Place a linear or radial gradient (needs mask-write admission; shared guarded-write and coordinate rules apply). Linear: full strength at start, fading to zero at end. Radial: center, width, height, clockwise rotation, feather 0 hard to 100 soft, area inside or outside. Omit mask_id for a new optionally named mask; supply it to add a component with mode add (default) or subtract. Intersect is unsupported. New masks start neutral. Returns mask_id, tool_id for update_gradient_mask, shape and the geometry read back.",
    rules: [linearNeedsEnds, radialNeedsEllipse, gradientFieldsOfItsShape, exclusiveWithMaskId, subtractNeedsMaskId, nameOnlyForNewMask],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          ...localAdjustmentsSchema(),
          description: "Local sliders for the new mask by the set_mask_adjustments names (e.g., {\"local_Exposure\": 0.5}); not allowed with mask_id",
        },
        shape: { type: "string", enum: ["linear", "radial"], description: "Gradient type" },
        ...gradientGeometryProperties,
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the gradient to this existing mask instead of creating a new one",
        },
        mode: {
          type: "string",
          enum: ["add", "subtract"],
          description: "How a component combines with the mask (default add); subtract needs mask_id",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "shape"],
    },
  },
  {
    name: "update_gradient_mask",
    toolset: "masks",
    title: "Update gradient mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerGradientMasks.updateGradientMask" },
    description:
      "Reshape a gradient by tool_id from list_masks or create_gradient_mask (needs mask-write admission; shared guarded-write and coordinate rules apply). Supply only changed fields: start/end for linear, center/width/height/rotation/feather/area for radial; a field of the shape the stored tool does not have is refused before anything is written. Preserves tool id, mask id and adjustments.",
    rules: [atLeastOneOf(gradientGeometryProperties)],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        tool_id: { type: "string", minLength: 1, description: "Tool id of the gradient to change" },
        ...gradientGeometryProperties,
      },
      required: ["photo_id", "tool_id"],
    },
  },
  {
    name: "create_brush_mask",
    toolset: "masks",
    title: "Create brush mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerBrushMasks.createBrushMask" },
    description:
      "Paint strokes into a new optionally named brush mask, or supply mask_id to add a brush component (needs mask-write admission; shared guarded-write and coordinate rules apply). Each nonempty stroke has points; dabs fill consecutive points at most half a radius apart. radius defaults to 0.14; its soft edge fades near 60% (0.05 on a 1000 px photo gives about 60 px width). Lightroom's Size slider depends on Develop zoom; use radius. Per-stroke flow/density default to 1, feather to 100, erase to false; erase removes only earlier paint of that brush. Empty strokes are rejected. New masks start neutral. Use add_brush_strokes for an existing brush. Read-back checks every dab position and flow. Returns mask_id, tool_id, strokes_added and stroke_count.",
    rules: [eraseHasNoDensity, exclusiveWithMaskId, nameOnlyForNewMask],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          ...localAdjustmentsSchema(),
          description: "Local sliders for the new mask by the set_mask_adjustments names (e.g., {\"local_Exposure\": 0.5}); not allowed with mask_id",
        },
        ...brushStrokeProperties,
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the brush to this existing mask instead of creating a new one",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "strokes"],
    },
  },
  {
    name: "add_brush_strokes",
    toolset: "masks",
    title: "Add brush strokes",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerBrushMasks.addBrushStrokes" },
    description:
      "Append strokes to a brush by tool_id from list_masks or create_brush_mask (needs mask-write admission; shared guarded-write and coordinate rules apply). Uses create_brush_mask stroke settings and path filling; existing strokes, ids and adjustments stay unchanged. Empty strokes are rejected. Append erase strokes to remove paint, or delete the brush with delete_masks tool_ids and repaint. Returns mask_id, tool_id, strokes_added and stroke_count.",
    rules: [eraseHasNoDensity],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        tool_id: { type: "string", minLength: 1, description: "Tool id of the brush to add strokes to" },
        ...brushStrokeProperties,
      },
      required: ["photo_id", "tool_id", "strokes"],
    },
  },
  {
    name: "create_range_mask",
    toolset: "masks",
    title: "Create range mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerRangeMasks.createRangeMask" },
    description:
      "Create a luminance, color or depth range (needs mask-write admission; shared guarded-write and coordinate rules apply). Luminance selects min..max (0 black, 1 white), fading over falloff on each side, clipped at 0 and 1. Depth uses device depth (0 nearest, 1 farthest), requires a depth photo such as iPhone Portrait HEIC. Falloff may be 0. Color takes exactly one sample: l, a, b in 0..1 plus x, y for the pin. A second sample point is rejected because Lightroom crashes on it. l, a, b are per-photo Lightroom rankings, not sRGB or computable from RGB: lightness darkest to brightest, green to red, blue to yellow. The same color has different rankings in different photos; develop edits leave them unchanged. Selection follows l, a, b, not the pin. Obtain them through list_masks after clicking Tools > Create New Mask > Color Range in Lightroom, or supply your own ranking (e.g. l 0.9, a 0.95 for brightest reds). copy_sample_from {mask_id, tool_id, optional photo_id} replaces color.sample: copies that sample verbatim, keeping its displayed pin and amount unless color.amount overrides it. Any other source fails unchanged. Cross-photo copies match rankings, so different photos can select different colors. Returns copied_from. amount is >0 to 1 (default 0.5), narrow to broad. Omit mask_id for a new optionally named mask; supply it to add a component with mode add (default) or subtract; intersect is unsupported. invert selects outside the range. New masks start neutral. Returns mask_id, tool_id, type and the range read back in list_masks' form (a color range as color.samples, one entry).",
    rules: [rangeNeedsItsValues, rangeValuesOfItsType, copyOnlyForColor, sampleOrCopy, rangeBandWideEnough("luminance"), rangeBandWideEnough("depth"), depthNarrowerThanScene, exclusiveWithMaskId, subtractNeedsMaskId, nameOnlyForNewMask],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          ...localAdjustmentsSchema(),
          description: "Local sliders for the new mask by the set_mask_adjustments names (e.g., {\"local_Exposure\": 0.5}); not allowed with mask_id",
        },
        type: { type: "string", enum: RANGE_TYPES, description: "Kind of range mask" },
        luminance: {
          type: "object",
          additionalProperties: false,
          properties: {
            min: { type: "number", minimum: 0, maximum: 1, description: "Darkest tone selected at full strength" },
            max: { type: "number", minimum: 0, maximum: 1, description: "Brightest tone selected at full strength" },
            falloff: {
              type: "number",
              minimum: 0,
              maximum: 1,
              description: "Width of the fade on each side of min and max (default 0.1); 0 gives hard edges",
            },
          },
          required: ["min", "max"],
          description: "Luminance only: the tonal range to select",
        },
        depth: {
          type: "object",
          additionalProperties: false,
          properties: {
            min: { type: "number", minimum: 0, maximum: 1, description: "Nearest depth selected at full strength (0 is the nearest point of the scene)" },
            max: { type: "number", minimum: 0, maximum: 1, description: "Farthest depth selected at full strength (1 is the farthest point of the scene)" },
            falloff: {
              type: "number",
              minimum: 0,
              maximum: 1,
              description: "Width of the fade on each side of min and max (default 0.1); 0 gives hard edges",
            },
          },
          required: ["min", "max"],
          description: "Depth only: the depth range to select",
        },
        color: {
          type: "object",
          additionalProperties: false,
          properties: {
            sample: {
              type: "object",
              additionalProperties: false,
              properties: {
                x: { type: "number", minimum: 0, maximum: 1, description: "Horizontal position of the sample, 0 = left edge" },
                y: { type: "number", minimum: 0, maximum: 1, description: "Vertical position of the sample, 0 = top edge" },
                l: { type: "number", minimum: 0, maximum: 1, description: "Lightness rank among the photo's pixels, 0 darkest, 1 brightest (Lightroom's stored value, not sRGB)" },
                a: { type: "number", minimum: 0, maximum: 1, description: "Green-to-red rank among the photo's pixels, 0 greenest, 1 reddest (Lightroom's stored value, not sRGB)" },
                b: { type: "number", minimum: 0, maximum: 1, description: "Blue-to-yellow rank among the photo's pixels, 0 bluest, 1 yellowest (Lightroom's stored value, not sRGB)" },
              },
              required: ["x", "y", "l", "a", "b"],
              description: "The single sample point: its pin position and Lightroom's stored l, a and b for the color",
            },
            amount: {
              type: "number",
              exclusiveMinimum: 0,
              maximum: 1,
              description: "How far from the sampled color still counts, small narrow to 1 broad (default 0.5)",
            },
          },
          description: "Color only: the sample (required unless copy_sample_from is given, then not allowed) and the refine amount (with copy_sample_from, defaults to the source's amount)",
        },
        copy_sample_from: {
          type: "object",
          additionalProperties: false,
          properties: {
            mask_id: { type: "string", minLength: 1, description: "Mask id from list_masks that holds the color range to copy" },
            tool_id: { type: "string", minLength: 1, description: "Tool id of the color range inside that mask" },
            photo_id: photoIdSchema("Photo to copy from; defaults to photo_id"),
          },
          required: ["mask_id", "tool_id"],
          description: "Color only: copy the stored l, a, b sample and pin of an existing color range instead of giving color.sample",
        },
        invert: { type: "boolean", description: "Select everything outside the range (default false)" },
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the range to this existing mask instead of creating a new one",
        },
        mode: {
          type: "string",
          enum: ["add", "subtract"],
          description: "How a component combines with the mask (default add); subtract needs mask_id",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "type"],
    },
  },
  {
    name: "delete_masks",
    toolset: "masks",
    title: "Delete masks",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerMaskDelete.deleteMasks" },
    description:
      "Delete mask_ids, tool_ids (a mask's top-level components) or all=true on one photo_id by removing them from the photo's saved settings, without opening Develop or selecting anything. Ids come from list_masks; unknown ids fail unchanged, and removing a mask's last component removes the mask. Every other mask, and every other field and component of a mask that loses a component, must read back exactly, or the photo is put back and the call fails; one history step. Returns deleted mask/tool ids and the remaining mask count. To delete tool-less masks over many photos use delete_empty_masks.",
    rules: [{
      text: "give exactly one of mask_ids, tool_ids or all",
      holds: (args) => ["mask_ids", "tool_ids", "all"].filter((key) => args[key] !== undefined).length === 1,
    }],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_ids: {
          type: "array",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: MAX_MASK_DELETE_IDS,
          description: "Mask ids from list_masks",
        },
        tool_ids: {
          type: "array",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: MAX_MASK_DELETE_IDS,
          description: "Component ids from list_masks",
        },
        all: {
          type: "boolean",
          enum: [true],
          description: "Delete every mask",
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "delete_empty_masks",
    toolset: "masks",
    title: "Delete empty masks",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerMaskDelete.deleteEmptyMasks" },
    description:
      "Delete masks that have no tools on up to 1000 photos, without opening Develop; module and selection stay. Masks with a component are kept whether adjusted or not (observed on 16.0); what else Lightroom counts as empty was not observed. Returns photos_checked and changed[{photo_id, masks_removed}]; unknown IDs are not_found.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Photo IDs or file paths"),
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_mask_adjustments",
    toolset: "masks",
    title: "Set mask adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerMaskAdjustments.setMaskAdjustments" },
    description:
      "Change any subset of local SDK sliders of a mask_id from list_masks in the photo's saved settings, without opening Develop or selecting the mask; others stay unchanged. Each slider's range is in the schema; describe_develop_keys with mask_id shows where Lightroom's live range differs. Bad mask or value fails before writing. Shared mask slider rules apply. Returns the stored values, changed (from/to) and unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        adjustments: {
          ...localAdjustmentsSchema(),
          description:
            "Local slider names and the numbers to set (e.g., {\"local_Exposure\": 0.5, \"local_Shadows\": -20})",
        },
      },
      required: ["photo_id", "mask_id", "adjustments"],
    },
  },
  {
    name: "get_mask",
    toolset: "masks",
    title: "Get mask",
    annotations: { readOnlyHint: true, openWorldHint: false },
    develop: "reads",
    run: { plugin: "HandlerMaskRead.getMask" },
    description:
      "Read local adjustments, tone curves and Point Color of a mask_id from list_masks in the photo's saved settings, without opening Develop or selecting the mask. kinds defaults to all; only requested kinds are returned. Returns adjustments (every local slider by its SDK name; a slider the mask does not store reads as its neutral value), curves (main/red/green/blue flat input/output arrays; an extended curve before a plain one, [0,0,255,255] when the channel is not stored) and swatches (Lightroom order, indexed from 1, with the six decimals Lightroom stores). Unknown ids fail without reading values.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        kinds: {
          type: "array",
          items: { type: "string", enum: ["adjustments", "curves", "point_colors"] },
          minItems: 1,
          maxItems: 3,
          uniqueItems: true,
          description: "Kinds to read; omitted reads all. Omitted kinds have no result fields. Point Color swatches report SrcHue, SrcSat, SrcLum, HueShift, SatScale, LumScale, RangeAmount, Variance, HueRange, SatRange and LumRange; no swatches is an empty list.",
        },
      },
      required: ["photo_id", "mask_id"],
    },
  },
  {
    name: "invert_mask",
    toolset: "masks",
    title: "Invert mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "drives",
    run: { plugin: "HandlerMaskInvert.invertMask" },
    description:
      "Invert by mask_id from list_masks. in_place flips only one component of a multi-component mask; result lists every tool/inverted flag. copy keeps the source, makes Lightroom's inverted duplicate and, once the copy is in the photo's saved settings, writes every value of the source onto it by id (sliders, curves, Point Color, amount) with the shared mask slider rules; if that fails the copy is removed through Develop and the call is unknown, naming the duplicate and the removal, and the copy or the source change when a fresh mask list does not confirm the copy gone and the source unchanged; a warning says when Lightroom changed or re-identified the source during the copy. The masking tool and the selected mask are restored. Returns mask_id and source_mask_id. Use returned mask_id: develop writes can regenerate ids. Unknown ids fail unchanged. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: {
          type: "string",
          minLength: 1,
          description: "ID of the mask to invert, from list_masks",
        },
        mode: {
          type: "string",
          enum: ["in_place", "copy"],
          description: "in_place inverts the mask; copy keeps it and creates an inverted copy",
        },
      },
      required: ["photo_id", "mask_id", "mode"],
    },
  },
  {
    name: "create_mask",
    toolset: "masks",
    title: "Create mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerMaskCreate.createMask" },
    description:
      `Create a Subject, Sky or Background mask, or People parts/Landscape categories, by writing the new mask into the photo's saved settings and letting Lightroom compute it, without opening Develop (needs mask-write admission; shared guarded-write rules). Returns mask_id (People/Landscape: masks per part/category). Existing masks are not written. The call answers from the photo's AI state after one Update AI Settings: when Lightroom reports finding nothing (a Subject, Sky or Background with nothing to select, a missing person, part or region) it ends the new mask failed (ErrorReason), the new masks are removed and the call fails naming it, with no alert to dismiss, ${AI_COMPUTE_CHANGED_MORE}; if anything on the photo is still computing ${AI_MASK_COMPUTE_WAIT_SECONDS} s after the compute, the call is unknown and writes nothing more; an existing AI mask whose result Lightroom's photo-wide recompute changed, or one already failed before the call, is named in a warning. A computed mask's digest does not prove it covers anything useful; compare previews. One history step for the new mask and one for the compute. An \"AI process is running\" alert can need OK. See type, parts, categories and adjustments for limits.`,
    rules: [
      { text: "parts requires type people", holds: (args) => args.parts === undefined || args.type === "people" },
      { text: "categories requires type landscape", holds: (args) => args.categories === undefined || args.type === "landscape" },
      { text: "type people requires parts", holds: (args) => args.type !== "people" || args.parts !== undefined },
      { text: "type landscape requires categories", holds: (args) => args.type !== "landscape" || args.categories !== undefined },
      {
        text: "adjustments is not supported for people or landscape",
        holds: (args) => args.adjustments === undefined || (args.type !== "people" && args.type !== "landscape"),
      },
    ],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        type: {
          type: "string",
          enum: [...CREATE_MASK_TYPES],
          description: "Subject, Sky or Background; people requires parts and landscape requires categories.",
        },
        adjustments: {
          ...localAdjustmentsSchema(),
          description: "Subject/Sky/Background only, by the set_mask_adjustments names: written into the new mask, stored as Lightroom stores them (colour grade in whole numbers, other sliders to six decimals) and returned in adjustments; omitted sliders are neutral. People/Landscape reject this field; use set_mask_adjustments afterwards.",
        },
        parts: {
          type: "array",
          items: { type: "string", enum: [...PEOPLE_MASK_PART_NAMES] },
          minItems: 1,
          maxItems: PEOPLE_MASK_PART_NAMES.length,
          uniqueItems: true,
          description: "People only: each part becomes its own mask. No single-person option: Lightroom ignores written person ids and masks the first person. A missing person or part removes all new masks.",
        },
        categories: {
          type: "array",
          items: { type: "string", enum: [...LANDSCAPE_MASK_CATEGORY_NAMES] },
          minItems: 1,
          maxItems: LANDSCAPE_MASK_CATEGORY_NAMES.length,
          uniqueItems: true,
          description: "Landscape only: each category becomes its own mask, often in about 15 s. A missing region removes all new masks. Unknown/duplicate categories/parts fail before access.",
        },
      },
      required: ["photo_id", "type"],
    },
  },
  {
    name: "create_mask_batch",
    toolset: "masks",
    title: "Create mask batch",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerMaskBatch.createMaskBatch" },
    description:
      `Create the same Subject, Sky or Background mask with the same adjustments on up to 200 photos by writing it into each photo's saved settings and letting Lightroom compute it for that photo, without opening Develop (needs mask-write admission; shared guarded-write rules apply). Existing masks are not written; an existing AI mask whose result Lightroom's photo-wide recompute changed, or one already failed before the call, is named in a warning. Returns results with photo_id, mask_id, status created and, when adjustments were given, the values Lightroom stored (colour grade in whole numbers, other sliders to six decimals). A photo where Lightroom reports finding nothing (ErrorReason) is failed with its mask removed, ${AI_COMPUTE_CHANGED_MORE}, and the batch goes on; a photo still computing at the limit is unknown, and nothing more is written to it. A computed mask's digest does not prove it covers anything useful; compare previews. Stops starting photos when one more would not fit its time budget; resend remaining. Rejected mask formats fail untouched. Exposure is -4 to 4.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          ...photoIdArray("Photo IDs or file paths"),
          maxItems: MAX_MASK_BATCH_PHOTO_IDS,
        },
        type: {
          type: "string",
          enum: [...MASK_TYPE_NAMES],
          description: "What Lightroom should select on each photo: subject, sky or background",
        },
        adjustments: {
          ...localAdjustmentsSchema(),
          description: "Local sliders for each new mask by the set_mask_adjustments names. Omitted sliders start at their neutral value.",
        },
      },
      required: ["photo_ids", "type"],
    },
  },
  {
    name: "set_mask_curves",
    toolset: "masks",
    title: "Set mask curves",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerMaskCurves.setMaskCurves" },
    rules: [maskCurveRule],
    description:
      "Set local tone curves of a mask_id from list_masks in the photo's saved settings, without opening Develop or selecting the mask. curves takes any subset of main (RGB), red, green, blue as flat point arrays of at most 16 points; [0,0,255,255] is straight and is stored as no curve. Other channels stay unchanged; a written channel replaces any extended (HDR) curve of that channel. Shared mask slider and curve rules apply. Returns the stored curves, changed channels (from/to) and unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        curves: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: maskCurveProperties,
          description: "Channel names and the point arrays to set (e.g., {\"main\": [0, 0, 128, 140, 255, 255]})",
        },
      },
      required: ["photo_id", "mask_id", "curves"],
    },
  },
  {
    name: "edit_mask_point_colors",
    toolset: "masks",
    title: "Edit mask point colors",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    develop: "settings",
    run: { plugin: "HandlerMaskPointColors.editMaskPointColors" },
    description:
      "Edit local Point Color swatches by mask_id from list_masks in the photo's saved settings, without opening Develop or selecting the mask; shared mask slider rules apply. Up to 8 swatches, indexed from 1 as in get_mask swatches. add needs swatch SrcHue (0..6), SrcSat and SrcLum (0..1) and appends a swatch; like Lightroom's own add it stores the source rounded to two decimals; the fields it omits take Lightroom's defaults (shifts, scales and Variance 0, RangeAmount 0.5, Hue range 0/0.333333/0.666667/1, Saturation and Luminance ranges centred on the rounded source as Lightroom's own add centres them); a ninth swatch or a source color the mask already holds (after that rounding) is refused. update needs index and changed swatch fields and writes them to that swatch; delete needs index and removes that swatch, the later ones moving up by one; clear removes every swatch, and a mask without swatches is left unchanged. Values are stored with six decimals. Optional shift/scale/range/Variance fields and limits are in the schema. Preserves mask sliders and other/global settings. Returns action, affected index (for add, the new swatch's), changed flag and resulting swatches; when a swatch Lightroom stored cannot be read, delete and clear still write and return swatch_count with a warning instead of swatches.",
    rules: [
      {
        text: "add needs a swatch with SrcHue, SrcSat and SrcLum and no index",
        holds: (args) => {
          const swatch = args.swatch as Record<string, unknown> | undefined;
          return args.action !== "add"
            || (args.index === undefined && ["SrcHue", "SrcSat", "SrcLum"].every((field) => swatch?.[field] !== undefined));
        },
      },
      { text: "update needs index and swatch", holds: (args) => args.action !== "update" || (args.index !== undefined && args.swatch !== undefined) },
      { text: "delete needs index and no swatch", holds: (args) => args.action !== "delete" || (args.index !== undefined && args.swatch === undefined) },
      { text: "clear takes no index or swatch", holds: (args) => args.action !== "clear" || (args.index === undefined && args.swatch === undefined) },
      swatchRangesOrderedRule,
    ],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        action: {
          type: "string",
          enum: ["add", "update", "delete", "clear"],
          description: "What to do with the mask's Point Color swatches",
        },
        index: {
          type: "integer",
          minimum: 1,
          maximum: 8,
          description: "Swatch number, from 1; required for update and delete",
        },
        swatch: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: pointColorSwatchProperties,
          description: "Swatch fields; add needs SrcHue, SrcSat and SrcLum, update takes any subset",
        },
      },
      required: ["photo_id", "mask_id", "action"],
    },
  },
  {
    name: "combine_mask",
    toolset: "masks",
    title: "Combine mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    duration: "long",
    develop: "settings",
    run: { plugin: "HandlerMaskCombine.combineMask" },
    description:
      `Add, subtract or intersect a Subject, Sky or Background component on mask_id from list_masks by appending it to the mask in the photo's saved settings, without opening Develop or selecting the mask (needs mask-write admission; shared guarded-write rules apply). Lightroom then computes it with one Update AI Settings; the call answers from the photo's AI state: the new component computed is done and returns its tool_id; when Lightroom reports finding nothing to combine it ends the component failed (ErrorReason), the mask is put back and the call fails, ${AI_COMPUTE_CHANGED_MORE}; anything still computing ${AI_MASK_COMPUTE_WAIT_SECONDS} s later is unknown and nothing more is written. add widens, subtract removes, intersect keeps overlap; intersect is stored as a subtracted, inverted component, shown inverted true in list_masks. A computed component's digest does not prove it covers anything useful; compare previews. Unknown mask ids fail unchanged. One history step for the component and one for the compute.`,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("ID of the mask to combine into, from list_masks"),
        operation: {
          type: "string",
          enum: [...MASK_COMBINE_OPERATIONS],
          description: "add widens the mask, subtract removes the area from it, intersect keeps only the overlap",
        },
        type: {
          type: "string",
          enum: [...MASK_TYPE_NAMES],
          description: "What Lightroom should select for the component: subject, sky or background",
        },
      },
      required: ["photo_id", "mask_id", "operation", "type"],
    },
  },
];

export const DISPATCHED_ACTIONS: readonly PluginAction[] = [
  ...TOOL_CONTRACTS.flatMap(({ name, run, develop }) => ("plugin" in run ? [{ name, plugin: run.plugin, develop }] : [])),
  ...PLUGIN_ACTIONS,
];

const DEVELOP_USE = new Map(DISPATCHED_ACTIONS.flatMap(({ name, develop }) => (develop ? [[name, develop] as const] : [])));

export function developUseOf(action: string): DevelopUse | undefined {
  return DEVELOP_USE.get(action);
}

const READ_ONLY_TOOLS = new Set(TOOL_CONTRACTS.filter((tool) => tool.annotations.readOnlyHint).map((tool) => tool.name));

export function isReadOnlyTool(name: string): boolean {
  return READ_ONLY_TOOLS.has(name);
}
