import { identityIn, treeDigest, type Identity } from "./build-identity.js";
import { VERSION } from "./version.js";

const SERVER_FIELDS = ["version", "build", "plugin"] as const;

export type ServerIdentity = Identity<(typeof SERVER_FIELDS)[number]>;

export function serverIdentity(distDir: string, plugin: string): ServerIdentity {
  return { version: VERSION, build: treeDigest(distDir, (file) => file.endsWith(".js")), plugin };
}

export function serverIdentityIn(value: unknown): ServerIdentity {
  return identityIn(value, SERVER_FIELDS);
}
