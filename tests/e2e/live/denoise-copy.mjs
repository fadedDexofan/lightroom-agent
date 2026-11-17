#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import os from "node:os";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const SOURCE_AMOUNT = 50;
const TARGET_AMOUNT = 30;
const SOURCE_EXPOSURE = 0.7;
const SETTLE_LIMIT_MS = 300_000;
const POLL_MS = 2_000;
const STABLE_POLLS = 3;
const DENOISE_WARNING = "A full copy leaves out the source's FilterList (Enhance)";

const report = createReport("a full copy leaves the target's own Denoise and warns about the source's (proof y, round 3 C2)");
const { session, marker } = await openLiveSession();
const data = async (name, args) => (await session.toolOrThrow(name, args, { timeoutMs: 300_000 })).data;
const base = String(requireFixtureId(marker, "arw_12bit"));
const freeKiB = () => Number(execFileSync("df", ["-k", os.homedir()], { encoding: "utf8" }).trim().split("\n").at(-1).split(/\s+/)[3]);
const copies = [];

const settingsOf = async (photoId) => (await data("get_develop_settings", { photo_ids: [photoId], keys: ["FilterList", "Exposure2012"] })).photos[0].settings;
const enhanceOf = (settings) => (settings.FilterList?.Filters ?? []).find((filter) => filter?.Name === "Enhance") ?? null;

async function denoised(photoId, amount) {
  const started = Date.now();
  const reply = await data("apply_denoise", { photo_ids: [photoId], amount });
  let last = null;
  let stable = 0;
  while (stable < STABLE_POLLS && Date.now() - started < SETTLE_LIMIT_MS) {
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
    const text = JSON.stringify(enhanceOf(await settingsOf(photoId)));
    stable = text !== "null" && text === last ? stable + 1 : 0;
    last = text;
  }
  return { reply, enhance: JSON.parse(last ?? "null"), settled: stable >= STABLE_POLLS, ms: Date.now() - started };
}

async function copyOf(name) {
  const copy = String((await data("create_virtual_copies", { photo_ids: [base], copy_name: name })).copies[0].copy_photo_id);
  copies.push(copy);
  if ((await data("list_masks", { photo_id: copy })).count > 0) await data("delete_masks", { photo_id: copy, all: true });
  return copy;
}

const freeBefore = freeKiB();
try {
  const source = await copyOf("LRAGENT live Denoise source");
  const target = await copyOf("LRAGENT live Denoise target");
  const plain = await copyOf("LRAGENT live Denoise plain target");
  const sourceDenoise = await denoised(source, SOURCE_AMOUNT);
  const targetDenoise = await denoised(target, TARGET_AMOUNT);
  await data("set_develop_settings", { photo_id: source, settings: { Exposure2012: SOURCE_EXPOSURE } });
  const before = { target: await settingsOf(target), plain: await settingsOf(plain) };
  report.check(`the source (Denoise ${SOURCE_AMOUNT}) and the target (Denoise ${TARGET_AMOUNT}) each hold a settled Enhance filter, and the plain target none`,
    sourceDenoise.settled && targetDenoise.settled && enhanceOf(before.target) !== null && enhanceOf(before.plain) === null
      && JSON.stringify(sourceDenoise.enhance) !== JSON.stringify(targetDenoise.enhance),
    { source: sourceDenoise, target: targetDenoise, plain_enhance: enhanceOf(before.plain) });

  const reply = await session.tool("copy_develop_settings", { source_id: source, target_ids: [target, plain] }, { timeoutMs: 300_000 });
  const after = { target: await settingsOf(target), plain: await settingsOf(plain) };
  report.check("the full copy is done for both targets, carries the source's exposure and warns that the source's Denoise is not copied",
    reply.outcome === "done" && reply.data?.copied === 2
      && after.target.Exposure2012 === SOURCE_EXPOSURE && after.plain.Exposure2012 === SOURCE_EXPOSURE
      && (reply.envelope.warnings ?? []).some((warning) => warning.includes(DENOISE_WARNING)),
    { reply: reply.envelope });
  report.check("the target keeps its own Enhance filter unchanged, and the plain target gets none",
    JSON.stringify(enhanceOf(after.target)) === JSON.stringify(enhanceOf(before.target)) && enhanceOf(after.plain) === null,
    { target: { before: enhanceOf(before.target), after: enhanceOf(after.target) }, plain: enhanceOf(after.plain) });
  report.finish({ source, target, plain, disk_used_kib: freeBefore - freeKiB() });
} finally {
  if (copies.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: copies, confirm: true });
  console.log(`free disk change after removing the copies: ${freeBefore - freeKiB()} KiB used`);
  await session.stop();
}
