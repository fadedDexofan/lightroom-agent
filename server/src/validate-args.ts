import { Ajv, type ErrorObject, type ValidateFunction } from "ajv";
import { PHOTO_ID_PATTERN, TOOL_CONTRACTS, type ToolArgs, type ToolContract } from "./tool-contracts.js";

const ajv = new Ajv({ strict: false, allErrors: true, verbose: true });

export interface CheckedContract {
  contract: ToolContract;
  validate: ValidateFunction;
}

export const CHECKED_CONTRACTS: ReadonlyMap<string, CheckedContract> = new Map(
  TOOL_CONTRACTS.map((contract) => [contract.name, { contract, validate: ajv.compile(contract.inputSchema) }]),
);

const RENAMED: Readonly<Record<string, readonly string[]>> = {
  photo_id: ["photo_ids"],
  target_ids: ["photo_ids"],
  source_id: ["source_photo_id", "reference_photo_id"],
  reference_id: ["reference_photo_id", "source_photo_id"],
  "copy_sample_from.photo_id": ["source_photo_id"],
  "photos.photo_ids": ["photo_id"],
};

const BATCH_MASK_TYPES = (
  TOOL_CONTRACTS.find((contract) => contract.name === "create_mask_batch")?.inputSchema.properties as
    | { type?: { enum?: unknown[] } }
    | undefined
)?.type?.enum;

const PLURAL_SIBLING: Readonly<Record<string, { name: string; takes: (args: ToolArgs) => boolean }>> = {
  get_photo_preview: { name: "get_photo_previews", takes: () => true },
  set_develop_settings: { name: "set_develop_settings_batch", takes: () => true },
  create_mask: { name: "create_mask_batch", takes: (args) => BATCH_MASK_TYPES?.includes(args.type) === true },
};

const PROFILE_KEYS = new Set(["CameraProfile", "CameraProfileDigest", "Look", "ProfileAmount"]);

function renameHint(field: string, property: string, offered: Record<string, unknown>): string {
  const parents = field.split(".").filter((part) => part !== "" && !/^\d+$/.test(part));
  if (parents.at(-1) === "settings" && PROFILE_KEYS.has(property)) return ": use set_profile";
  const renamed = RENAMED[[...parents, property].join(".")]?.find((name) => name in offered);
  return renamed ? `: use ${renamed}` : "";
}

function alternative(schema: unknown): string {
  const {
    type,
    enum: values,
    minimum,
    maximum,
  } = (schema ?? {}) as {
    type?: string;
    enum?: unknown[];
    minimum?: number;
    maximum?: number;
  };
  if (values) return values.map((value) => JSON.stringify(value)).join(", ");
  if (type === "number" && minimum !== undefined && maximum !== undefined) {
    return `a number between ${minimum} and ${maximum}`;
  }
  return type ? `a ${type}` : "a valid value";
}

function describe(tool: string, args: ToolArgs, error: ErrorObject): string {
  const field = error.instancePath ? error.instancePath.replace(/^\//, "").replace(/\//g, ".") : "";
  const params = error.params as { additionalProperty?: string; type?: string[]; allowedValues?: unknown[] };
  if (params.additionalProperty) {
    const offered = (error.parentSchema as { properties?: Record<string, unknown> } | undefined)?.properties ?? {};
    const unknown = `unknown property "${params.additionalProperty}"${renameHint(field, params.additionalProperty, offered)}`;
    return field ? `${field} ${unknown}` : unknown;
  }
  let what: string;
  if ((error.parentSchema as { pattern?: string } | undefined)?.pattern === PHOTO_ID_PATTERN) {
    what = "must be a photo ID (an integer from 1 without a leading zero) or an absolute file path";
  } else if (error.keyword === "oneOf" || error.keyword === "anyOf") {
    const options = [...(error.schema as { enum?: unknown[] }[])]
      .sort((left, right) => Number(Boolean(right.enum)) - Number(Boolean(left.enum)))
      .map(alternative);
    what = `must be ${options.join(", or ")}`;
  } else if (error.keyword === "enum" && params.allowedValues) {
    what = `must be one of ${params.allowedValues.map((value) => JSON.stringify(value)).join(", ")}`;
  } else if (Array.isArray(params.type)) {
    what = `must be ${params.type.join(" or ")}`;
  } else if (error.keyword === "maxItems" && field === "photo_ids" && PLURAL_SIBLING[tool]?.takes(args)) {
    what = `${error.message}; use ${PLURAL_SIBLING[tool].name} for several photos`;
  } else {
    what = error.message ?? "is invalid";
  }
  return field ? `${field} ${what}` : what;
}

function problems(tool: string, args: ToolArgs, errors: ErrorObject[]): string[] {
  const combined = new Set(
    errors.filter((error) => error.keyword === "oneOf" || error.keyword === "anyOf").map((error) => error.instancePath),
  );
  return errors
    .filter((error) => error.keyword === "oneOf" || error.keyword === "anyOf" || !combined.has(error.instancePath))
    .map((error) => describe(tool, args, error));
}

export function validateToolArgs({ contract, validate }: CheckedContract, args: ToolArgs): string | null {
  if (!validate(args)) {
    const unique = [...new Set(problems(contract.name, args, validate.errors ?? []))];
    return `Invalid arguments for ${contract.name}: ${unique.join("; ")}`;
  }
  const broken = (contract.rules ?? []).find((rule) => !rule.holds(args));
  if (!broken) return null;
  const where = broken.where?.(args);
  return `Invalid arguments for ${contract.name}: ${broken.text}${where ? ` (${where})` : ""}`;
}
