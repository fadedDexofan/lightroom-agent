import os from "node:os";
import path from "node:path";

export function configDir(): string {
  return path.join(os.homedir(), ".config", "lightroom-agent");
}
