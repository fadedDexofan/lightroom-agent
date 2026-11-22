# Live-test kit

Fixtures, scripts and pixel checks for testing the plug-in against a running Lightroom Classic. The mask tools need a live Lightroom, so CI cannot cover them; this kit makes a live run repeatable with the same images, the same throwaway catalog and the same checks.

Everything that needs no Lightroom (image encoders, orientation maths, manifest checks, the catalog guard, preview maths) has unit tests in `unit/`, which CI runs with `mise run live:test`.

## Requirements

- macOS. The kit drives Lightroom through Accessibility and decodes previews with `sips`. It was run on Lightroom Classic 15.6 and 16.0.
- Node.js 20 or later, `sqlite3` and `lsof` (both ship with macOS), and `mise` for the task shortcuts below.
- The Accessibility permission (System Settings → Privacy & Security → Accessibility) for the app that runs the scripts, such as your terminal. `setup-catalog.mjs`, `reopen-catalog.mjs` and the dialog helpers need it.

## What it changes on your Mac

- Lightroom's installed plug-in, replaced by `install-bundle.mjs`, with a backup in `~/.cache/lightroom-agent-live-backups/<stamp>/`.
- A new catalog in `~/Documents/lragent-live-<stamp>/`, made through File → New Catalog, which also becomes Lightroom's most recent catalog. Its photos are copies of the fixtures.
- `~/.config/lightroom-agent/mask-certification.json`, written by a certification run that passes. The plug-in reads this record to allow mask writes outside the throwaway catalog.
- Catalog snapshots in `~/.cache/lightroom-agent-live-snapshots/`, when you take them.
- Fixtures in `tests/e2e/live/.fixtures/` (ignored by Git).

## Safety rules

- The kit's scripts that write, and the writing `mcp-runner.mjs` scenarios, run only in a throwaway catalog. One-shot `mcp-runner.mjs tool` calls and `node server/dist/index.js call` check nothing: check the open catalog before writing with them. `lib/catalog-guard.mjs` reads the open catalog from Lightroom's open files (`lsof`) and refuses unless that catalog's folder holds `lragent-live-catalog.json` (written by `setup-catalog.mjs`) or `LRAGENT_LIVE_THROWAWAY_CATALOG` names the catalog. A catalog under `~/Pictures/Lightroom` is always refused.
- `setup-catalog.mjs` uses your open catalog only to reach File → New Catalog. It imports nothing until the new catalog is open and verified.
- Never commit a `.lrcat` or a photo whose licence does not allow redistribution.
- Menu clicks and keystrokes go to Lightroom only after `ensureLightroomFrontmost()` has confirmed it is in front; any app that takes focus can redirect them. Dialog buttons are pressed through their Accessibility element (`clickWindowButton`), which neither activates Lightroom nor moves the pointer.
- Do not force-quit Lightroom or remove another process's socket.
- Keep plug-in backups outside `$TMPDIR`, which macOS clears.
- Finish on your own catalog in the Library module, with ports 58763 and 58764 listening, Plug-in Manager closed and a read answering through the build that matches the restored plug-in: `node server/dist/index.js call list_collections '{"limit":1}'` from that build's checkout, or `npx -y lightroom-agent@<version> call list_collections '{"limit":1}'` for a published build. `call` installs nothing; the stdio server, which `mcp-runner.mjs` starts, replaces the installed plug-in when it takes the Lightroom connection only if that is an older version or its own build with changed files. Over a newer version or another build of the same version, the restored published bundle included, it refuses and leaves the plug-in alone.

## Setup

```sh
mise run build
mise run live:fixtures
node tests/e2e/live/install-bundle.mjs install
mise run live:setup
node tests/e2e/live/smoke.mjs
```

- `live:fixtures` generates the synthetic images, downloads the CC0 raw samples and checks every hash, including those of the two bundled photos in `fixtures/`. Set `LRAGENT_LIVE_FIXTURES_DIR` to share one fixture folder between worktrees.
- `install-bundle.mjs install [candidate-dir]` backs up the installed plug-in, installs the candidate (by default this checkout's plug-in) and compares the two with `diff -rq`. It lists Lua files the candidate adds: Reload Plug-in does not load new files, so restart Lightroom (the New Catalog relaunch in the next step does).
- `live:setup` (`setup-catalog.mjs`) needs Lightroom running. It creates the catalog, waits for the relaunch, dismisses start-up dialogs, waits for the plug-in, imports each fixture into `<catalog folder>/images/` and writes the photo ids by fixture name into `lragent-live-catalog.json`. Options: `--name`, and `--parent-dir`, which must match the folder the New Catalog dialog proposes (normally Documents).
- `smoke.mjs` checks that the kit works: the EXIF orientation of all eight orientation fixtures, `list_masks`, a linear gradient on `orient_6` (preview difference by region), a radial gradient on `wide_plain` (overlap with the expected ellipse) and the stored develop row. It removes its masks.
- `reopen-catalog.mjs <path to .lrcat>` quits Lightroom and opens it with that catalog, then confirms the catalog from the window title. Lightroom 16.0 sometimes opens its most recent catalog instead of the file it was given, so the script relaunches up to three times. Run `install-bundle.mjs restore <backup>` while Lightroom is closed, before reopening.

After the generator gains a fixture, run `mise run live:fixtures`, then `node tests/e2e/live/setup-catalog.mjs --add-missing` with the throwaway catalog open. It imports the fixtures the marker lacks or whose photo the catalog no longer holds.

If the New Catalog dialog proposes another folder, or Accessibility fails, create an empty catalog by hand, leave it open and run `node tests/e2e/live/setup-catalog.mjs --adopt-open-catalog`. It refuses a catalog under `~/Pictures/Lightroom` and any catalog that already holds photos.

## Certifying mask writes

The plug-in allows guarded mask writes (gradient, brush, range and AI masks, `combine_mask`, and full copies when the source or the target has masks) outside the throwaway catalog only after a certification run has passed for the running Lightroom version and build and the photo's process version. After a Lightroom update, run in the throwaway catalog:

```sh
node tests/e2e/live/certify-mask-writes.mjs
```

It resets the develop settings of `wide_plain`, `ramp256`, `chart80`, `orient_1`, `pano`, `arw_14bit`, `arw_12bit`, `flat_gray`, `people_photo` (required) and `depth_heic` (when present). A fixture the reset does not answer as `reset` (an unedited fixture answers `unknown`: nothing changed) is read back and must be in the certified fixture state, `fixtureStateProblems` in `lib/certification.mjs`: no masks, spots or Enhance filters, an uncropped frame, colour, no Transform, the global tone, presence and HSL sliders at 0 and white balance As Shot; otherwise, or when the read does not return the fixture, nothing is certified and the fixture and its keys are named. Then it runs these steps:

- linear and radial gradient create and update, a brush with an erase stroke, a luminance range, and a single-sample colour range on `chart80` at the l, a, b Lightroom sampled from its red patch;
- a depth range (nearest 0 to 0.3, Exposure −1) on `depth_heic`, which must darken the near table edge and leave the far background unchanged;
- a copy of develop settings with masks;
- a guarded write next to a computed Sky (below);
- Landscape, and People on a photo without a person (refused, nothing left behind);
- a sky batch over copies of `arw_12bit` and `arw_14bit`, judged on the first: the sky region (open sky at the top left) must darken by at least `min_contrast_change` (0.01) and by at least `min_contrast_ratio` (5) times the ground region (soil under a tree, away from the roof, path and metal, which Lightroom's Sky also darkens). The regions live in `REGION_RENDERS` in `lib/certification.mjs`, and `--rejudge` measures them again from the run's saved previews. Every saved run on 16.0 and 16.0.1 measures a ratio of 285 or more; a darkening of the whole frame measures about 1 and fails. A nothing-found answer for the second photo alone still passes;
- on copies of `people_photo`, whose subject fills about 70 % of the frame: Subject (the pixels it darkens become the subject region), a gradient combined with Subject by add, subtract and intersect, and Background. Each must darken at least 0.5 % of the preview, with at least 70 % of the darkened pixels inside its region, and brighten nothing;
- Subject on `flat_gray`, which must be refused as nothing found with the masks restored exactly.

The AI and combine steps each run on a fresh virtual copy, removed at the end. The steps judged by render use Exposure −1; the Landscape and nothing-found steps judge only the stored masks and write no adjustment. A step that expects a change polls its preview until its own check passes, for at most 60 s; the run file records `landed_ms`, which is null when the change never appeared. The preview is then read when two consecutive previews match and keep at least half the detail of the preview before the write (see `measureChange`).

**The guarded write next to a Sky.** On an `arw_14bit` copy that already holds a neutral linear gradient, Lightroom computes a Sky, then a second neutral gradient is created. The Sky's stored entry must stay byte-identical. Its effect must stay too: in the region the Sky darkened, and in the rest of the frame, the mean luminance may move by at most `max_region_mean_change` (0.01). The per-pixel maximum is recorded but not judged: on a raw, any parametric mask written next to an AI mask re-renders the whole photo slightly (observed on Lightroom Classic 16.0: a third of the pixels moved by more than 0.01, at most 0.08, with a mean change of −0.002). The neutral gradient comes first because the first parametric mask on a raw changes the render more (about 18 % of pixels by more than 0.01, at most 0.07).

A refusal passes when the call answered `failed`, or `unknown` naming Update AI Settings with the masks restored; the record's `refusals` says which. The run does not certify the stored scales of local sliders: the plug-in writes and checks them with the same `LOCAL_KEYS` formula, so the kit cannot observe a scale Lightroom changed. The record lists them as not exercised.

Each step reads `MaskGroupBasedCorrections` before and after, and checks the masks the step added or changed against the pinned format through `get_mask_write_admission`. A step that throws is recorded as failed and the run continues. Each step's verdict inputs go into the run file in `<catalog folder>/certification-runs/`: the answer, the raw settings before and after, the admission read, the measured numbers with the name of their check, and the previews (in `<run>-previews/`, with their SHA-256). The verdict depends only on that file and `THRESHOLDS` in `lib/certification.mjs`, so a step that missed a threshold can be judged again without Lightroom. A rejudged run whose steps all pass writes the certification record, as a live run does:

```sh
node tests/e2e/live/certify-mask-writes.mjs --rejudge <run file> --threshold <name>=<value>
```

Only a run where every step passed writes `~/.config/lightroom-agent/mask-certification.json`: the Lightroom version and build, the process versions exercised, the checks, the checks with a render comparison, what was not exercised (also depth range, when no depth photo was supplied or Lightroom found no depth map in it), the kit commit and the thresholds. A run with a failed step, or an interrupted one, leaves the previous record; stale ranges (below) do not stop the record from being written.

The same run compares the static range tables with Lightroom's: `describe_develop_keys` on `arw_12bit` for every number key of `DEVELOP_KEYS`, and on `pano` with a linear gradient selected for every local slider of `LOCAL_KEYS`. Ranges never decide admission, but a stale static range is written into the record, printed at the end and makes the command exit non-zero: correct the table before installing the build.

The run leaves the geometry steps' masks on the fixtures and exports nothing. `get_mask_write_admission` shows the result on any catalog.

## Fixtures

Generated by `generate-fixtures.mjs` (deterministic; PNG is written in JavaScript, JPEG through `sips` with the EXIF orientation added afterwards):

| Key | File | Purpose |
|---|---|---|
| `chart80` | 1000x800 PNG | 10x8 grid of 100 px patches: 72 HSV patches (12 hues x 6 saturation/value variants) and 8 greys, with known sRGB values (`chart80Patches()`). Colour range, point colours, HSL. |
| `ramp256` | 1024x1024 PNG | 16x16 patches of 64 px; patch `i` is grey level `i`. Luminance range, curves, tone. |
| `wide_plain` | 1000x600 JPEG | Flat grey 110 with slight noise, so any mask shape shows as a clean brightening that can be compared with the expected shape. |
| `pano` | 2400x240 JPEG | 10:1. Hue sweep over the top 80 %, grey ramp below. Radial width and height fractions. |
| `orient_1`..`orient_8` | 1000x600 JPEG | One asymmetric pattern (coloured corner squares and a white F) with EXIF orientation 1 to 8, so a turned or mirrored result is detectable (`expectedDisplayedCorners(n)`, `classifyOrientation`). Orientations 5 to 8 display at 600x1000. |
| `checkerboard` | 1200x800 PNG | Black and white alternating on every pixel. A 1:1 render (`get_photo_detail`) keeps the alternation (`alternationRate`); any resampling destroys it. |
| `markers_1`, `markers_6`, `markers_8` | 1500x1000 JPEG | Textured grey with red, blue and green discs at known positions (`MARKER_DISCS`), EXIF orientation 1, 6 or 8. `displayedFraction` gives where a disc shows, `colorCentroid` finds it in a preview. Masks and crops in the displayed frame. |
| `flat_gray` | 1200x800 PNG | One grey level everywhere: nothing for Subject or Sky to find. |
| `stack_1`..`stack_3` | 900x600, 600x600, 600x900 PNG | Solid red, green and blue cards for a collapsed stack (`stacks.mjs`), kept apart so hiding them hides no other fixture. |
| `batch/batch_001..200.jpg` | 1200x800 JPEG | `make-batch.mjs [count]`: crops of the 14-bit raw sample, with sky. `import-batch.mjs` imports them (about 4 minutes for 200) and stores their ids under `batch.ids` in the marker. For `create_mask_batch` and `delete_empty_masks`. |

Downloaded by `fetch-samples.mjs` from raw.pixls.us, both CC0 and pinned by hash in `manifest.json`. The downloader fetches only the URLs listed in `DOWNLOADABLE_URLS` (`lib/manifest.mjs`), and the manifest test rejects a sample that is not CC0.

| Key | File | Purpose |
|---|---|---|
| `arw_14bit` | `_DSC0009.ARW` (Sony ILCE-7M3, 6000x4000) | Raw with sky and trees: AI masks, Landscape, batch source, Denoise. |
| `arw_12bit` | `_DSC0010.ARW` | The same scene at 12 bits, for batch and multi-photo checks. |

Bundled in `fixtures/`, with their sources, licences and the Openize notice in [fixtures/SOURCES.md](fixtures/SOURCES.md). `setup-catalog.mjs` imports them by default. An environment variable points the kit at another copy instead; a file whose hash differs from the one `manifest.json` pins is reported as a mismatch and not imported, because certification's thresholds were measured on these photos.

| Key | File | Variable | Purpose |
|---|---|---|---|
| `people_photo` | `portrait_cc0.jpg` (CC0) | `LRAGENT_LIVE_PEOPLE_PHOTO` | People masks, and the Subject and combine steps of certification. |
| `depth_heic` | `iphone_portrait_photo.heic` (Openize License) | `LRAGENT_LIVE_DEPTH_HEIC` | Depth range. It has to be a real iPhone Portrait HEIC with a depth map: Lightroom ignores synthetic depth data. |

Supplied by you: `LRAGENT_LIVE_SUBJECT_PHOTO`, a photo with one clear foreground subject for Subject masks. Checks that need it are skipped without it.

Other variables: `LRAGENT_LIVE_FIXTURES_DIR`, `LRAGENT_LIVE_THROWAWAY_CATALOG`, `LIGHTROOM_AGENT_REQUEST_PORT` and `LIGHTROOM_AGENT_RESPONSE_PORT`.

## Helpers

| Module | Use |
|---|---|
| `lib/mcp.mjs` | `McpSession` starts the built server over stdio and waits for the plug-in. `tool(name, args, {timeoutMs, signal, onProgress, progressToken})` returns `{isError, text, envelope, outcome, data, image, images, ms}`. The default timeout is 120 s; pass a longer one for imports and batches. |
| `lib/live-catalog.mjs` | `openLiveSession()` runs the guard, reads the marker (photo ids by fixture name) and starts a session. `requireFixtureId(marker, key)`. |
| `lib/catalog-guard.mjs` | `requireThrowawayCatalog()`, `isRealCatalog()`. Call first in every script that writes. |
| `lib/ax.mjs` | `ensureLightroomFrontmost()`, `dismissBlockingModals()` (OK for "No X detected", decline for "Enable address lookup?"), `closePluginManager()`, `clickMenuItem()`, `openNewCatalogDialog()`, `quitLightroom()`, `reopenWithCatalog()`. |
| `lib/preview.mjs` | `measureChange(session, photoId, applyChange, options)`: reads a stable preview, applies the change, polls until the change shows (`shows(before, current)`, by default any difference; at most `settleMs`, 3.5 s by default) and reads a stable preview after. It returns `{before, after, landedMs}`, with `landedMs` null when the change never showed. Two previews are stable when `sampledMaxLuminanceDifference`, the largest luminance difference over every seventh pixel, is under 0.01. With `minDetailRatio`, the preview after must also keep that share of the earlier preview's `detailLevel` (mean luminance difference between neighbouring pixels): Lightroom can return the same soft interim render twice before the full one (observed on 16.0 at 0.09 of the detail, where finished renders of exposure masks keep 0.73 or more). Also `regionDeltas`, `bandDeltas`, `patchDeltas`, `regionMeanChanges`, and `intersectionOverUnion` with `ellipseInside` / `rectangleInside`. Previews before and after can differ in size, so everything compares by normalized position. |
| `lib/catalog-db.mjs` | Read-only queries of the open catalog with `sqlite3`. `readFlushedSettings(session, photoId, flushPhotoId, until)` opens another photo in Develop so Lightroom writes the photo's develop row, then polls until the row satisfies `until` (at most 4 s). `pollCatalog(read, until)` polls a read until `until` holds or 4 s pass; a check that something did not change reads at the end of the full 4 s. `storedMaskGroups`, `summarizeMaskGroups`, `developHistory`. |
| `lib/snapshot.mjs`, `catalog-snapshot.mjs` | `snapshot [label]` copies the throwaway catalog with its `-wal` and `-shm` files and runs `quick_check` on the copy. `restore <dir> <catalog>` needs Lightroom closed. |
| `lib/plugin-bundle.mjs`, `install-bundle.mjs` | Install and restore the plug-in, keep backups, compare with `diff -rq`, detect added Lua files. |

A check takes a few lines:

```js
const { session, marker } = await openLiveSession();
const photoId = requireFixtureId(marker, "orient_6");
const { before, after } = await measureChange(session, photoId, () => session.toolOrThrow("create_gradient_mask", {
  photo_id: String(photoId), shape: "linear", start: { x: 0.5, y: 0.1 }, end: { x: 0.5, y: 0.5 }, adjustments: { local_Exposure: 1 },
}));
const deltas = regionDeltas(before, after, [{ name: "top", x0: 0.3, y0: 0, x1: 0.7, y1: 0.08 }]);
```

## Structural proofs

Each script checks one area in the open throwaway catalog, prints a pass or FAIL line per check with its measurements and exits non-zero when a check failed. With `--evidence <file>` it writes the whole report as JSON after every check, with `started_at`, `finished_at` and `seconds`. The scripts restore what they change or work on virtual copies they remove.

- `detail-crop.mjs`: `get_photo_detail`. A region larger than `max_edge` is refused before rendering and leaves no trace; the refusal's suggested region size, sent back, renders within the limit. One successful render adds exactly one Export history step and sets the exported mark, and the reply says so (`render.source`, `left_on_photo`). A render removes render folders older than five minutes and keeps newer ones and unrelated files. The checkerboard crop alternates pixel by pixel. Render sizes match the displayed size and `get_crop` for `checkerboard`, `wide_plain`, `orient_6` and a cropped `wide_plain`, and are recorded for an angled crop, an Upright transform and the raw. The written JPEG's quantisation tables are recorded, not judged: the plug-in asks for Lightroom's top JPEG quality, and there is no reference table for it. Photo count, selection and develop settings stay unchanged, and no render folder is left.
- `crop-frames.mjs`: `set_crop` at 8° on the marker fixtures; a radial at a disc's displayed position renders within 0.002 of it; a horizontal linear gradient renders horizontal; Upright makes the write warn; a 4:5 `aspect` crop renders at 4:5 within 0.5 %; with `relative_to: "crop"` a turned aspect fit stays inside the current crop, and a turned rectangle is limited only by the photo's edges (accepted at 8°, refused at 40°).
- `treatment.mjs`: `set_treatment` to black and white and back on `arw_12bit` and `chart80`: flags, profile before and after, a grey render, the Look and its amount, whether the starting profile comes back, the selection. Also `set_develop_settings` refusing `ConvertToGrayscale`, and copying settings from a black-and-white copy to a colour one. `--with-preset` also captures a plug-in preset from the black-and-white copy; `--round-trip <id>`, `--to-black-and-white <id>` and `--to-color <id> --expect-profile <name>` split the check around a Lightroom restart.
- `edit-breadth-keys.mjs`: on a copy of `chart80`, Defringe, Remove CA, Color Grading, Glow, Upright and Projection are written and read back unadjusted, and the colour and Glow writes are visible; GrayMixer after `set_treatment`; refusals for an out-of-range value, a Defringe hue pair closer than 10, GlowStyle with Glow 0 and GrayMixer on a colour photo.
- `preview-sizes.mjs`: `get_photo_preview` sizes cull, review and 1000 arrive at 864, 1728 and 1000 px, or at the photo's own long edge when it is smaller; the same for `get_photo_previews`.
- `photo-marks.mjs`: rating, flag and colour label read back and found by `search_photos`; alt text and extended description written with `set_metadata` and returned by `get_photo_metadata`.
- `batch-preview.mjs`: `get_photo_previews` returns three previews in the order asked, each at most 2000 px and numbered by `image_index`; a reject flag, a yellow label and a private reason written on `wide_plain` read back, and its starting flag, label and reason are restored exactly.
- `snapshots.mjs`: `create_develop_snapshot` refuses a duplicate name and replaces with `replace: true`; `apply_develop_snapshot` brings back the snapshot's Exposure and leaves rating, flag, keywords, title and caption unchanged; apply and delete refuse a missing id, another photo's snapshot and an unknown photo; a deleted snapshot leaves the list, which ends as it began.
- `develop-dry-run.mjs`: a `copy_develop_settings` dry run from `arw_14bit` onto `wide_plain` and `pano` leaves their stored develop rows and History unchanged and lists exactly the copied keys; the real copy then changes exactly the listed settings, each from its `before` to its `after`. The targets' rows must first show a write made just before, which proves the catalog flush works in that session.
- `paths.mjs`: `export_photos` names files under a destination given as `/tmp/...` in that spelling; `import_photos` with `copy_to` keeps the whole file name.
- `empty-masks.mjs --empty-group <photo id>`: `delete_empty_masks` removes a mask group without components and keeps a gradient without adjustments. No tool can leave a group without components, so the photo must be prepared outside the kit by writing its saved masks directly; the script does not remove that photo.
- `delete-masks.mjs`: `delete_masks` by mask id, by one tool id of a two-component mask and by a mask's only tool id; each removes what it names and leaves every other mask byte-identical.
- `point-color-add.mjs`: `edit_mask_point_colors` add of a six-decimal source stores one swatch (the stored string is recorded) and moves only the patches near its hue; an update with unordered range edges is refused before reaching Lightroom.
- `guarded-neighbours.mjs`: next to one mask of each kind (Subject, Sky, a People part, Landscape, linear and radial gradients, brush, colour, luminance and depth ranges, a combined mask, an inverted copy), a guarded gradient create must answer done, add one mask and leave every existing mask byte-identical. A kind whose fixture is missing is recorded as not exercised.
- `ai-copy-turned.mjs`: a full `copy_develop_settings` carrying a Sky onto a photo of another size and onto a turned one. Each target computes its own Sky, with its own size fields, and renders within a mean luminance difference of 0.01 of a Sky made directly on a twin copy. When Lightroom finds no sky on the twin, the copy must stop that target as nothing found and leave its masks as they were.
- `nothing-found-settings.mjs`: compares all develop settings before and after a `create_mask subject` that finds nothing (on `flat_gray`, and on `arw_14bit` with Lens Blur on). The answer must be `failed` when nothing outside the masks changed, and otherwise `unknown`, naming Update AI Settings and every changed key.
- `ai-mask-order.mjs`: whether a full copy, which computes the target's AI masks before writing its other settings, renders a Sky differently from the same settings written first and the Sky afterwards (verdict `order_matters`, against the noise of two direct targets). Also a full copy from a source without masks: the dry run shows the target's masks going from 2 to 0, and the copy removes them and reports `masks_removed`.
- `process-version-copy.mjs`: a full copy onto a target on another process version gives the target the source's process version and its Sky mask.
- `denoise-copy.mjs`: a full copy carries the other settings and warns that it leaves out the source's Denoise; each target keeps its own Enhance result. It waits for Denoise to finish (three equal reads of `FilterList`) and records the disk space it used.
- `failed-export.mjs`: an export into a read-only folder passes the pre-checks and fails when Lightroom writes the file. The script records the reply, Lightroom's dialogs (pressing OK only on one that names the export, after 10 s), the files and the history steps and exported mark it left. A control export into a writable folder must add one Export step and set the mark.
- `people-mask.mjs`: People masks for face skin, hair, facial hair, clothes and the entire person on `people_photo`, one mask per part; Exposure on face skin brightens the forehead and on the entire person darkens the jacket, leaving the background unchanged.
- `smart-collection.mjs`: a smart collection is listed with `is_smart` true and `photo_count` 0, and `add_to_collection` into it is refused.
- `stacks.mjs`: needs `stack_1`..`stack_3` grouped into one collapsed stack by hand (Photo → Stacking → Group into Stack, then Collapse Stack; the SDK cannot stack). Checks the top's `member_photo_ids`, the refusal to remove a hidden member, the search warning naming the top, and that previews and detail renders of a hidden member show that member.

## Other checks

- `duplicate-groups.mjs`: `find_duplicate_groups` groups the two raw samples at their capture gap and leaves `wide_plain` out; ratings, flags, keywords and collections stay unchanged.
- `photo-stats.mjs [ramp id] [plain id]`: `get_photo_stats` on `ramp256` (each quarter holds 25 % of the histogram within 5 points) and `wide_plain` (mean 110 within 4, no clipping). Pass your own ramp and grey photos when the shared fixtures have edits.
- `ai-metadata.mjs write`, then `verify` after Reload Plug-in and again after a Lightroom restart, then `clear`. Keywords, title and caption must stay unchanged. The metadata provider registers a schema in the catalog, so run it only in the throwaway catalog, and restore the original plug-in with Lightroom closed before reopening your own catalog.
- `export-presets.mjs`: writes its own presets beside `User Presets` and checks numbering, size overrides and units, skipped and unwritable exports, parallel calls, malformed presets, the quality override with a file size limit, the same preset in two scopes, non-ASCII names and Windows line ends. It removes its presets and exports. By hand: when `arw_14bit`'s AI masks are outdated, "AI Updates Recommended" appears; Cancel returns the photo in `unknown`, Export writes the file.
- `folders.mjs`, after importing the batch: folder paths, fixture membership, pagination and counts.
- `lens-blur.mjs`: on its own copy of `arw_14bit`, Lens Blur off and on, amount, a visible change, persistence after switching photos, cat's eye, highlights, focal range and Ring bokeh. Lens Blur needs process version 3 or later. Only the inner near and far focal points are editable; Lightroom supplies the outer falloff.
- `style-summary.mjs`: the single-photo median on `arw_14bit`, then the time for a 200-photo summary (needs the batch).
- `remove-from-catalog.mjs`: imports three copies, checks the confirmation guards, removes two in one call and checks the catalog count, every fixture, the surviving selection and that all three files remain on disk. It asks you to select two photos in Lightroom by hand and waits for Enter. Stop if removal opens a dialog, affects only the active photo, or removes virtual copies or stack members it was not given.
- `raw-jpeg-pairs.mjs [sample.dng]`: a folder import adds a raw and keeps its same-named JPEG as a sidecar, whatever the extension's case; a stem that differs in case, and a DNG pair, import both files (observed on 15.6); importing the paired JPEG alone fails and names the raw, also from an NFD path; `separate_jpegs` adds the JPEG as its own photo; a repeated folder import counts existing files in `already_in_catalog`.
- `import-case-folders.mjs <folder>` and `import-case-files.mjs <folder>`, on a case-sensitive volume (for example `hdiutil create -size 200m -fs "Case-sensitive APFS" -type SPARSE case.sparseimage`): files and folders whose names differ only in case are refused before Lightroom imports them, because Lightroom would file them as duplicates of the first spelling. Detach and delete the image afterwards.

## MCP runner

`tests/e2e/mcp-runner.mjs` starts the built server and calls tools over stdio, as an MCP client would. It exits non-zero when a scenario fails.

```sh
node tests/e2e/mcp-runner.mjs <mode>
node tests/e2e/mcp-runner.mjs tool <name> '<json>'
node tests/e2e/mcp-runner.mjs list-tools
```

| Mode | Checks |
|---|---|
| `read` (default) | Read tools return well-formed data. Runs on any catalog. |
| `write` | Creates a collection `LRAGENT_E2E_<timestamp>`, sets a rating and a keyword and restores them. The collection is left for inspection. |
| `develop` | Writes and reads Exposure, applies a preset, copies Contrast with a `settings` list. |
| `preset-roundtrip` | Captures a plug-in preset, reads it back and exports it; a second export to the same file is refused. Output goes to `LIGHTROOM_AGENT_E2E_PRESET_DIR` (default `$TMPDIR`). |
| `export` | Exports a five-star photo (or the first photo) as a JPEG to `$TMPDIR` and checks that its long edge is at most 1024 px. |
| `pagination` | Consecutive `search_photos` pages do not overlap and report the same count. |
| `failure` | Unknown tools, unknown ids and invalid values are refused. |
| `wrong-token` | A server with a wrong token file is rejected by the plug-in. |
| `port-mismatch` | A server on other ports reports that the plug-in is not connected. |
| `all` | `read`, `write`, `develop`, `export`, `pagination` and `failure`. |

`write`, `develop`, `export`, `preset-roundtrip` and `all` refuse to run unless the open catalog is a throwaway catalog.

Checks by hand:

- **Selection.** Select three photos by hand in Lightroom's filmstrip. `get_selected_photos` must then return those three. With nothing selected, `get_selected_photos` returns the whole filmstrip, not an empty list.
- **Reload and restart.** After Reload Plug-in in Plug-in Manager, `mcp-runner.mjs read` must work again; if it reports `failed to open localhost:58763`, quit and reopen Lightroom. Stopping the runner mid-run and starting it again must reconnect within about a second, and Plug-in Manager → Show Status must show both sockets connected.
- **Preset import.** Import a preset exported with `export_develop_preset` through Lightroom's Presets panel before relying on the exported file in Lightroom.

## Manual checks

Positions are always in the frame of the rendered preview, after crop, straightening and orientation; Lightroom stores masks in the stored frame (`ImageFrame.lua`).

| Tool | Fixtures | Check |
|---|---|---|
| `set_rating_and_flag` | a copy | Rating 3 and pick read back through `get_photo_metadata`; rating 0 and flag `none` clear; an omitted field stays. |
| `get_photo_preview` with `region` | `chart80`, `orient_6` | A patch matches the same pixels of a full preview at `requested_size` within 0.03 per channel; a corner of `orient_6` matches `expectedDisplayedCorners(6)`; a malformed region fails before rendering. |
| `list_masks` | any photo with masks | Read from the saved settings without opening Develop, newest mask first; AI components carry create_mask's subtype names (people and landscape add `part`); ids work in later calls; a photo without masks gives an empty list. |
| `create_gradient_mask` linear | `orient_1`..`orient_8`, `wide_plain`, `pano` | The brightening lands on the side of the displayed start point on every orientation, and at the displayed point on a cropped and straightened copy. |
| `create_gradient_mask` radial | `wide_plain`, `orient_1`..`orient_8`, `pano` | Overlap with `ellipseInside` at 0 feather is at least 0.8; rotations 60 and −60 differ; past 45° the width and height are reported swapped with the angle turned back by 90°; `pano` stays 10:1; `area: outside` is the complement. |
| `update_gradient_mask` | as create | Only the given fields change; ids and adjustments stay. |
| `create_brush_mask`, `add_brush_strokes` | `wide_plain`, `orient_6` | The change follows the stroke in the displayed frame; radius is a fraction of the long edge; erase strokes remove paint. |
| `create_range_mask` luminance | `ramp256` | Full change inside `[min, max]`, none outside, a linear falloff; a band narrower than 0.01 is refused. |
| `create_range_mask` colour | `chart80` | Selection follows Lightroom's l, a, b sample, not sRGB: take it from a range made in Lightroom (`list_masks`) or use `copy_sample_from`. Use exactly one sample: two crash Lightroom (below). |
| `create_range_mask` depth | `depth_heic` | Near and far regions of the depth map; a photo without depth fails and stays unchanged. |
| `create_mask` subject, sky, background | `arw_14bit`, `arw_12bit`, `subject_photo` | The Sky covers the sky in the preview; created without opening Develop or raising a dialog; nothing found removes the new entry. |
| `create_mask_batch` | `batch.ids` | At most 200 photos per call; a call stops starting photos when one more would not fit its time budget and lists the unattempted ones in `remaining` (`partial` when some photos succeeded, `failed` when none did, `unknown` when any attempted photo is unknown); a photo where nothing is found fails and the batch continues. |
| `create_mask` people, landscape | `people_photo`, `arw_14bit` | One mask per part or category, on the right region. |
| `invert_mask` | `wide_plain` | The change is the shape's complement; inverting twice restores it. |
| `set_mask_adjustments`, `get_mask` | `wide_plain`, `ramp256` | The preview settles about 3.5 s after the call (use `measureChange`); `local_Exposure` +2 is stored as `LocalExposure2012 = 0.5`. |
| `set_mask_curves`, `edit_mask_point_colors` | `ramp256`, `chart80` | Grey levels follow the curve; a point colour moves nearby patches only; both read back through `get_mask`. |
| `get_mask` without `kinds` | a copy | Returns adjustments, curves and point colours as written; reads the saved settings without opening Develop. |
| `delete_masks`, `delete_empty_masks` | any, `batch.ids` | Exactly one selector; the photo stays; empty masks go, others stay, without opening Develop. |
| `set_crop` | `orient_1`, `orient_6`, `orient_8`, `markers_1` | A 4:5 frame renders with the target where asked; a frame leaving the photo is refused with the largest frame that fits. |
| `list_spots`, `update_spot`, `delete_spot` | a copy with two Heal spots made by hand | Set `Opacity` 0.6 on spot 1 and switch photos: both `Opacity` and `opacity` read 0.6 and spot 2 is unchanged. Delete spot 1 and check the count; an index out of range changes nothing. The plug-in sends the full parameter table and changes only `Opacity`: on 15.6 a partial table cleared both spots, and a change to lowercase `opacity` reverted after switching photos. |

## Known traps

- Lightroom starts the plug-in only when its window first comes to the front; after a relaunch behind another app, no server starts. `setup-catalog.mjs` and `ensureLightroomFrontmost()` bring it forward.
- After a launch, the "Enable address lookup?" dialog blocks the window; run `dismissBlockingModals()`.
- The preview tools take no thumbnail of the photo open in Develop: they fail at once, naming `render_photo`, which renders it by an export and adds an Export history step to the photo. Take preview checks of an edited photo in Library, or call `render_photo` knowing its trace; pixel checks go through `measureChange`.
- A photo's develop row in the catalog lags until another photo is opened, and the Develop panel can show a change Lightroom never saves: verify through history or `readFlushedSettings`.
- Develop zoom changes between photos; use View → Toggle Zoom View for Fit before pixel work.
- Reload Plug-in does not load an added `.lua` file; restart Lightroom. When `mise run plugin:reload` cannot close Plug-in Manager, its window blocks clicks: `closePluginManager()`.
- After switching catalogs the plug-in can drop its sockets after the 10 s no-client timeout: Plug-in Manager → Stop Server → Start Server.
- Imports take about 1.2 s per small JPEG; give import calls a long `timeoutMs`.
- A colour range with two sample points crashes Lightroom and crash-loops the catalog. Quit Lightroom normally and restore a snapshot (`catalog-snapshot.mjs snapshot <label>` before any test that writes masks you cannot delete).
- A hung import can leave Lightroom waiting on `withWriteAccessDo ... blocked by another write access call` until a normal quit.
