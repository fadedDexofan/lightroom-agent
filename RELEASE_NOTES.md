# lightroom-agent 0.1.0-rc.1

The second release candidate of lightroom-agent, a fork of [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) at 1709e40, for testing the installs before 0.1.0.

**Install**

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`.
- Codex: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`.
- Claude Desktop: open the `.mcpb` attached to this release.
- Any MCP client: `npx -y lightroom-agent@0.1.0-rc.1` over stdio.
- From a checkout: after pulling, run `npm --prefix server run build`, restart every client, then restart Lightroom.

The server that holds the Lightroom connection installs the plug-in when it starts, or `install-plugin` does with every client quit: then restart Lightroom Classic and bring its window to the front; the plug-in starts its server. Needs Lightroom Classic 15.0 or later (checked on 15.6 and 16.0) on macOS.

**Known issue**

In `codex exec`, Codex does not yet offer the plugin's tools to the model, although the server starts; under investigation.

**Changes against upstream** (the design decisions behind them are in [docs/adr](https://github.com/fadedDexofan/lightroom-agent/tree/main/docs/adr))

- Every tool answers in one result envelope: `done`, `partial`, `failed` or `unknown`, decided by a per-call ledger of what the plug-in wrote, so `failed` always means nothing changed.
- Masks are listed, adjusted and deleted by id in the photo's saved settings, without opening Develop or depending on the selected mask; `invert_mask` still works in Develop. Constructing writes name the masks they add, so the ids they return work in the next call. While a mask on the photo has no id yet, value edits, `delete_masks` and constructing writes on that photo refuse and ask to call again.
- Subject, Sky, Background, People and Landscape masks and `combine_mask` components are written for Lightroom to compute and judged on the photo afterwards; a mask Lightroom finds nothing for is removed.
- Writes that construct masks are admitted by a per-machine certification of the running Lightroom build and the photo's process version; the live kit's throwaway catalog needs none.
- Develop writes are read back after Lightroom normalises them; a value stored differently is reported in `adjusted`. Slider changes pending in Develop are committed before a call reads or writes anything. `apply_auto_adjustments` returns once the saved values settle; `reset_develop_adjustments` returns without a read-back.
- The server checks that the Lightroom plug-in comes from its own build, and two clients sharing one Lightroom check each other's build. A server whose build does not match its plug-in folder refuses until it is rebuilt or reinstalled. The plug-in is installed by the server that holds the Lightroom connection or by `install-plugin` while no client runs, replacing an installed copy whose files differ.
- One repository installs as a plugin in Claude Code and Codex, and per their documentation in Cursor, Copilot CLI, Kiro and Goose; the npm package carries the plug-in and the bundled skill `lightroom-agent`, which teaches an agent to cull, develop, mask and export with these tools.
- A command line runs any tool: `tools`, `call <tool> [json]` and `install-plugin`.
- The plug-in, its folder, environment variables and configuration directory are named lightroom-agent (`LightroomAgent.lrplugin`, `LIGHTROOM_AGENT_*`, `~/.config/lightroom-agent/`); remove an installed `LightroomMCP.lrplugin` first.
- Lightroom Classic 15.0 is the minimum.

# Upstream history

The notes below are Automaat/lightroom-mcp's, unchanged up to 1709e40, with its per-change notes in `docs/release-notes/`. They describe upstream's behaviour, which this fork has changed in the ways listed above.

# Unreleased

- All advertised tools now publish Claude Code-compatible root schemas. Cross-field selector rules remain enforced before dispatch, and nested schema constraints are unchanged.
- `delete_empty_masks` is removed. Use `delete_masks` with only `photo_ids` to delete empty masks on up to 1000 photos (LrC 14+), preserving module and selection. Existing `photo_id` calls with `mask_ids`, `tool_ids` or `all` keep their behavior (LrC 11+). The two forms cannot be mixed; each retains its result fields.
- The default tool list now contains only core catalog and metadata tools. Enable `LIGHTROOM_MCP_TOOLSETS=develop`, `masks`, `develop,masks`, or `all` in your MCP server environment to restore Develop or mask tools after upgrading. Desktop bundle users can set **Enabled toolsets**. Core is always enabled. Restart the server to apply a change; hidden tools are also refused when called. Develop includes `create_virtual_copies` and `summarize_develop_settings`.

- `create_people_mask` and `create_landscape_mask` are removed. Use `create_mask` with `type: "people", parts: ["hair"]` or `type: "landscape", categories: ["sky"]`. Results retain `mask_id` and the per-part/category `masks` list. People/Landscape keep their guarded LrC 15.6 / process 15.4 requirement and reject `adjustments`; set sliders afterwards with `set_mask_adjustments`. Subject/Sky/Background calls and their adjustments remain unchanged.
- `get_mask` replaces `get_mask_adjustments`, `get_mask_curves` and `get_mask_point_colors`. Pass `photo_id` and `mask_id`; omit `kinds` to read all three in one Develop session, or select `adjustments`, `curves` and/or `point_colors`. Results contain `adjustments`, `curves`, `swatches` and per-kind `unavailable`; unsupported/unreadable kinds appear in `errors`, and a request with no readable kind fails. The set tools are unchanged.
- Write results omit request echoes and count-only messages while retaining counts, IDs, readbacks and actionable warnings. See [the changed tools and fields](docs/release-notes/360-write-results.md).
- `set_rating` and `set_flag` are replaced by `set_rating_and_flag`. Pass `photo_ids` and `rating`, `flag`, or both; both fields are saved in one write. Rating `0` clears stars and flag `"none"` clears the pick flag. Omitted fields stay unchanged. Results contain `success`, `updated` and `missing`.
- `set_rating_and_flag`, `get_photo_metadata` and the three mask creation tools publish plain object schemas for Claude Code. Rating-or-flag, exclusive single/batch photo selectors and the mask-id/creation-adjustments exclusion are enforced before dispatch; handlers, sections, geometry, sliders and results are unchanged.
- Readiness failures now return one short line with the cause and next action. Full port diagnoses remain in stderr logs.
- Invalid photo IDs now produce one type-validation clause. Handler errors omit the leading Lua source position; error conditions and accepted ID values are unchanged.

- `search_photos`, `get_selected_photos`, and `get_collection_photos` now omit `path` from default rows. Pass `include_path: true` to include it. Rows retain `id`, `filename`, `rating`, and `dateTimeOriginal`; use `id` with metadata and write tools. Photo IDs and file paths remain accepted as selectors. Pagination is unchanged.
- `list_collections` now omits `parent`. Its `name` remains the full collection path, such as `Trips / 2026 / Paris`, accepted as `collection_name` by collection tools.
- Shared Develop, guarded-mask and coordinate guidance now arrives once through MCP server instructions. Tool descriptions are shorter; tool schemas and results are unchanged.
- `list_develop_presets` now returns up to 100 presets by default. Use `limit` and `offset` to page through matches until `has_more` is false. `count` is the total after filtering, including when `limit` is 0.
- Narrow preset discovery with `query` (case-insensitive name substring) and `folder` (exact, case-sensitive folder name). Use `Plugin Develop Presets` for plugin checkpoints.
- Preset list rows now contain only `name`, `folder`, `scope` and `uuid`. Use `get_develop_preset` with `preset_uuid` to retrieve `file`. Other preset tool results and selectors are unchanged.
