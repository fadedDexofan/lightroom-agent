import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export type Identity<K extends string> = { readonly [key in K]: string | null };

export const BUILD_FIELDS = ["version", "build"] as const;

export type BuildIdentity = Identity<(typeof BUILD_FIELDS)[number]>;

export function sameIdentity<K extends string>(left: Identity<K>, right: Identity<K>): boolean {
  return (Object.keys(left) as K[]).every((key) => left[key] !== null && left[key] === right[key]);
}

const SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$/;

function compareIdentifiers(left: string, right: string): number {
  const numeric = /^\d+$/;
  if (numeric.test(left) && numeric.test(right)) return Math.sign(Number(left) - Number(right));
  if (numeric.test(left)) return -1;
  if (numeric.test(right)) return 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

export function compareVersions(left: string | null, right: string | null): -1 | 0 | 1 | null {
  const a = left === null ? null : SEMVER.exec(left);
  const b = right === null ? null : SEMVER.exec(right);
  if (a === null || b === null) return null;
  for (const index of [1, 2, 3]) {
    const order = Math.sign(Number(a[index]) - Number(b[index]));
    if (order !== 0) return order as -1 | 1;
  }
  if (a[4] === undefined || b[4] === undefined) return a[4] === b[4] ? 0 : a[4] === undefined ? 1 : -1;
  const pa = a[4].split("."),
    pb = b[4].split(".");
  for (let index = 0; index < Math.min(pa.length, pb.length); index++) {
    const order = compareIdentifiers(pa[index], pb[index]);
    if (order !== 0) return order as -1 | 1;
  }
  return Math.sign(pa.length - pb.length) as -1 | 0 | 1;
}

export function identityIn<K extends string>(value: unknown, fields: readonly K[]): Identity<K> {
  const record = typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
  return Object.fromEntries(
    fields.map((field) => {
      const item = record[field];
      return [field, typeof item === "string" ? item : null];
    }),
  ) as Identity<K>;
}

function filesUnder(dir: string, accept: (file: string) => boolean, prefix = ""): string[] {
  return fs.readdirSync(path.join(dir, prefix), { withFileTypes: true }).flatMap((entry) => {
    const file = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
    if (entry.isDirectory()) return filesUnder(dir, accept, file);
    return entry.isFile() && accept(file) ? [file] : [];
  });
}

export function treeDigest(dir: string, accept: (file: string) => boolean, extra = ""): string {
  const hash = createHash("sha256");
  for (const file of filesUnder(dir, accept).sort()) {
    hash.update(`${file}\0${fs.readFileSync(path.join(dir, file), "utf8").replace(/\r\n/g, "\n")}\0`);
  }
  return hash.update(extra).digest("hex").slice(0, 16);
}
