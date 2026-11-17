# Lightroom Agent

A fork of Automaat/lightroom-mcp: a broad, verifiable Lightroom Classic API for agents, served by one backend behind an MCP server and a scriptable CLI. Verified capabilities are ported selectively from znznzna/lightroom-cli.

Local, untracked facts about the owner and this machine are in `CLAUDE.local.md` when it exists; read it first.

The aim is a better tool than the existing ones, judged by the quality of the photographs an agent can produce with it and by how much of Lightroom it can drive. Those two outrank token cost, development effort and closeness to upstream.

## Ownership

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it. That includes the code inherited from upstream.

- The API is pre-release. A tool's shape, name, default or vocabulary stays only while it is the best one for the calling agent; "it was like this before" is not a reason. Update README, GLOSSARY, the ADRs and the bundled skill in the same change as the API.
- Upstream is a source of fixes to take, not a shape to stay close to.
- Outside your ownership: the user's catalog and photographs, what is installed into their Lightroom and when a live session takes it over, publication (push, release, the MIT license, upstream history) and the order of work the maintainer has set. These need the maintainer's explicit word.

## Working rules

- Preserve upstream history and the MIT license.
- Keep `AGENTS.md` a symlink to this file. Verify any behavior claim here against the current source before relying on it, and fix this file in the change that makes it stale.
- This repository holds technical API facts, contracts and mechanics. API work supplies capabilities, stable identities, render provenance and verifiable outcomes; it never silently turns an experimental score into a culling rule.
- `skills/lightroom-agent` is the bundled skill, shipped as the MCP prompt and the mcpb prompt; `npm run build` regenerates both from it. `agents/openai.yaml` is its metadata for Codex.
- CLI and MCP share tool contracts and access policy. Reuse the existing bridge and Develop session lifecycle; do not add a second Lua protocol or catalog model.
- Develop and test offline by default. Never install or reload a plug-in, restart Lightroom, switch the open catalog or change a user's photos as a side effect of development or tool discovery.
- The project `.mcp.json` starts this checkout's built server as `lightroom`. Its tools act on whatever catalog Lightroom has open; do not call them without the user's permission.
- For undocumented APIs, distinguish a discovered symbol, a callable signature, a persisted effect and a verified render. Widen a version or format guard only with evidence from that exact Lightroom version.
- Keep one mutating worker; delegate independent read-only investigation. The parent owns integration, final checks and exact staging. Do not push, release or publish without the maintainer's instruction.
- Add no source comments, docstrings or diagnostic suppressions unless explicitly required.
- Test behavior through existing boundaries. Show new behavior failing before the change and passing after it.
- Commit messages follow Conventional Commits: `<type>(<scope>): <imperative summary>`, subject at most 72 characters, no final period, body only for why.

## Commands and checks

Run from the repository root; `.mise.toml` and `server/package.json` define the tasks.

- `mise run build` (`npm run build` in `server/`): regenerates `server/src/skill-content.ts` and the prompt in `mcpb/manifest.json` from the bundled skill, runs `tsc` into `server/dist/`, then regenerates `plugin/LightroomAgent.lrplugin/Contract.lua` from the TypeScript contract. Never edit these three files by hand.
- `mise run test` (Jest), `mise run dev` (`tsc --watch`), `mise run lua:lint` (selene), `mise run lua:test` (busted), `mise run live:test` (live-kit unit tests, no Lightroom).
- `mise install` provisions Node, Lua and selene; `lua:test` installs busted into the ignored `lua_modules/`. `selene.toml` and `lightroom.yml` (the SDK globals) configure the linter.

Before committing, run after your final edit:

- in `server/`: `npm run check`, `npm run lint`, `npm run build`, `npm run test:coverage`;
- `mise run live:test` and `node scripts/bump-version.mjs --check`;
- `mise run lua:lint` and `mise run lua:test` if Lua changed.

CI (`.github/workflows/`) runs on pushes and pull requests to `main`. `ci.yml` runs the server checks on Ubuntu, macOS and Windows and the live-kit unit tests on Ubuntu and macOS, fails when the build changes a tracked generated file, and checks version consistency. The Lua workflows run on every push and pull request; `lua-test.yml` takes Lua from `.mise.toml`, pinned to 5.1.5, the version Lightroom Classic runs. A live-kit unit run never substitutes for validation in Lightroom.

## Layout

- `server/`: TypeScript MCP server and CLI (strict, ESM with NodeNext: imports carry the `.js` extension).
- `plugin/LightroomAgent.lrplugin/`: the Lua plug-in, pure Lua and the same on macOS and Windows. Specs are in `plugin/spec/`.
- `tests/e2e/live/`: the live kit. `tests/e2e/mcp-runner.mjs` drives the built server; `manual-test.mjs` probes the plug-in over raw TCP.
- `docs/adr/`: accepted decisions. `GLOSSARY.md`: the terms these documents use.

## Transport

Read before changing it.

- The plug-in opens two `LrSocket.bind` servers (`PluginInfoProvider.lua`): request port 58763 in `mode = "receive"`, response port 58764 in `mode = "send"`. Every message is line-delimited JSON ending in `\n`. Each port takes one client at a time.
- Ports: the server reads `LIGHTROOM_AGENT_REQUEST_PORT` and `LIGHTROOM_AGENT_RESPONSE_PORT` (`server/src/ports.ts`); the plug-in reads `requestPort` and `responsePort` from its Plug-in Manager prefs. Change both sides together.
- Hosts start several servers at once. `Bridge` (`bridge.ts`) elects one leader per port pair through the instance lock; it owns the plug-in sockets and serves the others over local IPC (`broker.ts`: a Unix socket under `~/.config/lightroom-agent/`, a named pipe on Windows, token checked). Followers forward and re-elect when the leader exits. Never `process.exit` on lock contention.
- A receive bind fires `onError` after 10 s without a client. Set a flag in the callback and call `:reconnect()` from the monitor loop; never reconnect synchronously from `onError`, or reconnects storm.
- `onMessage` runs in a non-yielding context, so dispatch runs inside `LrTasks.startAsyncTask`; otherwise catalog gates cannot yield.

## Catalog reads

- Run yielding catalog queries (`getTargetPhotos`, `findPhotos`, `findPhotoByPath`) outside `withReadAccessDo`. A yielding query inside the read gate deadlocks on Windows and wedges the bridge until the server timeout (upstream issues #124, #134). Only non-yielding per-photo reads belong inside; `getAllPhotos` is safe either side. Resolve photo ids before opening any gate. Specs check this with `getQueriedInsideReadAccess()` (`spec_helper.lua`).
- Each SDK getter call costs about 0.1–1 ms. Read a page of photos with `catalog:batchGetRawMetadata` / `batchGetFormattedMetadata` (`PhotoSummary`), a keyword's name and synonyms with one `getAttributes`, and avoid a `LrTasks.pcall` per item.
- Lightroom stores macOS paths in NFD and `findPhotoByPath` does not normalize. Look paths up through `PhotoLookup.findByPath` and compare them with `PathForms.same`; `PathForms.absolute` is the one path rule.
- `catalog:getPhotoByLocalId` returns a dangling photo object, not nil, for an unknown id. `PhotoLookup` keeps only photos whose batched `uuid` read is non-nil.

## Catalog writes and outcomes

The decision is [ADR 0001](docs/adr/0001-one-result-envelope.md). A call's outcome class comes from its write ledger, never from how an error was raised.

- `CatalogWrite.lua` is the only caller of `withWriteAccessDo` and the one place writes are recorded in the request's `Ledger`. Record a write where it can no longer be taken back.
- `CatalogWrite.run` opens a gate that waits `CATALOG_WRITE_WAIT_SECONDS` (generated into `Contract.lua`). It records the gate's title when the gate returns, except when the function raised, when the catalog stayed busy (Lightroom answers `"aborted"` without running the function) or when the function returns `CatalogWrite.NOTHING`.
- `CatalogWrite.call` makes an SDK write inside a gate and records it first, unless `RAISE_INSIDE_GATE` lists the method as observed rolled back by a raising gate. A method not in that table, or one observed on only some receivers, counts as kept. A raise that escapes a gate discards all its journaled writes.
- Some calls are kept despite a raising gate because they are commands, not journal entries: `addPhoto`, `applyDevelopPreset`, `deleteAllEmptyMasks`, applying or deleting a snapshot; `updateAISettings` computes outside the transaction. The table holds the observation behind each entry.
- `CatalogWrite.develop` is the only caller of a writing `LrDevelopController` function and records before the call; `CatalogWrite_spec` scans the plug-in for direct calls. `CatalogWrite.invoke` records any other write outside a gate (undo, Remove from Catalog, virtual copies, treatment, presets, export sessions, files); `createFolder` and `copyFile` record what they create.
- `Ledger:undone` voids entries only after a proving read: one of the store those writes changed, made after they can no longer land, covering everything they may have changed. A controller write lands in the saved settings later, so a Develop-side read proves nothing and such calls answer `unknown`, naming the controller writes.
- `Reply.stopped` is the one rule, for a call (`Reply.outcome`) and for each item of a loop (`Ledger:attempt`): nothing live is `failed`, anything live is `unknown` with "written before this stopped: …". A successful reply with neither data nor unknown items while entries are live carries `written` and becomes `unknown`.
- A read showing a photo's keys changed makes its item `unknown` even with an empty ledger (`DevelopReadBack`).
- Handlers state the problem (`Reply.refuse`, `Reply.notFound`) and never choose the class. A handler returns `Reply.parts{...}` or a plain table, sent as `data`. Specs assert the class with `failedOf`, `unknownOf`, `notFoundOf` and `outcomeOf` from `spec_helper.lua`.
- `server/src/tool-result.ts` derives `outcome` (`done`, `partial`, `failed`, `unknown`) from the reply parts; `isError` is set exactly when the outcome is not `done`. A lost reply is `unknown` for a sent write and `failed` for an unsent call or a read-only server.

## Develop sessions, queue and budgets

- `LrDevelopController` acts only on the photo active in Develop. Go through `DevelopSession.lua`: `withPhoto` opens one photo, runs the callback and restores module, view source and selection; `run` is the multi-photo form. A view they cannot restore becomes a reply warning.
- Photo-list Develop operations (Denoise, process version, Auto, reset, mask batches) go through `DevelopBatch.run`, which owns de-duplication, `not_found`, the time budget, cancellation, progress and each photo's outcome.
- Contracts marked `develop: "drives"` or `develop: "settings"` run one at a time in arrival order through `DevelopQueue` in the leader, shared by every client. A call that gets no turn within its budget fails without sending anything. `DevelopSession`'s single-flight refusal stops two Develop drivers interleaving when a timed-out call outlives its 60 s grace.
- A pending Develop edit overwrites a saved-settings write about 2 s later. `DevelopSession.flushIfShowing` commits pending edits before every develop-settings gate and every guarded mask write; a session that made a controller write commits it before restoring the view. An edit the user makes during the call can still be lost.
- `DevelopSession.requireControllerFunctions` is the one gate for a controller function a Lightroom version may lack. The plug-in declares Lightroom Classic 15.0 as its minimum (`Info.lua`); only `apply_denoise` checks for a function, because Denoise is outside the SDK.
- Snapshot apply and delete are Develop-module commands that do nothing elsewhere, so `HandlerSnapshots.lua` runs them inside `withPhoto`. Snapshots are stored per master: deleting one through a virtual copy deletes it for the master and every copy.
- A contract with `duration: "long"` gets the long timeout, every other tool the quick one (`TIMEOUT_MS_BY_DURATION`, decided only in `createCallToolHandler`). Each request carries `budget_ms`; handlers use `RequestContext` (`timeLeft()`, `stopping(reserveSeconds)`, cancellation, `report()`) and stop starting items when one more would not fit. No plug-in constant mirrors the server timeout.

## Develop keys

- Develop keys have one home, `server/src/develop-keys.ts`: `DEVELOP_KEYS`, `DEVELOP_RULES` and `LOCAL_KEYS`. Schemas are generated from it and the build writes it into `Contract.lua`. A key enters only with live evidence: range, write, read-back after normalisation, rendered effect.
- `set_develop_settings` runs on the server (`develop-write.ts`): it rounds to precision, checks rules against stored values and writes through the internal `write_develop_settings` action; keys another tool writes and point-curve shapes are refused by its contract rules.
- Lightroom normalises a write within about a second, and the read right after the gate only echoes the input. `DevelopReadBack.lua` reads back after that second and reports `adjusted`. A written key absent before and after is `not_stored` with a warning; one present before and absent after is `unknown`.
- Point curves, global and mask, take at most `POINT_CURVE_MAX_PAIRS` (16) points. Lightroom keeps a longer global curve only as an Extended companion that then wins over plain writes, so `DevelopCurves.lua` reads the Extended field first and writes both.
- `describe_develop_keys` is the only reader of `LrDevelopController.getRange`. Certification compares the static ranges and fails on a stale one without touching mask admission.

## Masks

Decisions: [ADR 0002](docs/adr/0002-mask-write-admission-by-certification.md) (admission by certification) and [ADR 0003](docs/adr/0003-masks-addressed-by-id-in-the-saved-settings.md) (addressing by id).

- Address masks by photo and `CorrectionID` in the saved `MaskGroupBasedCorrections`, not through Develop's selection. That setting is undocumented: write it only through `GuardedMaskWrite.lua`, never directly.
- `GuardedMaskWrite.submit` is the one whole-array write: commit pending Develop edits, build on a read taken inside the gate, write, read back with the caller's comparison, and restore on a mismatch through `GuardedMaskWrite.restore`. The restore writes the previous array back unvalidated and confirms it with an exact read.
- `GuardedMaskWrite.apply` is `submit` behind admission, for writes that construct or change entries. It checks the pinned format only on what the call constructs or changes (`plannedEntries`), compares constructed numbers within 1e-5, and requires every untouched entry back exactly: those are Lightroom's own data.
- Value edits and deletions construct nothing and need no admission. `MaskValues.lua` owns sliders, local curves and Point Color by id, with no Develop session. It skips an unchanged request, sets `CorrectionActive` (warning when a hidden mask is shown) and demands an exact read-back of the whole array (`JsonValue.differences`).
- Admission (`MaskWriteAdmission.lua`): always on a catalog whose folder holds `lragent-live-catalog.json`; elsewhere only when `~/.config/lightroom-agent/mask-certification.json` names the running build from `LrApplication.versionTable()` and the photo's process version. No build, no admission. The record does not bind the plug-in revision: rerun certification after changing the plug-in.
- Only `tests/e2e/live/certify-mask-writes.mjs` writes the record, after its suite passes on the throwaway catalog. After a Lightroom update, constructing writes stay refused until it reruns. Widening the pinned format needs a live check. `GuardedMaskWrite.formatProblems` feeds `schema_problems`; certification reads it, admission does not.
- Lightroom stores slider values to six decimals (`STORED_MASK_DECIMAL_PLACES`) and colour-grade keys as whole numbers. `LocalSliders.storedOf` rounds before the write; replies report stored values. A new local slider is one `LOCAL_KEYS` entry. The schema is the only range check on a local slider write.
- Point Color: the four edges of every range must be ordered or Lightroom drops the whole list (`MaskPointColors.requireOrderedRanges`). Deleting the last swatch or clearing removes both `LocalPointColors` and `LocalColorVariance`, since Lightroom drops empty arrays.
- `MaskSelection.lua` owns mask-list readiness: `readMasks` waits up to 5 s until Develop lists as many masks as the saved settings hold, then refuses. Selection now serves only `describe_develop_keys` live ranges and `invert_mask`. `withMaskSelected` refuses when the selection moved; `keepingSelection` is the one restore. Invert's copy waits for the saved mask, then writes by id.
- Argument laws of the gradient, range and brush tools are contract rules in `server/src/tool-contracts.ts`. `GradientGeometry.lua`, `RangeMaskGeometry.lua` and `BrushStrokes.lua` refuse only on derived or stored values. `plugin/spec/CertifiedGeometry_spec.lua` pins the stored geometry of certified inputs byte for byte.
- A colour range the plug-in constructs holds exactly one `PointModels` entry: a two-entry write crashed Lightroom and crash-looped the catalog on reopen. Lightroom-authored multi-sample ranges are resent unchanged.
- A colour range's `l a b` is Lightroom's per-photo ranking of the sampled colour, not sRGB; Lua cannot compute it. `create_range_mask` takes it verbatim or copies it with `copy_sample_from`; busted specs hold Lightroom-authored samples as ground truth.
- A depth range is refused when the read-back lacks `LuminanceDepthSampleInfo` (no device depth); Lightroom replaces a band narrower than 0.01 with its default.
- Brush Size is a screen size that changes with zoom, so only `radius` is exposed. Feather maps to stored `Radius` and `CenterWeight` through `BrushFeather.lua`. `MaskValue` 0 is an erase stroke.
- Mask geometry is stored in the stored frame; tools take and return positions in the displayed frame. `ImageFrame.lua` is the one conversion. Upright, Transform and manual distortion have no inverse, so such writes carry a warning. A crop angle combined with a non-default orientation is not yet checked live.
- `set_crop`: `HandlerCrop.plan` computes the keys, `server/src/crop.ts` writes them through the `set_develop_settings` rounding and rules, then reads them back.

## AI masks

- `createNewMask('aiSelection', 'people'|'landscape')` makes no mask because Lightroom waits for a menu pick. All AI masks (Subject, Sky, Background, People and Landscape parts) are written as seed components through `GuardedMaskWrite.apply`, then computed. Lightroom ignores written person ids and masks the first person.
- `AIMaskData.lua` lists the fields Lightroom computes per photo (digests, sizes, origin, reference point, `ErrorReason`). They are never compared or copied (`isComputed`, `withoutComputedData`), so a copied mask is recomputed for its target.
- `AIMaskCompute.run` is the only caller of `photo:updateAISettings()` and the one judgement of AI masks. It applies the optional guarded write, computes in its own gate, then polls until nothing is pending, up to `AI_MASK_COMPUTE_WAIT_SECONDS`.
- Outcomes: a compute gate never entered restores and refuses. Anything still pending at the limit is `unknown`, and nothing more is written to the photo: a write during a compute can freeze Lightroom. An own entry with a non-zero `ErrorReason` is restored and refused (`ErrorReason` 1 is "nothing found", with no modal alert).
- The call's own entries are the `CorrectionID`s new to the photo, or all of them for a full copy. Entries already failed before the call, and existing AI masks that changed, only produce warnings.
- The compute is photo-wide: it can also update Enhance, Remove areas, Lens Blur depth and an adaptive profile. After the masks are restored, the compute is voided only when the whole develop settings equal the read taken inside the mask write's gate; otherwise the call is `unknown`, naming the changed keys.
- Callers: `create_mask`, `create_mask_batch`, `combine_mask`, a full `copy_develop_settings` and `apply_develop_preset` (each photo once; for a preset, any outcome but done is `unknown` with the preset kept). A digest proves computation, not useful coverage.
- In render checks, wait for the expected change instead of trusting one early preview. On a raw, a parametric mask write re-renders the photo with texture-level differences even when neutral, so compare regional means, never single pixels.

## Other Lightroom traps

- `photo:quickDevelopSetTreatment` ignores its receiver and acts on Library's selection, which Lightroom can refuse while its command status is stale. `HandlerTreatment.lua` selects the photo alone, dispatches up to twice and answers by the read.
- Export presets (`ExportPresets.lua`) are `.lrtemplate` files parsed as literal tables, never run. A wrong-typed setting can hang the session silently, so `invalidSetting` marks it unusable.
- Each photo gets its own `LrExportSession`, so sequence numbers are continued per photo. The session ignores `size_percentage` and truncates `size_megapixels`, so both become a per-photo long edge; `longEdge` ignores width. `LR_jpeg_quality` runs 0–1.
- Parallel export sessions write nothing, so one `export_photos` runs at a time; the lock lapses 300 s after the last photo started. An "AI Updates Recommended" dialog blocks the call; each session is recorded before it starts, so a cancelled photo is `unknown`.
- Lightroom runs `LrInitPlugin` only when its window is first activated: a background launch starts no server until Lightroom comes to the front.
- Reload Plug-in does not reliably stop the old task. `PluginShutdown.lua` stops the old loop; when Lightroom skips it, the old loop exits on a foreign token (`isSuperseded`). Until then the new binds fail with `failed to open`.
- Reload Plug-in does not see a `.lua` file added after Lightroom started; the plug-in is disabled. Restart Lightroom after adding a file.
- `install-plugin`, and the stdio server at start when neither Modules nor Plugins holds the bundle, copy the plug-in into Modules. Neither replaces an installed bundle, and both refuse while a `LightroomMCP.lrplugin` is installed, because upstream's plug-in binds the same ports. Plug-in log: `~/Documents/LrClassicLogs/LightroomAgent.log`.

## Adding a tool

- Add its contract in `server/src/tool-contracts.ts` with `run: { plugin: "HandlerX.fn" }`, or `run: { server }` for a server-run tool; internal plug-in actions go in `PLUGIN_ACTIONS`. Put the handler in `plugin/LightroomAgent.lrplugin/Handler*.lua` and declare new SDK globals in `lightroom.yml`.
- Run `npm run build` to regenerate `Contract.lua`; a Jest test fails while it is stale.
- `tools/call` refuses a name with no contract, so internal actions such as `write_develop_settings` are reachable only over the raw TCP probe.

## Live kit

`tests/e2e/live/README.md` holds the bootstrap, fixtures, helpers and known traps. Its safety rules bind:

- Live runs need the user's permission and exclusive control of Lightroom; one agent writes at a time.
- The guard (`requireThrowawayCatalog()` in `lib/catalog-guard.mjs`) refuses catalogs under `~/Pictures/Lightroom`, then accepts a catalog whose folder holds `lragent-live-catalog.json` or that `LRAGENT_LIVE_THROWAWAY_CATALOG` names. It cannot recognise a personal catalog stored elsewhere: check the catalog before opting it in.
- One-shot `mcp-runner.mjs tool` calls and `node server/dist/index.js call` are not guarded.
- `mise run live:setup` switches Lightroom away from the open catalog to a new one.
- Never commit a `.lrcat` or a photo whose licence does not allow redistribution. Bundled fixtures carry their source, licence and hash in `tests/e2e/live/fixtures/SOURCES.md`.
- Back up the installed bundle outside `$TMPDIR` before installing a candidate (`install-bundle.mjs` does it) and restore it afterwards.
- A listening socket does not prove requests work: confirm with a tool call. Never force quit Lightroom or remove another process's socket.
- Make temporary collections and keywords uniquely named, delete only those, and confirm the catalog's original state afterwards.
