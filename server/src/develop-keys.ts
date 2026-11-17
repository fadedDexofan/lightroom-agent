import type { JSONObject } from "@modelcontextprotocol/server";

type Bounds = readonly [number, number];

export type DevelopKey = { name: string; note?: string; writtenBy?: string } & (
  | { kind: "number"; range: Bounds | "photo"; precision: number; photo?: true }
  | { kind: "enum"; values: readonly (string | number)[]; labels?: readonly string[]; photo?: true }
  | { kind: "boolean"; photo?: true }
  | { kind: "text" }
  | { kind: "curve" }
);

const SLIDER: Bounds = [-100, 100];
const AMOUNT: Bounds = [0, 100];

const slider = (name: string, range: Bounds = SLIDER, precision = 1): DevelopKey =>
  ({ name, kind: "number", range, precision });
const geometry = (name: string, range: Bounds, precision = 1): DevelopKey =>
  ({ name, kind: "number", range, precision, photo: true });
const HUE: Bounds = [0, 360];
const B_AND_W_DEFRINGE = "While the photo is black and white, Defringe reads back but renders nothing";
const COLORS = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"];

export const DEVELOP_KEYS: readonly DevelopKey[] = [
  {
    name: "WhiteBalance", kind: "enum", photo: true,
    values: ["As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash", "Custom"],
  },
  {
    name: "Temperature", kind: "number", range: "photo", precision: 1, photo: true,
    note: "Range depends on the photo: kelvin 1500 to 50000 on a raw, -150 to 100 on a rendered file (Lightroom 16.0)",
  },
  { name: "Tint", kind: "number", range: "photo", precision: 1, photo: true, note: "Range depends on the photo" },
  slider("Exposure2012", [-5, 5], 0.01),
  ...["Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Texture", "Clarity2012", "Dehaze",
    "Vibrance", "Saturation"].map((name) => slider(name)),
  ...["Saturation", "Hue", "Luminance"].flatMap((part) => COLORS.map((color) => slider(`${part}Adjustment${color}`))),
  ...["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"].map((name) => slider(name)),
  ...["ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"].map((name) => slider(name, AMOUNT)),
  ...["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"]
    .map((name): DevelopKey => ({ name, kind: "curve" })),
  { name: "ToneCurveName2012", kind: "text" },
  { name: "ConvertToGrayscale", kind: "boolean", writtenBy: "set_treatment" },
  ...COLORS.map((color) => slider(`GrayMixer${color}`)),
  slider("Sharpness", [0, 150]),
  slider("SharpenRadius", [0.5, 3], 0.1),
  ...["SharpenDetail", "SharpenEdgeMasking", "LuminanceSmoothing", "LuminanceNoiseReductionDetail",
    "LuminanceNoiseReductionContrast", "ColorNoiseReduction", "ColorNoiseReductionDetail",
    "ColorNoiseReductionSmoothness"].map((name) => slider(name, AMOUNT)),
  { name: "LensProfileEnable", kind: "enum", values: [0, 1], labels: ["off", "on"], photo: true },
  { name: "AutoLateralCA", kind: "enum", values: [0, 1], labels: ["off", "on"], photo: true },
  { ...geometry("DefringePurpleAmount", [0, 20]), note: B_AND_W_DEFRINGE },
  geometry("DefringePurpleHueLo", [0, 60]),
  geometry("DefringePurpleHueHi", [40, 100]),
  { ...geometry("DefringeGreenAmount", [0, 20]), note: B_AND_W_DEFRINGE },
  geometry("DefringeGreenHueLo", [0, 50]),
  geometry("DefringeGreenHueHi", [50, 100]),
  geometry("LensManualDistortionAmount", SLIDER),
  geometry("PerspectiveVertical", SLIDER),
  geometry("PerspectiveHorizontal", SLIDER),
  geometry("PerspectiveRotate", [-10, 10], 0.1),
  geometry("PerspectiveScale", [50, 150]),
  geometry("PerspectiveAspect", SLIDER),
  {
    name: "PerspectiveUpright", kind: "enum", photo: true,
    values: [0, 1, 2, 3, 4], labels: ["off", "auto", "full", "level", "vertical"],
    note: "Inspect the render after an Upright write: on an image without real structure Lightroom rotated the frame by about 35 degrees",
  },
  geometry("ReshapeAmount", AMOUNT),
  slider("PostCropVignetteAmount"),
  slider("PostCropVignetteMidpoint", AMOUNT),
  slider("PostCropVignetteRoundness"),
  slider("PostCropVignetteFeather", AMOUNT),
  { name: "PostCropVignetteStyle", kind: "enum", values: [1, 2, 3] },
  ...["GrainAmount", "GrainSize", "GrainFrequency"].map((name) => slider(name, AMOUNT)),
  slider("SplitToningShadowHue", HUE),
  slider("SplitToningShadowSaturation", AMOUNT),
  slider("SplitToningHighlightHue", HUE),
  slider("SplitToningHighlightSaturation", AMOUNT),
  slider("SplitToningBalance"),
  slider("ColorGradeShadowLum"),
  slider("ColorGradeHighlightLum"),
  slider("ColorGradeMidtoneHue", HUE),
  slider("ColorGradeMidtoneSat", AMOUNT),
  slider("ColorGradeMidtoneLum"),
  slider("ColorGradeGlobalHue", HUE),
  slider("ColorGradeGlobalSat", AMOUNT),
  slider("ColorGradeGlobalLum"),
  slider("ColorGradeBlending", AMOUNT),
  slider("Glow", AMOUNT),
  { name: "GlowStyle", kind: "enum", values: [0, 1, 2, 3, 4], labels: ["diffusion", "bloom", "halation", "motion", "streak"] },
  slider("GlowRange", AMOUNT),
  slider("GlowSpread", AMOUNT),
  slider("GlowWarmth"),
  slider("GlowDirection", [-180, 180]),
  ...["CropTop", "CropLeft", "CropBottom", "CropRight"].map((name) => geometry(name, [0, 1], 0.000001)),
  geometry("CropAngle", [-45, 45], 0.01),
];

export interface LocalKey {
  name: string;
  range: Bounds;
  tolerance: number;
  stored: string;
  scale: number;
  neutral?: number;
}

const WHOLE = 0.5;
const local = (name: string, stored: string, range: Bounds = SLIDER, scale = 100): LocalKey =>
  ({ name, range, tolerance: WHOLE, stored, scale });
const GRADE_WHEELS = ["Shadow", "Midtone", "Highlight", "Global"];

export const LOCAL_KEYS: readonly LocalKey[] = [
  { name: "local_Exposure", range: [-4, 4], tolerance: 0.01, stored: "LocalExposure2012", scale: 4 },
  ...["Contrast", "Highlights", "Shadows", "Whites", "Blacks"].map((name) => local(`local_${name}`, `Local${name}2012`)),
  local("local_Texture", "LocalTexture"),
  local("local_Clarity", "LocalClarity2012"),
  ...["Dehaze", "Temperature", "Tint", "Saturation", "Sharpness"].map((name) => local(`local_${name}`, `Local${name}`)),
  local("local_LuminanceNoise", "LocalLuminanceNoise"),
  local("local_Moire", "LocalMoire"),
  local("local_Defringe", "LocalDefringe"),
  ...GRADE_WHEELS.flatMap((wheel) => [
    local(`local_colorgrade${wheel}Hue`, `LocalColorGrade${wheel}Hue`, HUE, 1),
    local(`local_colorgrade${wheel}Sat`, `LocalColorGrade${wheel}Sat`, AMOUNT, 1),
    local(`local_colorgrade${wheel}Lum`, `LocalColorGrade${wheel}Lum`, SLIDER, 1),
  ]),
  { ...local("local_colorgradeBlending", "LocalColorGradeBlending", AMOUNT, 1), neutral: 50 },
  local("local_colorgradeBalance", "LocalColorGradeBalance", SLIDER, 1),
  local("local_glow", "LocalGlow"),
];

export function localAdjustmentsSchema(keys: readonly LocalKey[] = LOCAL_KEYS): JSONObject {
  return {
    type: "object",
    properties: Object.fromEntries(keys.map((key) => [key.name, { type: "number", minimum: key.range[0], maximum: key.range[1] }])),
    additionalProperties: false,
    minProperties: 1,
  };
}

const POINT_CURVE_MIN_PAIRS = 2;
const POINT_CURVE_MAX_PAIRS = 32;
const POINT_CURVE_SHAPE = "start at input 0, end at input 255 and have strictly increasing inputs";

export function isPointCurve(points: unknown): boolean {
  if (!Array.isArray(points) || points[0] !== 0 || points[points.length - 2] !== 255) return false;
  for (let index = 2; index < points.length; index += 2) {
    if ((points[index] as number) <= (points[index - 2] as number)) return false;
  }
  return true;
}

export const pointCurveRuleText = (subject: string) => `${subject} must ${POINT_CURVE_SHAPE}`;

export const pointCurveSchema = (subject: string): JSONObject => ({
  type: "array",
  items: { type: "integer", minimum: 0, maximum: 255 },
  minItems: POINT_CURVE_MIN_PAIRS * 2,
  maxItems: POINT_CURVE_MAX_PAIRS * 2,
  anyOf: Array.from({ length: POINT_CURVE_MAX_PAIRS - POINT_CURVE_MIN_PAIRS + 1 }, (_, index) => {
    const length = (POINT_CURVE_MIN_PAIRS + index) * 2;
    return { minItems: length, maxItems: length };
  }),
  description: `Flat input/output pairs for ${subject}, e.g. [0, 0, 64, 48, 192, 210, 255, 255]. Values are integers from 0 to 255 and the array holds 2 to 32 pairs, so its length is always even. The curve must ${POINT_CURVE_SHAPE}.`,
});

function described(schema: JSONObject, ...parts: (string | undefined)[]): JSONObject {
  const text = parts.filter(Boolean).join(". ");
  return text ? { ...schema, description: text } : schema;
}

function valueSchema(key: DevelopKey): JSONObject {
  switch (key.kind) {
    case "number":
      return described(key.range === "photo"
        ? { type: "number" }
        : { type: "number", minimum: key.range[0], maximum: key.range[1] }, key.note);
    case "enum":
      return described({ enum: [...key.values] },
        key.labels && key.values.map((value, i) => `${value} ${key.labels?.[i]}`).join(", "), key.note);
    case "boolean":
      return described({ type: "boolean" }, key.writtenBy && `Written by ${key.writtenBy}, not here`);
    case "text":
      return { type: "string" };
    case "curve":
      return pointCurveSchema("a Lightroom point curve");
  }
}

export function developSettingsSchema(keys: readonly DevelopKey[] = DEVELOP_KEYS): JSONObject {
  return {
    type: "object",
    properties: Object.fromEntries(keys.map((key) => [key.name, valueSchema(key)])),
    additionalProperties: false,
    minProperties: 1,
  };
}

export function developKeyNamesSchema(keys: readonly DevelopKey[] = DEVELOP_KEYS): JSONObject {
  return { type: "string", enum: keys.map((key) => key.name) };
}

export interface Rounded {
  key: string;
  requested: number;
  written: number;
}

const PRECISION = new Map(DEVELOP_KEYS.flatMap((key) => (key.kind === "number" ? [[key.name, key.precision]] : [])));

function atPrecision(value: number, precision: number): number {
  const decimals = Math.max(0, -Math.floor(Math.log10(precision)));
  return Number((Math.round(value / precision) * precision).toFixed(decimals));
}

export function roundToPrecision(settings: Record<string, unknown>): { settings: Record<string, unknown>; rounded: Rounded[] } {
  const rounded: Rounded[] = [];
  const written = Object.fromEntries(Object.entries(settings).map(([key, value]) => {
    const precision = PRECISION.get(key);
    if (precision === undefined || typeof value !== "number") return [key, value];
    const kept = atPrecision(value, precision);
    if (kept !== value) rounded.push({ key, requested: value, written: kept });
    return [key, kept];
  }));
  return { settings: written, rounded };
}

export interface OutOfRange {
  key: string;
  value: number;
  range: Bounds;
}

const RANGE = new Map(DEVELOP_KEYS.flatMap((key) => (key.kind === "number" && key.range !== "photo" ? [[key.name, key.range]] : [])));

export function outOfRange(settings: Readonly<Record<string, unknown>>): OutOfRange[] {
  return Object.entries(settings).flatMap(([key, value]) => {
    const range = RANGE.get(key);
    return range && typeof value === "number" && (value < range[0] || value > range[1]) ? [{ key, value, range }] : [];
  });
}

export interface DevelopRule {
  text: string;
  triggers: readonly string[];
  reads: readonly string[];
  holds: (values: Readonly<Record<string, unknown>>) => boolean;
}

const pair = (low: string, high: string, text: string, apart: (difference: number) => boolean): DevelopRule => ({
  text, triggers: [low, high], reads: [low, high],
  holds: (values) => typeof values[low] !== "number" || typeof values[high] !== "number"
    || apart((values[high] as number) - (values[low] as number)),
});

const CURVE_KEYS = DEVELOP_KEYS.filter((key) => key.kind === "curve").map((key) => key.name);

export const DEVELOP_RULES: readonly DevelopRule[] = [
  pair("CropLeft", "CropRight", "CropLeft must be less than CropRight", (difference) => difference > 0),
  pair("CropTop", "CropBottom", "CropTop must be less than CropBottom", (difference) => difference > 0),
  ...["Purple", "Green"].map((color) => pair(`Defringe${color}HueLo`, `Defringe${color}HueHi`,
    `Defringe${color}HueHi must be at least 10 above Defringe${color}HueLo (Lightroom resets the pair otherwise)`,
    (difference) => difference >= 10)),
  {
    text: "GlowStyle needs Glow above 0 (Lightroom resets the style otherwise)",
    triggers: ["GlowStyle"], reads: ["Glow"],
    holds: (values) => typeof values.Glow === "number" && values.Glow > 0,
  },
  {
    text: "GrayMixer keys need a black and white photo (set_treatment black_and_white first); Lightroom keeps them only then",
    triggers: COLORS.map((color) => `GrayMixer${color}`), reads: ["ConvertToGrayscale"],
    holds: (values) => values.ConvertToGrayscale === true,
  },
  {
    text: pointCurveRuleText("A ToneCurvePV2012 curve"),
    triggers: CURVE_KEYS, reads: [],
    holds: (values) => CURVE_KEYS.every((key) => values[key] === undefined || isPointCurve(values[key])),
  },
  {
    text: "GlowDirection needs GlowStyle 3 (motion) or 4 (streak) (it renders nothing with the other styles)",
    triggers: ["GlowDirection"], reads: ["GlowStyle"],
    holds: (values) => values.GlowStyle === 3 || values.GlowStyle === 4,
  },
];

export function rulesTouchedBy(settings: Readonly<Record<string, unknown>>): DevelopRule[] {
  return DEVELOP_RULES.filter((rule) => rule.triggers.some((key) => key in settings));
}

export function mayWrite(tool: string, key: DevelopKey): boolean {
  return key.writtenBy === undefined || key.writtenBy === tool;
}

export function transfersStyle(key: DevelopKey): boolean {
  return !("photo" in key && key.photo) && mayWrite("match_photo_style", key);
}

const KEY_BY_NAME = new Map(DEVELOP_KEYS.map((key) => [key.name, key]));

export function keysRefusedFor(tool: string, names: Iterable<string>): DevelopKey[] {
  return [...names].flatMap((name) => {
    const key = KEY_BY_NAME.get(name);
    return key && !mayWrite(tool, key) ? [key] : [];
  });
}

export function writtenElsewhereText(keys: readonly DevelopKey[]): string {
  return keys.map((key) => `${key.name} is written by ${key.writtenBy}`).join("; ");
}
