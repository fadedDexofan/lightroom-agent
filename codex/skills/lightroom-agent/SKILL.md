---
name: lightroom-agent
description: Operate Lightroom Classic through the lightroom-agent tools and make photographic decisions with them - find and cull photos, judge sharpness, develop RAWs, mask, crop, build looks and presets, export, and verify every change on Lightroom's own render. Use whenever you are about to read or change a Lightroom catalog through these tools, or when someone asks to select, critique, edit, compare, prepare or export their photographs in Lightroom, even if they do not name the tools.
---

# Lightroom agent

Write tools change edits, ratings, metadata and collections, remove photos from the catalog and export files, and Lightroom's history is shared with them.

The tool descriptions and the server instructions are the authority on what each tool does. This skill tells you how to combine them well and how to judge photographs; when the two seem to disagree, follow the tool description and say so.

## Ground rules

- **Keep a way back before any Develop change.** Make a snapshot (`create_develop_snapshot`) or a named virtual copy (`create_virtual_copies` with `copy_name`), and check that it exists. There is no batch snapshot: for many photos, snapshot the representative, run a selected-key `copy_develop_settings` with `dry_run` first and keep each target's previous values from `get_develop_settings` with those keys (follow `remaining`); a full copy can remove masks and change the process version, so give every target a snapshot or named copy first, or edit named virtual copies (up to 25 per call) and leave the masters untouched. Snapshots do not store ratings, flags, labels or metadata: note those separately if you will change them.
- **Anything that deletes, removes, overwrites or replaces the person's work needs their word for that action first.** Examples: `remove_photos_from_catalog`, `reset_develop_adjustments`, `delete_collection`, `remove_from_collection`, `delete_develop_snapshot`, `apply_develop_snapshot` (it overwrites the current edit), `delete_masks`, `delete_empty_masks`, `delete_spot`, `undo_last_step`, `set_process_version`, keyword subtree removal, a full `copy_develop_settings` (it replaces or removes the target's masks) and exports over existing files. Files on disk are never yours to delete. A request to "prepare" or "improve" photos is not permission for any of these. When the current state of every affected photo is preserved (a snapshot or a virtual copy you checked) and the person has allowed reversible edits, applying a snapshot or a full copy onto those photos needs no separate word; removal from the catalog, deletion and overwriting files always do.
- **Write within the request.** Selection is not development, development is not publication. Ratings, flags and labels carry the person's meaning: read the existing ones first and change them only as asked.
- **One writer.** Develop calls run one at a time across every client of the server; do not fire parallel writes, and do not work on a photo the person is editing at that moment.
- **Verify by reading back and looking.** A `done` reply is necessary, not sufficient: read the changed values back and look at a fresh render before you report a change. In a partial or unknown reply, items confirmed by their own read-back are real changes and may be reported after that read-back; read the others before reporting anything about them.
- **Say what you did not check.** Preview size, unverified full-resolution detail, a mask edge you did not inspect: name them.

## Before the first call

1. Check which tools the session exposes. Toolsets are fixed when the server starts (`LIGHTROOM_AGENT_TOOLSETS`: core, develop, masks or all); read-only mode (`LIGHTROOM_AGENT_READ_ONLY`) hides every write, exports and `get_photo_detail` included. If a tool is missing, check the server's toolsets, read-only mode and version before deciding it is unsupported, and tell the person.
2. Identify the actual source: a folder (`list_folders`, `get_folder_photos`), a collection (`list_collections`, `get_collection_photos`), the selection (`get_selected_photos`, which falls back to the filmstrip) or a search. Address photos by their catalog ids; paths are ambiguous with virtual copies.
3. Read what is already there: `get_photo_metadata` (ratings, flags, labels, virtual-copy and stack identity), `get_develop_settings`, `get_ai_metadata` for earlier private notes.

## Read every reply's outcome

Every tool answers `{outcome, data, error, failed, unknown, not_found, remaining, warnings}`. The class comes from what the call wrote, not from the kind of error.

| outcome | meaning | your next step |
| --- | --- | --- |
| `done` | everything asked happened and was confirmed | verify the effect as usual |
| `partial` | `data` holds what happened, the lists what did not | resend exactly `remaining`; fix and retry `failed` items; read `unknown` items first; never repeat what succeeded |
| `failed` | nothing changed (Lightroom's history may still hold the write and its undo as two steps) | read the reason, fix the cause, retry is safe |
| `unknown` | something may have been written; the error names what Lightroom reported (a lost reply carries only its error) | read the photo's current state before anything else; a blind retry duplicates |

`warnings` never change the outcome but often matter (a mask placed through Upright, a mask shown again, a key a JPEG cannot store). Details, budgets and timeouts: [tools](references/tools/tools.md#outcomes-ordering-and-time).

## Judge pictures on the right evidence

- **A preview's size is not the detail it holds.** Previews come from Lightroom's preview cache, which can answer with an enlargement of a smaller cached preview, a cropped photo most of all, without saying so (the preview tools' descriptions say the same), and every whole-frame preview is a downscale. A preview can hide a slight smear or defocus and can make a sharp frame look soft; streaks or doubled contours across the subject are strong evidence of motion, but check a neighbouring frame or a detail crop when unsure.
- **On sharpness, reject from a preview only a gross smear:** motion streaks, doubled edges, a subject blurred where the same preview holds sharper areas. A frame that only looks uniformly soft is uncertain, not rejected.
- **Everything finer comes from `get_photo_detail`:** whether a frame is critically sharp, which of two near-identical frames is sharper, and any keep that rests on sharpness. Each detail render leaves one Export history step and the exported mark on the photo (a request refused before rendering leaves neither), so ask for all regions of a photo in one call.
- **Look again after every change** on a fresh preview.

## The workflow

1. **Name the job and how it will be checked:** scope, selection or development, intended output and its size, what must stay true (skin, product colour, a building's proportions), any stop after a pass.
2. **Cull** whole frames first, then detail crops for the candidates whose verdict depends on sharpness; two separate gates, technical and editorial: [cull](references/workflow/cull.md).
3. **Develop one representative per lighting situation** in small, rendered passes before anything is copied across a set: [development](references/workflow/development.md).
4. **Mask** only where a global change cannot do the job, and check each mask on the render: [masks](references/tools/masks.md).
5. **Transfer** only what is truly shared (a look, not one photo's white balance, crop or masks), then read back and render every target.
6. **Report** per photo by filename and catalog id: decision or treatment, what changed, the trade-off, preview resolution, what was not verified, and whether you stopped at a requested pause.

## Load the reference for the branch you are on

- Any tool call beyond a simple read, an outcome you do not understand, crop, black and white, snapshots, presets, exports: [tools](references/tools/tools.md).
- Any mask: creation, AI masks, values, positions, admission: [masks](references/tools/masks.md).
- Selecting frames, judging sharpness, sequences, readiness for publication: [cull](references/workflow/cull.md).
- Developing a RAW, the closed loop of passes, copying settings across a set: [development](references/workflow/development.md).
- Composition, crop, colour and light decisions on a new set: [foundations](references/workflow/foundations.md).
- Birds and animals: [wildlife](references/genres/wildlife.md). Buildings, cities, landscapes, Upright: [architecture and landscape](references/genres/architecture-landscape.md). People, products, food: [portrait and product](references/genres/portrait-product.md).
- Looks, Color Grading, Glow, black and white, building and saving a preset: [looks and presets](references/workflow/looks.md).
- Preparing photos for a named destination, formats, export settings: [publishing](references/workflow/publishing.md).

The references carry their findings inline; their sources are provenance, not required reading. Observations marked "observed on Lightroom Classic 16.0" were made on that version and can change with Lightroom updates; recheck with `describe_develop_keys` and a render when a result surprises you.
