import { DEVELOP_KEYS, LOCAL_KEYS, transfersStyle } from "./develop-keys.js";
import { DETAIL_RENDER_FOLDER } from "./photo-detail.js";
import { HEARTBEAT_INTERVAL_SECONDS } from "./plugin-liveness.js";
import { PREVIEW_REPLY_RESERVE_MS } from "./preview-item.js";
import { VERSION } from "./version.js";
import { AI_MASK_COMPUTE_WAIT_SECONDS, AUTO_CHANGE_WAIT_SECONDS, CATALOG_WRITE_WAIT_SECONDS, DEFAULT_PAGE_LIMIT, NEW_MASK_SAVE_WAIT_SECONDS, PLUGIN_ACTIONS, STYLE_SUMMARY_MIN_RATING, STYLE_SUMMARY_PHOTO_LIMIT, TOOL_CONTRACTS } from "./tool-contracts.js";
import {
  COLOR_LABELS,
  LANDSCAPE_MASK_CATEGORIES,
  MASK_CURVE_CHANNELS,
  MASK_TYPES,
  PEOPLE_MASK_PARTS,
  PHOTO_FLAGS,
  STORED_MASK_DECIMAL_PLACES,
} from "./lightroom-tables.js";

type LuaValue = string | number | boolean | readonly LuaValue[] | { readonly [key: string]: LuaValue };

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

function render(value: LuaValue, indent: string): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  const inner = `${indent}    `;
  if (Array.isArray(value)) {
    const items = value as readonly LuaValue[];
    if (items.every((item) => typeof item !== "object")) {
      return `{ ${items.map((item) => render(item, inner)).join(", ")} }`;
    }
    return `{\n${items.map((item) => `${inner}${render(item, inner)},\n`).join("")}${indent}}`;
  }
  const entries = Object.entries(value as { readonly [key: string]: LuaValue });
  const field = ([key, item]: [string, LuaValue]) =>
    `${IDENTIFIER.test(key) ? key : `[${JSON.stringify(key)}]`} = ${render(item, inner)}`;
  if (entries.every(([, item]) => typeof item !== "object")) {
    return `{ ${entries.map(field).join(", ")} }`;
  }
  return `{\n${entries.map((entry) => `${inner}${field(entry)},\n`).join("")}${indent}}`;
}

function dispatchMap(): Record<string, readonly [string, string]> {
  const actions = [
    ...TOOL_CONTRACTS.flatMap(({ name, run }) => ("plugin" in run ? [{ name, plugin: run.plugin }] : [])),
    ...PLUGIN_ACTIONS,
  ].sort((a, b) => a.name.localeCompare(b.name));
  return Object.fromEntries(actions.map(({ name, plugin }) => {
    const [module, fn] = plugin.split(".");
    return [name, [module, fn] as const];
  }));
}

export function renderContractLua(): string {
  const contract: LuaValue = {
    DISPATCH: dispatchMap(),
    DEVELOP_KEYS: DEVELOP_KEYS.map((key): LuaValue => ({
      name: key.name,
      ...(transfersStyle(key) ? { style: true } : {}),
      ...(key.kind === "number" ? { precision: key.precision } : {}),
      ...(key.kind === "curve" ? { extended: key.extended } : {}),
    })),
    LOCAL_KEYS: LOCAL_KEYS.map(({ range: _range, ...key }): LuaValue => key),
    MASK_TYPES,
    PEOPLE_MASK_PARTS,
    LANDSCAPE_MASK_CATEGORIES,
    MASK_CURVE_CHANNELS,
    PHOTO_FLAGS,
    COLOR_LABELS,
    PREVIEW_REPLY_RESERVE_SECONDS: PREVIEW_REPLY_RESERVE_MS / 1000,
    DETAIL_RENDER_FOLDER,
    DEFAULT_PAGE_LIMIT,
    CATALOG_WRITE_WAIT_SECONDS,
    AI_MASK_COMPUTE_WAIT_SECONDS,
    AUTO_CHANGE_WAIT_SECONDS,
    NEW_MASK_SAVE_WAIT_SECONDS,
    STORED_MASK_DECIMAL_PLACES,
    STYLE_SUMMARY_MIN_RATING,
    STYLE_SUMMARY_PHOTO_LIMIT,
    HEARTBEAT_INTERVAL_SECONDS,
    VERSION,
  };
  return `return ${render(contract, "")}\n`;
}
