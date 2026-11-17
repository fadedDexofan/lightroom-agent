import fs from "node:fs";
import path from "node:path";
import { configDir } from "./config-dir.js";

export function tokenFilePath(): string {
  return (
    process.env.LIGHTROOM_AGENT_TOKEN_PATH ??
    path.join(configDir(), "token")
  );
}

export function readToken(): string {
  const p = tokenFilePath();
  let raw: string;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch {
    throw new Error(
      `Lightroom Agent token file not found at ${p}. ` +
        `Open Lightroom and click 'Start Server' in Plug-in Manager to generate one.`,
    );
  }
  const token = raw.trim();
  if (!token) throw new Error(`Token file ${p} is empty`);
  return token;
}
