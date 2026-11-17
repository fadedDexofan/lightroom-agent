# Lightroom MCP Integration

## Server capabilities

Upstream repository: `https://github.com/Automaat/lightroom-mcp`

Detect available tools at runtime because main can differ from the installed release. Enable `LIGHTROOM_MCP_TOOLSETS=develop` in the MCP server environment for this workflow, or `develop,masks` for local masks (`all` enables both). In the desktop bundle, set **Enabled toolsets**. Restart the server after changing the setting; the default exposes only core catalog and metadata tools.

## Why it helps

The integration adds the missing feedback loop:

- `get_selected_photos`: identify representatives selected in Lightroom.
- `get_photo_metadata`: read EXIF for 1 to 100 `photo_ids`. Results contain `photos` in request order and `not_found` identifiers; repeated identifiers return repeated entries.
- `get_develop_settings`: read Develop values by the SDK names `set_develop_settings` writes, for 1 to 100 `photo_ids` with `keys`.
- `get_photo_preview`: inspect a Lightroom-rendered preview without exporting a file.
- `set_develop_settings`: apply bounded global/HSL/detail settings.
- `create_develop_snapshot`, `list_develop_snapshots`, `apply_develop_snapshot`, and `delete_develop_snapshot`: save and restore a photo's Develop state and manage its snapshots.
- `export_photos`: render the actual Lightroom result for visual comparison.
- `copy_develop_settings`: apply an approved subset to a cluster.
- `get_develop_preset`: read exact historical preset settings.
- `compare_develop_presets`: diff an approved look and a versioned candidate.
- `create_develop_preset`: capture explicit settings from a representative as a plugin-managed checkpoint.
- `export_develop_preset`: copy an exportable backing file without overwriting.
- `apply_denoise`: apply AI Denoise on Lightroom Classic 15+.
- `list_masks`, `create_mask`, `create_mask_batch`, `combine_mask`, `invert_mask`, `delete_masks` and `delete_empty_masks`: inspect and manage local masks. Call `delete_empty_masks` with `photo_ids` to remove empty masks in bulk without opening Develop; call `delete_masks` with `photo_id` and exactly one of `mask_ids`, `tool_ids` or `all` for targeted deletion.
- `create_gradient_mask`, `update_gradient_mask`, `create_brush_mask`, `add_brush_strokes`, `create_range_mask`, `create_mask` with `type: "people"` or `type: "landscape"`: create or edit mask geometry and AI parts on supported Lightroom versions.
- `get_mask`, `set_mask_adjustments`, `set_mask_curves`, and `edit_mask_point_colors`: read and adjust a mask's local sliders, curves, and Point Color. `get_mask` reads all three in one call, from the saved settings; pass `kinds: ["adjustments"]`, `["curves"]` or `["point_colors"]` to read only selected kinds.

This improves setting selection. It does not by itself create a canonical preset XMP.

## Current gaps

- Export returns the written file path for each exported photo in `files`; inspect those files, not the folder.
- `create_virtual_copies` and `reset_develop_adjustments` need the develop toolset. `reset_develop_adjustments` removes all Develop edits, including crop and masks. `undo_last_step` undoes one shared history step that may belong to the user or another plug-in.
- Adobe's SDK creates plugin-managed presets that are hidden from the Develop panel. Use versioned names and export/import the accepted file, or create a visible canonical preset through Lightroom's UI.
- A preset can be exported only when Lightroom exposes a backing file. Built-in presets can lack one, and the backing format is determined by Lightroom.
- Global develop settings do not expose Profile, Calibration, or global Point Color. Local Point Color is available through the mask tools above.
- `set_develop_settings` publishes each key's range in its schema and refuses an out-of-range value before writing; after the write it reads the values back and lists any Lightroom stored differently as `adjusted`.
- `copy_develop_settings` without an explicit field list copies the full source settings. Always provide the intended field list for cluster work.

## Safe closed-loop sequence

1. Require Lightroom Classic to be open and the Lightroom MCP plugin server to report connected sockets.
2. Use a user-selected representative or an explicitly approved test photo.
3. Capture metadata/develop settings and export baseline.
4. Read the approved historical preset when one exists.
5. Change only the current pass's keys with bounded values.
6. Re-read settings and export to a new empty folder.
7. Inspect before/after. Create a uniquely versioned plugin checkpoint only for explicit intended fields.
8. Compare the candidate checkpoint against the approved historical preset and record the diff.
9. Continue, revert by applying recorded values when possible, or stop for manual Lightroom work.
10. Export the accepted checkpoint to a new filename, import/round-trip it in Lightroom, then copy an approved subset only after user approval.

Do not use this route on a master edit when the baseline cannot be restored with the available tool subset.

## Preset creation decision

- Best with Lightroom MCP: create a versioned plugin checkpoint from explicit intended fields, compare it to the approved look, export it, then import/round-trip it in Lightroom.
- Best for a visible Develop-panel preset: use Lightroom's Create Preset UI from the accepted representative and select only intended fields.
- Acceptable fallback: use `generate_xmp_preset.py` for supported global settings, then import and visually validate it in Lightroom.
- Not acceptable: wrap the old one-shot XMP generator in MCP and call that a closed loop.

## Installation boundary

This is an optional local dependency. Do not install packages, edit Codex MCP configuration, or install a Lightroom plugin unless the user requests that setup. A newly configured MCP server normally requires restarting the local Codex client before its tools become available in a new task.
