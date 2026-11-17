import { Ajv, type ErrorObject, type ValidateFunction } from "ajv";
import { PHOTO_ID_PATTERN, TOOL_CONTRACTS, type ArgumentRule, type ToolArgs } from "./tool-contracts.js";

const ajv = new Ajv({ strict: false, allErrors: true, verbose: true });

const validators = new Map<string, { validate: ValidateFunction; rules: readonly ArgumentRule[] }>(
  TOOL_CONTRACTS.map((contract) => [
    contract.name,
    { validate: ajv.compile(contract.inputSchema), rules: contract.rules ?? [] },
  ]),
);

function alternative(schema: unknown): string {
  const { type, enum: values, minimum, maximum } = (schema ?? {}) as {
    type?: string; enum?: unknown[]; minimum?: number; maximum?: number;
  };
  if (values) return values.map((value) => JSON.stringify(value)).join(", ");
  if (type === "number" && minimum !== undefined && maximum !== undefined) {
    return `a number between ${minimum} and ${maximum}`;
  }
  return type ? `a ${type}` : "a valid value";
}

function describe(error: ErrorObject): string {
  const field = error.instancePath ? error.instancePath.replace(/^\//, "").replace(/\//g, ".") : "";
  const params = error.params as { additionalProperty?: string; type?: string[]; allowedValues?: unknown[] };
  if (params.additionalProperty) return `unknown property "${params.additionalProperty}"`;
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
  } else {
    what = error.message ?? "is invalid";
  }
  return field ? `${field} ${what}` : what;
}

function problems(errors: ErrorObject[]): string[] {
  const combined = new Set(errors
    .filter((error) => error.keyword === "oneOf" || error.keyword === "anyOf")
    .map((error) => error.instancePath));
  return errors
    .filter((error) => error.keyword === "oneOf" || error.keyword === "anyOf" || !combined.has(error.instancePath))
    .map(describe);
}

export function validateToolArgs(name: string, args: unknown): string | null {
  const contract = validators.get(name);
  if (!contract) throw new Error(`No contract for ${name}`);
  const values = args ?? {};
  if (!contract.validate(values)) {
    const unique = [...new Set(problems(contract.validate.errors ?? []))];
    return `Invalid arguments for ${name}: ${unique.join("; ")}`;
  }
  const broken = contract.rules.find((rule) => !rule.holds(values as ToolArgs));
  return broken ? `Invalid arguments for ${name}: ${broken.text}` : null;
}
