import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export type Identity<K extends string> = { readonly [key in K]: string | null };

export const BUILD_FIELDS = ["version", "build"] as const;

export type BuildIdentity = Identity<(typeof BUILD_FIELDS)[number]>;

export function sameIdentity<K extends string>(left: Identity<K>, right: Identity<K>): boolean {
  return (Object.keys(left) as K[]).every((key) => left[key] !== null && left[key] === right[key]);
}

export function identityIn<K extends string>(value: unknown, fields: readonly K[]): Identity<K> {
  const record = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  return Object.fromEntries(fields.map((field) => {
    const item = record[field];
    return [field, typeof item === "string" ? item : null];
  })) as Identity<K>;
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
