import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { batchCropOffsets, batchFileName } from "../lib/batch.mjs";
import { catalogWindowState, chooseModalButton, parseModalWindows, watchModalsWhile } from "../lib/ax.mjs";
import { lastExportTimestamp, maskGroupsText, parseLuaTable, storedMaskGroups, summarizeMaskGroups } from "../lib/catalog-db.mjs";
import { addedLuaFiles, assertOutsideTemporaryDirectory, listLuaFiles } from "../lib/plugin-bundle.mjs";
import { jpegQuantTables } from "../lib/jpeg.mjs";
import { createReport } from "../lib/proof.mjs";
import {
  alternationRate,
  bandDeltas,
  changeCentroid,
  colorCentroid,
  decodeBmp,
  ellipseInside,
  intersectionOverUnion,
  meanChroma,
  patchDeltas,
  rectangleInside,
  regionDeltas,
} from "../lib/preview.mjs";

function solidPixels(w, h, level) {
  const size = w * h;
  const fill = () => new Float32Array(size).fill(level);
  return { w, h, R: fill(), G: fill(), B: fill(), L: fill() };
}

function brightenWhere(pixels, inside, amount) {
  const copy = { ...pixels, L: Float32Array.from(pixels.L), R: Float32Array.from(pixels.R), G: Float32Array.from(pixels.G), B: Float32Array.from(pixels.B) };
  for (let y = 0; y < pixels.h; y++) {
    for (let x = 0; x < pixels.w; x++) {
      if (inside((x + 0.5) / pixels.w, (y + 0.5) / pixels.h, pixels.w, pixels.h)) {
        const i = y * pixels.w + x;
        copy.L[i] += amount;
        copy.R[i] += amount;
      }
    }
  }
  return copy;
}

test("modal windows are parsed and the safe button is chosen", () => {
  const raw = [
    ["", "OK", "No faces detected in this photo"],
    ["Enable address lookup?", "Enable|Not Now", "Lightroom can look up addresses"],
    ["Other", "Save", "Something else"],
  ]
    .map((fields) => fields.join("\u001f"))
    .join("\u001e");
  const windows = parseModalWindows(raw);
  assert.deepEqual(windows.map(chooseModalButton), ["OK", "Not Now", null]);
});

test("the open catalog is read from Lightroom's main window title", () => {
  const requested = "/Users/me/Pictures/Lightroom/Lightroom Catalog.lrcat";
  const main = (name) => ["", "", `${name} - Adobe Photoshop Lightroom Classic - Develop`];
  assert.equal(catalogWindowState(main("Lightroom Catalog.lrcat"), requested), "requested");
  assert.equal(catalogWindowState(main("lrmcp-live-20261112090706.lrcat"), requested), "other");
  assert.equal(catalogWindowState(["", ""], requested), "waiting");
  assert.equal(catalogWindowState(["Lightroom Plug-in Manager"], requested), "waiting");
});

test("the main window and Plug-in Manager are never treated as modals", () => {
  const raw = ["Lightroom Catalog.lrcat - Adobe Photoshop Lightroom Classic - Library", "OK", "x"].join("\u001f");
  assert.deepEqual(parseModalWindows(raw), []);
  assert.deepEqual(parseModalWindows(["Lightroom Plug-in Manager", "Done", ""].join("\u001f")), []);
});

test("address lookup is never enabled", () => {
  assert.equal(chooseModalButton({ title: "", text: "Enable address lookup?", buttons: ["Enable"] }), null);
});

test("region deltas measure the brightened area only", () => {
  const before = solidPixels(100, 100, 0.2);
  const after = brightenWhere(before, rectangleInside({ x0: 0, y0: 0, x1: 1, y1: 0.5 }), 0.3);
  const deltas = regionDeltas(before, after, [
    { name: "top", x0: 0, y0: 0, x1: 1, y1: 0.4 },
    { name: "bottom", x0: 0, y0: 0.6, x1: 1, y1: 1 },
  ]);
  assert.ok(Math.abs(deltas.top - 0.3) < 1e-6);
  assert.ok(Math.abs(deltas.bottom) < 1e-6);
  const bands = bandDeltas(before, after, 10);
  assert.ok(bands.rows[0] > 0.29 && bands.rows[9] === 0);
});

test("patch deltas report per channel changes", () => {
  const before = solidPixels(100, 100, 0.2);
  const after = brightenWhere(before, rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 }), 0.1);
  const [left, right] = patchDeltas(before, after, [{ x: 0.25, y: 0.5 }, { x: 0.75, y: 0.5 }]);
  assert.ok(Math.abs(left.deltaR - 0.1) < 1e-6);
  assert.equal(left.deltaG, 0);
  assert.equal(right.deltaL, 0);
});

test("IoU is 1 for a perfect ellipse, low for a shifted one", () => {
  const ellipse = { center: { x: 0.5, y: 0.5 }, width: 0.5, height: 0.3, rotationDegrees: 40 };
  const before = solidPixels(200, 120, 0.2);
  const after = brightenWhere(before, ellipseInside(ellipse), 0.3);
  assert.ok(intersectionOverUnion(before, after, ellipseInside(ellipse)) > 0.99);
  const shifted = { ...ellipse, center: { x: 0.85, y: 0.5 } };
  assert.ok(intersectionOverUnion(before, after, ellipseInside(shifted)) < 0.3);
  assert.ok(intersectionOverUnion(before, after, ellipseInside({ ...ellipse, rotationDegrees: -40 })) < 0.9);
});

test("a BMP is decoded bottom-up with BGR order", () => {
  const bmp = Buffer.alloc(54 + 8);
  bmp.writeUInt32LE(54, 10);
  bmp.writeInt32LE(1, 18);
  bmp.writeInt32LE(2, 22);
  bmp.writeUInt16LE(24, 28);
  bmp.set([0, 0, 255], 54);
  bmp.set([255, 0, 0], 58);
  const pixels = decodeBmp(bmp);
  assert.equal(pixels.w, 1);
  assert.equal(pixels.h, 2);
  assert.equal(pixels.B[0], 1);
  assert.equal(pixels.R[1], 1);
});

test("stored mask groups are extracted from a develop settings row", () => {
  const settings = [
    "s = {",
    '  Exposure2012 = 0.5,',
    "  MaskGroupBasedCorrections = {",
    "    {",
    '      CorrectionID = "AB",',
    '      CorrectionName = "Mask 1",',
    "      LocalExposure2012 = 1.5,",
    "      CorrectionMasks = {",
    '        { What = "Mask/Gradient", MaskID = "M1", MaskInverted = false, MaskBlendMode = 0, },',
    "      },",
    "    },",
    "  },",
    "  Other = 1,",
    "}",
  ].join("\n");
  assert.ok(maskGroupsText(settings).startsWith("{"));
  const summary = summarizeMaskGroups(storedMaskGroups(settings));
  assert.deepEqual(summary, [
    {
      id: "AB",
      name: "Mask 1",
      exposure: 1.5,
      contrast: undefined,
      components: [{ id: "M1", what: "Mask/Gradient", inverted: false, blend: 0 }],
    },
  ]);
  assert.deepEqual(storedMaskGroups("s = { Exposure2012 = 0 }"), []);
});

test("lua table parser handles quoted keys, nil and nested arrays", () => {
  assert.deepEqual(parseLuaTable('{ ["a b"] = 1, c = nil, d = { 1, 2, 3 }, e = "x\\"y" }'), {
    "a b": 1,
    c: null,
    d: [1, 2, 3],
    e: 'x"y',
  });
});

test("added Lua files are the ones a reload would not see", () => {
  assert.deepEqual(addedLuaFiles(["A.lua", "B.lua"], ["A.lua", "B.lua", "C.lua", "D.lua"]), ["C.lua", "D.lua"]);
  assert.deepEqual(addedLuaFiles(["A.lua"], ["A.lua"]), []);
});

test("Lua files are listed recursively and sorted", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-bundle-"));
  try {
    fs.mkdirSync(path.join(directory, "sub"));
    fs.writeFileSync(path.join(directory, "b.lua"), "");
    fs.writeFileSync(path.join(directory, "a.lua"), "");
    fs.writeFileSync(path.join(directory, "notes.txt"), "");
    fs.writeFileSync(path.join(directory, "sub", "c.lua"), "");
    assert.deepEqual(listLuaFiles(directory).map((file) => file.split(path.sep).join("/")), ["a.lua", "b.lua", "sub/c.lua"]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("bundle backups under the temporary directory are refused", () => {
  const temporary = os.tmpdir();
  assert.throws(() => assertOutsideTemporaryDirectory(path.join(temporary, "backups"), temporary), /outside the temporary directory/);
  assert.throws(() => assertOutsideTemporaryDirectory(temporary, temporary), /outside the temporary directory/);
  assert.doesNotThrow(() => assertOutsideTemporaryDirectory(path.join(os.homedir(), ".cache", "x"), temporary));
});

test("deltas compare previews of different sizes by normalized position", () => {
  const before = solidPixels(100, 60, 0.2);
  const after = brightenWhere(solidPixels(200, 120, 0.2), rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 }), 0.3);
  const deltas = regionDeltas(before, after, [
    { name: "left", x0: 0, y0: 0, x1: 0.4, y1: 1 },
    { name: "right", x0: 0.6, y0: 0, x1: 1, y1: 1 },
  ]);
  assert.ok(Math.abs(deltas.left - 0.3) < 1e-6);
  assert.ok(Math.abs(deltas.right) < 1e-6);
  assert.ok(intersectionOverUnion(before, after, rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 })) > 0.99);
});

test("batch crops are all distinct and stay inside the base image", () => {
  const offsets = batchCropOffsets(200, 400, 267);
  assert.equal(offsets.length, 200);
  assert.equal(new Set(offsets.map(({ x, y }) => `${x},${y}`)).size, 200);
  for (const { x, y } of offsets) {
    assert.ok(x >= 0 && x <= 400 && y >= 0 && y <= 267);
  }
  assert.deepEqual(batchCropOffsets(1, 400, 267), [{ x: 0, y: 0 }]);
  assert.equal(batchFileName(0), "batch_001.jpg");
  assert.equal(batchFileName(199), "batch_200.jpg");
});

test("the change centroid is the centre of the brightened area", () => {
  const before = solidPixels(200, 100, 0.2);
  const after = brightenWhere(before, ellipseInside({ center: { x: 0.7, y: 0.3 }, width: 0.1, height: 0.2 }), 0.3);
  const centroid = changeCentroid(before, after);
  assert.ok(Math.abs(centroid.x - 0.7) < 0.003 && Math.abs(centroid.y - 0.3) < 0.003, JSON.stringify(centroid));
  assert.equal(changeCentroid(before, before), null);
});

test("a colour's centroid ignores pixels of other colours", () => {
  const pixels = solidPixels(100, 100, 0.5);
  for (const [x, y] of [[20, 30], [21, 30], [20, 31], [21, 31]]) {
    const i = y * 100 + x;
    pixels.R[i] = 0.86;
    pixels.G[i] = 0.12;
    pixels.B[i] = 0.12;
  }
  const centroid = colorCentroid(pixels, [220, 30, 30]);
  assert.ok(Math.abs(centroid.x - 0.21) < 1e-6 && Math.abs(centroid.y - 0.31) < 1e-6, JSON.stringify(centroid));
  assert.equal(colorCentroid(pixels, [30, 60, 220]), null);
});

test("chroma is zero on grey and positive on colour", () => {
  const grey = solidPixels(10, 10, 0.4);
  assert.equal(meanChroma(grey), 0);
  grey.R.fill(0.8);
  assert.ok(Math.abs(meanChroma(grey) - 0.4) < 1e-6);
});

test("the alternation rate is 1 on a one-pixel checkerboard and 0 on a flat field", () => {
  const board = solidPixels(8, 6, 0);
  for (let y = 0; y < 6; y++) for (let x = 0; x < 8; x++) if ((x + y) % 2 === 0) board.L[y * 8 + x] = 1;
  assert.equal(alternationRate(board), 1);
  assert.equal(alternationRate(solidPixels(8, 6, 0.5)), 0);
});

test("a proof report passes only when every check passed and writes its evidence where asked", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-proof-"));
  const file = path.join(directory, "a.json");
  const log = console.log;
  const exitCode = process.exitCode;
  console.log = () => {};
  try {
    const report = createReport("detail crop", ["node", "x.mjs", "--evidence", file]);
    report.check("alternates", true, { rate: 1 });
    report.check("size", false, { width: 2 });
    const summary = report.finish({ photo: "1" });
    assert.equal(summary.passed, false);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).checks.map((entry) => entry.passed), [true, false]);
    assert.equal(process.exitCode, 1);
  } finally {
    console.log = log;
    process.exitCode = exitCode;
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("JPEG quantisation tables are read from every DQT segment", () => {
  const table = (id, value) => [id, ...Array(64).fill(value)];
  const segment = (body) => [0xff, 0xdb, (body.length + 2) >> 8, (body.length + 2) & 0xff, ...body];
  const jpeg = Buffer.from([0xff, 0xd8, ...segment(table(0, 1)), ...segment([...table(1, 2), ...table(2, 3)]), 0xff, 0xda, 0, 2, 0xff, 0xd9]);

  assert.deepEqual(jpegQuantTables(jpeg).map((values) => [values.length, values[0]]), [[64, 1], [64, 2], [64, 3]]);
});

test("the export mark is read from the photo's image attributes row", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-catalog-"));
  const catalog = path.join(directory, "t.lrcat");
  try {
    execFileSync("sqlite3", [catalog, "create table AgLibraryImageAttributes (id_local integer, image integer, lastExportTimestamp, lastPublishTimestamp); insert into AgLibraryImageAttributes values (1, 10, 0.0, 0.0), (2, 11, 816176651.5, 0.0);"]);
    assert.equal(lastExportTimestamp(catalog, 10), 0);
    assert.equal(lastExportTimestamp(catalog, 11), 816176651.5);
    assert.equal(lastExportTimestamp(catalog, 12), null);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("a held modal records whether it was still listed when the call settled", async () => {
  const failure = { title: "Export", text: "could not be written", buttons: ["OK"] };
  const other = { title: "Note", text: "unrelated", buttons: ["OK"] };
  const isTarget = (window) => window.title === "Export";
  const timing = { holdMs: 200, pollMs: 5 };
  const cases = [
    { name: "settles alone while it is open", settlesAfterMs: 20, result: "alone", pressed: [], open: true },
    { name: "closes by itself before the call settles", closesAfterMs: 20, settlesAfterMs: 60, result: "alone", pressed: [], open: false },
    { name: "a press closes it and the call settles", pressCloses: true, result: "after press", pressed: ["Export"], open: false },
    { name: "a press leaves it listed and the call settles", pressCloses: false, result: "after press", pressed: ["Export"], open: true },
  ];
  for (const scenario of cases) {
    let open = [failure, other];
    let release;
    const call = new Promise((resolve) => { release = resolve; });
    if (scenario.settlesAfterMs !== undefined) setTimeout(() => release("alone"), scenario.settlesAfterMs);
    if (scenario.closesAfterMs !== undefined) setTimeout(() => { open = open.filter((candidate) => candidate !== failure); }, scenario.closesAfterMs);
    const pressed = [];
    const press = async (window) => {
      pressed.push(window.title);
      if (scenario.pressCloses) open = open.filter((candidate) => candidate !== window);
      release("after press");
    };
    const watched = await watchModalsWhile(call, isTarget, { ...timing, list: () => open, press });
    assert.equal(watched.result, scenario.result, scenario.name);
    assert.deepEqual(pressed, scenario.pressed, scenario.name);
    const [held, unheld] = watched.modals;
    assert.deepEqual({ title: held.title, held: held.held, settled_while_open: held.settled_while_open },
      { title: "Export", held: true, settled_while_open: scenario.open }, scenario.name);
    assert.deepEqual({ title: unheld.title, held: unheld.held, pressed_at_seconds: unheld.pressed_at_seconds, settled_while_open: unheld.settled_while_open },
      { title: "Note", held: false, pressed_at_seconds: null, settled_while_open: undefined }, scenario.name);
    if (scenario.pressed.length === 0) assert.equal(held.pressed_at_seconds, null, scenario.name);
    else assert.ok(held.pressed_at_seconds >= timing.holdMs / 1000, scenario.name);
  }
});
