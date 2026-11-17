import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { encodePng } from "./png.mjs";

const JPEG_QUALITY = "95";

export function encodeJpegWithSips(canvas) {
  if (process.platform !== "darwin") throw new Error("JPEG fixtures are encoded with sips and need macOS");
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "lragent-jpeg-"));
  try {
    const pngPath = path.join(scratch, "in.png");
    const jpegPath = path.join(scratch, "out.jpg");
    fs.writeFileSync(pngPath, encodePng(canvas));
    execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", JPEG_QUALITY, pngPath, "--out", jpegPath], {
      stdio: "ignore",
    });
    return fs.readFileSync(jpegPath);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

const DQT = 0xdb;
const START_OF_SCAN = 0xda;

export function jpegQuantTables(jpeg) {
  const tables = [];
  let at = 2;
  while (at + 4 <= jpeg.length && jpeg[at] === 0xff && jpeg[at + 1] !== START_OF_SCAN) {
    const length = jpeg.readUInt16BE(at + 2);
    if (jpeg[at + 1] === DQT) {
      let cursor = at + 4;
      while (cursor < at + 2 + length) {
        const wide = jpeg[cursor] >> 4 === 1;
        const size = wide ? 128 : 64;
        const values = [];
        for (let i = 0; i < 64; i++) values.push(wide ? jpeg.readUInt16BE(cursor + 1 + i * 2) : jpeg[cursor + 1 + i]);
        tables.push({ id: jpeg[cursor] & 0x0f, precision: wide ? 16 : 8, values });
        cursor += 1 + size;
      }
    }
    at += 2 + length;
  }
  return tables;
}
