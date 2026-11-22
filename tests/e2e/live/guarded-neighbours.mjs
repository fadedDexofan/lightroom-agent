#!/usr/bin/env node
import { isDeepStrictEqual } from "node:util";
import { fixtureIdOrNull, openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const AI_TIMEOUT_MS = 240_000;
const LINEAR = { shape: "linear", start: { x: 0.5, y: 0.9 }, end: { x: 0.5, y: 0.7 } };
const COLOR_SAMPLE = { sample: { x: 0.048726, y: 0.060942, l: 0.570123, a: 0.961792, b: 0.817275 }, amount: 0.494949 };

const report = createReport("a guarded create beside each mask kind leaves the neighbour byte-identical");
const { session, marker } = await openLiveSession();
const answer = (name, args) => session.tool(name, args, { timeoutMs: AI_TIMEOUT_MS });
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: AI_TIMEOUT_MS })).data;
const entries = async (photoId) =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["MaskGroupBasedCorrections"] })).photos[0].settings
    .MaskGroupBasedCorrections ?? [];
const exposure = { local_Exposure: 0.3 };

const KINDS = [
  {
    kind: "Subject",
    fixture: "arw_12bit",
    make: (id) => data("create_mask", { photo_id: id, type: "subject", adjustments: exposure }),
  },
  {
    kind: "Sky",
    fixture: "arw_12bit",
    make: (id) => data("create_mask", { photo_id: id, type: "sky", adjustments: exposure }),
  },
  {
    kind: "People part",
    fixture: "people_photo",
    make: (id) => data("create_mask", { photo_id: id, type: "people", parts: ["face_skin"] }),
  },
  {
    kind: "Landscape",
    fixture: "arw_14bit",
    make: (id) => data("create_mask", { photo_id: id, type: "landscape", categories: ["sky", "vegetation"] }),
  },
  {
    kind: "gradient",
    fixture: "wide_plain",
    make: (id) =>
      data("create_gradient_mask", {
        photo_id: id,
        shape: "linear",
        start: { x: 0.5, y: 0.1 },
        end: { x: 0.5, y: 0.4 },
        adjustments: exposure,
      }),
  },
  {
    kind: "radial",
    fixture: "wide_plain",
    make: (id) =>
      data("create_gradient_mask", {
        photo_id: id,
        shape: "radial",
        center: { x: 0.3, y: 0.4 },
        width: 0.3,
        height: 0.2,
        rotation: 0,
        feather: 50,
        adjustments: exposure,
      }),
  },
  {
    kind: "brush",
    fixture: "wide_plain",
    make: (id) =>
      data("create_brush_mask", {
        photo_id: id,
        strokes: [
          {
            points: [
              { x: 0.1, y: 0.2 },
              { x: 0.4, y: 0.2 },
            ],
            radius: 0.05,
          },
        ],
        adjustments: exposure,
      }),
  },
  {
    kind: "colour range",
    fixture: "chart80",
    make: (id) =>
      data("create_range_mask", { photo_id: id, type: "color", color: COLOR_SAMPLE, adjustments: exposure }),
  },
  {
    kind: "luminance range",
    fixture: "ramp256",
    make: (id) =>
      data("create_range_mask", {
        photo_id: id,
        type: "luminance",
        luminance: { min: 0.6, max: 1 },
        adjustments: exposure,
      }),
  },
  {
    kind: "depth range",
    fixture: "depth_heic",
    make: (id) =>
      data("create_range_mask", { photo_id: id, type: "depth", depth: { min: 0, max: 0.3 }, adjustments: exposure }),
  },
  {
    kind: "combined mask",
    fixture: "arw_12bit",
    make: async (id) => {
      const gradient = await data("create_gradient_mask", {
        photo_id: id,
        shape: "linear",
        start: { x: 0.5, y: 0.1 },
        end: { x: 0.5, y: 0.4 },
        adjustments: exposure,
      });
      return data("combine_mask", {
        photo_id: id,
        mask_id: String(gradient.mask_id),
        operation: "add",
        type: "subject",
      });
    },
  },
  {
    kind: "inverted copy with adjustments",
    fixture: "wide_plain",
    make: async (id) => {
      const gradient = await data("create_gradient_mask", {
        photo_id: id,
        shape: "linear",
        start: { x: 0.5, y: 0.1 },
        end: { x: 0.5, y: 0.4 },
        adjustments: exposure,
      });
      return data("invert_mask", { photo_id: id, mask_id: String(gradient.mask_id), mode: "copy" });
    },
  },
];

const copies = [];
try {
  for (const { kind, fixture, make } of KINDS) {
    const source = fixtureIdOrNull(marker, fixture);
    if (source === null) {
      report.check(`${kind}: not exercised, the catalog has no ${fixture}`, true, { fixture });
      continue;
    }
    try {
      const copy = String(
        (
          await data("create_virtual_copies", {
            photo_ids: [String(requireFixtureId(marker, fixture))],
            copy_name: `LRAGENT neighbours ${kind}`,
          })
        ).copies[0].copy_photo_id,
      );
      copies.push(copy);
      const made = await make(copy);
      const before = await entries(copy);
      const created = await answer("create_gradient_mask", { photo_id: copy, ...LINEAR });
      const after = await entries(copy);
      const changed = before
        .filter(
          (entry) =>
            !isDeepStrictEqual(
              entry,
              after.find((candidate) => candidate.CorrectionID === entry.CorrectionID),
            ),
        )
        .map((entry) => entry.CorrectionID);
      report.check(
        `${kind}: the guarded create answered ${created.outcome}${created.envelope.error ? ` (${created.envelope.error})` : ""} and ${changed.length === 0 ? "left every neighbour byte-identical" : `changed ${changed.join(", ")}`}`,
        created.outcome === "done" && changed.length === 0 && after.length === before.length + 1,
        { made, neighbours: before.map((entry) => entry.CorrectionID), created: created.envelope, changed },
      );
    } catch (error) {
      const noDepthMap = kind === "depth range" && /found no depth map/.test(error.message);
      report.check(
        noDepthMap
          ? `${kind}: not exercised, Lightroom found no depth map in ${fixture}`
          : `${kind}: the neighbour could not be made or checked`,
        noDepthMap,
        { error: error.message },
      );
    }
  }
  report.finish({ copies });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
