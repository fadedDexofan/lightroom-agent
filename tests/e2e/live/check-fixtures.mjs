#!/usr/bin/env node
import { FIXTURE_BASELINE_KEYS, fixtureBaselineProblems, isRawFixture } from "./lib/certification.mjs";
import { openLiveSession } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
try {
  const keys = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(marker.fixtures ?? {});
  const fixtures = keys.map((key) => {
    if (!marker.fixtures?.[key]) throw new Error(`fixture ${key} is not in the throwaway catalog`);
    return { key, id: String(marker.fixtures[key].id), raw: isRawFixture(marker.fixtures[key].file) };
  });
  const answer = await session.tool("get_develop_settings", {
    photo_ids: fixtures.map((f) => f.id),
    keys: FIXTURE_BASELINE_KEYS,
  });
  if (!answer.data) throw new Error(`get_develop_settings returned no data: ${answer.text}`);
  const settingsOf = new Map(
    (answer.data.photos ?? []).map((photo) => [
      String(photo.photo_id),
      Array.isArray(photo.settings) ? {} : photo.settings,
    ]),
  );
  const drifted = fixtures
    .map((f) => ({
      ...f,
      keys: settingsOf.has(f.id) ? fixtureBaselineProblems(settingsOf.get(f.id), f.raw) : ["not returned by the read"],
    }))
    .filter((f) => f.keys.length > 0);
  for (const f of drifted) console.log(`${f.key} (${f.id}) is off its baseline: ${f.keys.join(", ")}`);
  console.log(
    drifted.length
      ? `${drifted.length} of ${fixtures.length} fixtures are off their baseline; restore them before any step`
      : `all ${fixtures.length} fixtures are on their baseline`,
  );
  process.exitCode = drifted.length ? 1 : 0;
} finally {
  await session.stop();
}
