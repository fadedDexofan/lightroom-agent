#!/usr/bin/env node
import { isDeepStrictEqual } from "node:util";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const AI_TIMEOUT_MS = 300_000;
const SETTLE_MS = 60_000;
const POLL_MS = 1_000;
const LATE_READ_MS = 5_000;
const MASKS = "MaskGroupBasedCorrections";

const report = createReport("the whole develop settings before and after a nothing-found AI create, on a plain photo and with Lens Blur active: failed when no key outside the masks changed, unknown naming Update AI Settings and every changed key otherwise (review D-8, findings-8)");
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: AI_TIMEOUT_MS })).data;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const copies = [];

async function whole(photoId) {
  const names = (await data("get_develop_settings", { photo_ids: [photoId] })).photos[0].keys.map((entry) => entry.name);
  return (await data("get_develop_settings", { photo_ids: [photoId], keys: names })).photos[0].settings;
}

async function settled(photoId) {
  const started = Date.now();
  let previous = await whole(photoId);
  for (;;) {
    await sleep(POLL_MS);
    const current = await whole(photoId);
    if (isDeepStrictEqual(current, previous)) return { settings: current, ms: Date.now() - started };
    if (Date.now() - started >= SETTLE_MS) return { settings: current, ms: Date.now() - started, unsettled: true };
    previous = current;
  }
}

function differences(before, after) {
  return [...new Set([...Object.keys(before), ...Object.keys(after)])]
    .filter((key) => key !== MASKS && !isDeepStrictEqual(before[key], after[key]))
    .map((key) => ({ key, before: before[key] ?? null, after: after[key] ?? null }));
}

const CASES = [
  { label: "plain flat_gray", fixture: "flat_gray", prepare: async () => {} },
  { label: "arw_14bit with Lens Blur active", fixture: "arw_14bit", prepare: (photoId) => data("set_lens_blur", { photo_id: photoId, amount: 50 }) },
];

try {
  for (const { label, fixture, prepare } of CASES) {
    try {
      const copy = String((await data("create_virtual_copies", { photo_ids: [String(requireFixtureId(marker, fixture))], copy_name: `LRMCP nothing found ${label}` })).copies[0].copy_photo_id);
      copies.push(copy);
      await prepare(copy);
      const before = await settled(copy);
      const created = await session.tool("create_mask", { photo_id: copy, type: "subject" }, { timeoutMs: AI_TIMEOUT_MS });
      const after = await whole(copy);
      await sleep(LATE_READ_MS);
      const late = await whole(copy);
      const changed = differences(before.settings, after).map((entry) => entry.key);
      const error = created.envelope.error ?? "";
      const nothingFound = created.outcome !== "done" && /Lightroom found nothing/.test(error);
      const classAgrees = created.outcome === "failed" ? changed.length === 0
        : created.outcome === "unknown" && /Update AI Settings/.test(error) && changed.every((key) => error.includes(key));
      report.check(`${label}: create_mask subject answered ${created.outcome}${nothingFound ? ` (nothing found; the class ${classAgrees ? "agrees with" : "does not agree with"} the keys that differ)` : ""}; keys outside the masks that differ: ${changed.join(", ") || "none"} at once, ${differences(before.settings, late).map((entry) => entry.key).join(", ") || "none"} ${LATE_READ_MS / 1000} s later`,
        !nothingFound || classAgrees,
        { reply: created.envelope, settle: { ms: before.ms, unsettled: before.unsettled ?? false },
          differences_at_once: differences(before.settings, after), differences_late: differences(before.settings, late),
          masks: { before: before.settings[MASKS] ?? null, after: after[MASKS] ?? null }, keys_before: Object.keys(before.settings).length });
    } catch (error) {
      report.check(`${label}: not recorded, the case could not run`, false, { error: error.message });
    }
  }
  report.finish({ copies });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
