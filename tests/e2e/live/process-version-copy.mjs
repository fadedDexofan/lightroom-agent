#!/usr/bin/env node
import { developHistory, pollCatalog } from "./lib/catalog-db.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const OLDER_VERSION = "Version 5";

const report = createReport("process version in a full copy (proof v, N5)");
const { session, marker, catalogPath } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 300_000 })).data;
const base = String(requireFixtureId(marker, "arw_12bit"));
const copies = [];

async function masklessCopy(name) {
  const copy = String((await data("create_virtual_copies", { photo_ids: [base], copy_name: name })).copies[0].copy_photo_id);
  copies.push(copy);
  if ((await data("list_masks", { photo_id: copy })).count > 0) await data("delete_masks", { photo_id: copy, all: true });
  return copy;
}

const processVersion = async (photoId) =>
  (await data("get_develop_settings", { photo_ids: [photoId], keys: ["ProcessVersion"] })).photos[0].settings.ProcessVersion;

try {
  const target = await masklessCopy("LRMCP live process version target");
  const downgrade = (await data("set_process_version", { photo_ids: [target], version: OLDER_VERSION, confirm: true })).results[0];
  const source = await masklessCopy("LRMCP live process version source");
  const sky = await data("create_mask", { photo_id: source, type: "sky", adjustments: { local_Exposure: -1 } });
  const before = { source: await processVersion(source), target: await processVersion(target) };
  report.check(`the target was set to ${OLDER_VERSION} and differs from the source's process version before the copy`,
    downgrade.status === "changed" && before.target !== before.source, { downgrade, before });

  const historyBefore = developHistory(catalogPath, target);
  const reply = await session.tool("copy_develop_settings", { source_id: source, target_ids: [target] }, { timeoutMs: 300_000 });
  const historyAfter = await pollCatalog(() => developHistory(catalogPath, target), () => false);
  const after = await processVersion(target);
  const masks = await data("list_masks", { photo_id: target });
  report.check("the full copy is done, the target takes the source's process version and lists the copied sky mask",
    reply.outcome === "done" && reply.data?.copied === 1 && (reply.data?.computed ?? []).map(String).includes(target)
      && after === before.source && masks.count === 1,
    { reply: reply.envelope, after, masks });
  report.check("the admission under the resulting version, the target's history steps and the source's mask are recorded", true, {
    admission: await data("get_mask_write_admission", { photo_id: target }),
    history_added: historyAfter.slice(historyBefore.length),
    source_mask: sky,
  });
  report.check("the refused half (a masked source on an uncertified process version) is recorded as not exercised", true, {
    exercised: false,
    reason: "set_process_version refuses to downgrade a photo with masks, and the kit holds no photo masked in an older Lightroom",
  });
  report.finish({ source, target, before, after });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  await session.stop();
}
