# lightroom-agent 0.2.1

A maintenance release. A tool call made while the server is still connecting to the plug-in no longer fails at once when the plug-in's first connection drops: it waits for the reconnect while the connect wait lasts. And the plug-in now takes its tables from the server instead of keeping its own copies. The tools are the same 83 as in 0.2.0.

## Install

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex CLI: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`; to update, `codex plugin marketplace upgrade lightroom-agent`, then start a new session.
- Claude Desktop: open the `.mcpb` attached to this release; to update, open a newer release's `.mcpb`.
- Any MCP client: `npx -y lightroom-agent@0.2.1` over stdio. The default toolset, `core`, leaves out the develop and mask tools; set `LIGHTROOM_AGENT_TOOLSETS=all` to load every tool.
- From a checkout: run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients.

After updating, restart every client, then restart Lightroom Classic and bring its window to the front once. The plug-in has a new file, and Reload Plug-in does not load files added after Lightroom started.

## Fixes

- **A call made during the connect no longer fails on a dropped first connection.** A call polls up to 3 s for the plug-in's connection. The plug-in's first check then has its own 5 s, and a diagnosis of the ports can add a wait after that. When the connection dropped before the plug-in answered that first check, the call was refused with "Lightroom plugin not connected" at once, with most of the 3 s left. It now polls for the reconnect with whatever remains of the 3 s, and a reconnect in time gets a new check with its own 5 s. This is one race that produces the intermittent failure seen in the CLI tests; the cause of the reported failure itself was never observed.
- **The plug-in takes its tables from the server.** The process versions, the Point Color format and its eight-swatch limit, the default ports and the 1000-photo limit of `export_photo_metadata` on the selection now reach the plug-in only through the generated contract. The values have not changed. The default ports in the Claude Desktop bundle and the MCP registry entry are generated from the same place, so the bundle can no longer override the server's default with a stale one.
- The descriptions of `set_process_version` and `edit_mask_point_colors` were reworded: the first no longer repeats the version list its schema gives, and the second states the swatch limit as a count.

## For contributors

- The server tests run on Vitest 5 with v8 coverage instead of Jest and ts-jest. The test transform no longer type-checks each file; `npm run check` remains the type check of the sources and the tests. TypeScript 7 is the only TypeScript left in the dev dependencies. Coverage is enforced over the same 50 source files; the floors are 95% statements, 89% branches, 90% functions and 95% lines, with `src/index.ts` apart.
- The plug-in's server loop takes its restart, takeover and log-throttling decisions from a new module, `PluginServerPolicy.lua`, and `PluginInfoProvider.lua` exports only what Lightroom and the plug-in's own scripts call.

## Known issues

The known issues of 0.2.0 still apply.

# lightroom-agent 0.2.0

This release adds `set_profile` for a raw photo's base profile, makes `copy_develop_settings` copy the profile the way Lightroom does, and names the photos every tool acts on `photo_ids`. It ships 83 tools.

## Install

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex CLI: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`; to update, `codex plugin marketplace upgrade lightroom-agent`, then start a new session.
- Claude Desktop: open the `.mcpb` attached to this release; to update, open a newer release's `.mcpb`.
- Any MCP client: `npx -y lightroom-agent@0.2.0` over stdio. The default toolset, `core`, leaves out the develop and mask tools; set `LIGHTROOM_AGENT_TOOLSETS=all` to load every tool.
- From a checkout: run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients.

After updating, restart every client, then Lightroom Classic, and bring the Lightroom window to the front once; Lightroom picks up the new profile presets only when it starts.

## Breaking

- **Photos are passed as `photo_ids`,** an array of photo IDs or absolute paths. A single-photo tool takes exactly one; `get_mask_write_admission` takes an optional one. The old names are refused before anything reaches Lightroom, and the refusal names the new one:

  | old | new |
  |---|---|
  | `photo_id` (32 single-photo tools) | `photo_ids: [id]` |
  | `copy_develop_settings` `source_id`, `target_ids` | `source_photo_id`, `photo_ids` |
  | `match_photo_style` `reference_id`, `target_ids` | `reference_photo_id`, `photo_ids` |
  | `create_range_mask` `copy_sample_from.photo_id` | `copy_sample_from.source_photo_id` |

  Unchanged: `set_develop_settings_batch`'s `photos[].photo_id` and every reply field (`photo_id` per item, `match_photo_style`'s `reference_id`). A single-photo tool given several photos is refused and pointed to its plural tool where one exists: `get_photo_previews`, `set_develop_settings_batch`, and `create_mask_batch` for Subject, Sky and Background.

## New

- **`set_profile`** sets a colour raw photo's profile by name, Adobe Color or Adobe Landscape, in one history step: it applies one of the two presets below, so Lightroom fits the profile to the photo's camera. It refuses a photo that is not raw, a black and white raw (convert it with `set_treatment` first) and one on an Adaptive profile. With `amount` (0–200, 100 as the profile was made) it sets the strength of the creative profile a photo already has, such as Artistic, Modern or Vintage, and refuses a profile without an amount, such as the Adobe Raw ones, and an Adaptive profile. About 2 s after the write it reads the photo back and answers `unknown`, naming the difference, when the stored profile is not the one requested or anything outside the profile changed. Profile keys in `settings` (`CameraProfile`, `Look`, `ProfileAmount`) are still refused; the refusal now points to `set_profile`, or to `"profile"` in `copy_develop_settings`.
- **Two profile presets.** Each install (the one the server makes when it starts, and `install-plugin`) writes two Develop presets that hold only a profile, "lightroom-agent Adobe Color" and "lightroom-agent Adobe Landscape", into Camera Raw's settings folder (`~/Library/Application Support/Adobe/CameraRaw/Settings` on macOS, `%APPDATA%\Adobe\CameraRaw\Settings` on Windows), in the group "lightroom-agent profiles". They live outside the catalog and show in Lightroom's Presets panel and in Camera Raw. Each install restores a preset of its own that was changed or deleted, and leaves alone a file of the same name it did not write; `set_profile` then refuses that profile. `install-plugin` reports each preset it wrote or left alone, and exits non-zero when one is not in place. To uninstall, delete the two files by hand.
- **The profile copies as one unit.** `copy_develop_settings` takes `"profile"` in `settings`, and a full copy includes it. Each target gets it through Lightroom's own Copy Settings and Paste Settings, so Lightroom applies it to that photo as it would itself; this overwrites Lightroom's Develop clipboard, and the reply warns when it did. The profile is left, with the reason in `profiles_left`, between a raw and a non-raw photo, between raw photos of different camera models, from or onto an Adaptive profile, across colour and black and white, for a DNG, when the profile is made for another camera, and when a photo's file type or camera model is unknown. A copy of the profile alone lists a target already on the source's profile in `unchanged`. A dry run counts the profile change and lists the profiles it would leave.
- **Render advice for the photo open in Develop.** The preview tools still refuse that photo, whose Lightroom thumbnail can be stale. Their refusal and `render_photo` now advise one render before editing and one after, not one per step, since each render adds an Export history step.

## Fixes

- A full `copy_develop_settings` no longer writes the source's `Look` and `CameraProfile` as plain settings, which left parts of the target's old profile behind.
- `copy_develop_settings` reads each target back at the end and answers `unknown`, naming the settings, when a setting it did not write changed, apart from companion keys Lightroom derives from a written key, or when Lightroom's Update AI Settings, run to compute copied AI masks, refreshed other settings such as the Enhance filters. A named setting the source does not have is no longer skipped silently: named alone, it refuses the call; beside others, the call is partial and names it.
- Mask certification fails when the server itself refuses a call's arguments or tool name, instead of recording that as the refusal it expected from Lightroom.

## Known issues

- `set_profile` sets only Adobe Color and Adobe Landscape by name; the other Adobe Raw profiles, such as Adobe Neutral, Adobe Portrait and Adobe Vivid, cannot be set yet.
- A DNG's profile is neither set by name nor copied, because the tools do not tell whether a DNG holds raw data.
- An Adaptive preset whose AI mask Lightroom finds nothing for (no teeth on a closed-mouth portrait, say) answers `unknown` for that photo, though the preset was applied and its other masks computed.
- The first reset after Lightroom starts can come back `unknown` with nothing changed, most often right after a read of that photo's settings; read the photo and call again.
- Windows is not tested against Lightroom: the server builds and passes CI there, but nobody has run it with Lightroom on Windows, so the profile presets' Windows folder is unverified too.

# lightroom-agent 0.1.0

The first release of lightroom-agent: an MCP server and a Lightroom Classic plug-in that let an AI agent cull, develop, mask and export your photos, and check every change on Lightroom's own render. It ships 82 tools and a bundled skill, `lightroom-agent`, that teaches an agent to work with them.

## Install

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex CLI: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`; to update, `codex plugin marketplace upgrade lightroom-agent`, then start a new session.
- Claude Desktop: open the `.mcpb` attached to this release; to update, open a newer release's `.mcpb`.
- Any MCP client: `npx -y lightroom-agent@0.1.0` over stdio. The default toolset, `core`, leaves out the develop and mask tools; set `LIGHTROOM_AGENT_TOOLSETS=all` to load every tool.
- From a checkout: run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients.

After installing or updating, restart every client, then Lightroom Classic, and bring the Lightroom window to the front once. The server holding the Lightroom connection installs the matching plug-in when it starts, and Lightroom loads plug-ins only when its window is first activated.

## Requirements

- Lightroom Classic 15.0 or later, tested on Lightroom Classic 16.0.1 on macOS. Lightroom (the cloud app) is not supported.
- Node.js 20 or later.
- `LightroomAgent.lrplugin` cannot run next to `LightroomMCP.lrplugin`, because both use the same ports; remove `LightroomMCP.lrplugin` first if it is installed.

## What an agent can do

- **Find and organise photos.** Search by rating, date, camera, lens, ISO, focal length, keyword, folder, flag, colour label, edited state and file type; set ratings, flags, colour labels, keywords, metadata, GPS and location; build regular and smart collections; import, make virtual copies, and remove photos from the catalog (the files stay on disk). The agent can also keep its own score (0–100) and reason for each photo in private plug-in data, which is not written to IPTC, XMP, keywords or exported files.
- **Look at photos.** Previews of any photo, whole or a region, at a chosen size, except the photo open in Develop, whose Lightroom thumbnail can be out of date. `render_photo` renders any photo, that one included, through a temporary export at a chosen long edge. `get_photo_detail` cuts 1:1 crops from a full-resolution render, so sharpness is judged on full-resolution pixels rather than a scaled preview. Both add one Export history step to the photo and mark it as exported.
- **Develop.** 131 Develop settings, named as in the Lightroom SDK (`Exposure2012`, `ShadowTint`), including calibration, perspective offsets, lens and post-crop vignetting, and the tone curve's saturation refinement. Before anything is written, each value is checked against its range and against the rules that link settings to the photo's current ones. Every write is then read back, and any value Lightroom stored differently from the request is reported. `set_develop_settings_batch` gives up to 50 photos their own settings in one call. Crop and straighten in the frame the agent sees, switch between colour and black and white, set the process version (the version of Lightroom's processing engine a photo is edited with), run Auto, Denoise and Lens Blur, copy settings between photos, match one photo's look on others, and keep earlier edits recoverable with snapshots and named virtual copies. A reset reports `reset` only when a read afterwards shows the photo's edits changed; otherwise it reports `unknown`, because an unedited photo reads the same before and after.
- **Presets.** List presets, with a query that matches every word in a preset's folder or name, so `sky` finds Lightroom's built-in Adaptive: Sky group; read and compare them; apply one by the id the list returns or by name; save settings as versioned plug-in presets and export them. When a preset contains AI masks, Lightroom computes them for each photo, and the call waits up to 30 s per photo.
- **Mask.** Subject, Sky, Background, People parts and Landscape masks; linear and radial gradients, brushes, colour, luminance and depth ranges; per-mask sliders, curves and Point Color. Every mask write is read back from the photo's saved settings. If Lightroom finds nothing for an AI mask, the empty mask is removed and the call says so. Creating a mask works only after a test run (certification) has passed on your Mac for the installed Lightroom build and the photo's process version; rerun it after each Lightroom update. Editing or deleting existing masks works without it.
- **Export.** To a folder or through an export preset; the reply lists the files written.

## How it works

- Every call ends with one of four statuses, set by what the plug-in wrote: `done`, `partial`, `failed` or `unknown`. `failed` means nothing changed; `unknown` names what may have changed, so read the photo before calling again.
- Calls that open Develop or read or write develop settings run one at a time, in the order they arrive, across all clients; catalog reads, previews and other catalog writes run alongside them. One export or detail render runs at a time, and a second is refused rather than queued.
- Several clients can share one Lightroom. The server checks that the plug-in comes from its own build and refuses, saying what to update, when it does not.
- The package also works from the command line: `npx -y lightroom-agent@0.1.0 tools` lists the tools, `call <tool> [json]` runs one, and `install-plugin` installs the plug-in.

## Known issues

- The first reset after Lightroom starts can come back `unknown` with nothing changed, most often right after a read of that photo's settings; read the photo and call again.
- An Adaptive preset whose AI mask Lightroom finds nothing for (no teeth on a closed-mouth portrait, say) answers `unknown` for that photo, though the preset was applied and its other masks computed.
- Windows is not tested against Lightroom: the server builds and passes CI there, but nobody has run it with Lightroom on Windows.

# lightroom-agent 0.1.0-rc.4

The fifth release candidate of lightroom-agent. Previews now work for the photo you are editing in Develop.

**Install**

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex CLI: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`; to update, `codex plugin marketplace upgrade lightroom-agent`, then start a new session.
- Claude Desktop: open the `.mcpb` attached to this release.
- Any MCP client: `npx -y lightroom-agent@0.1.0-rc.4` over stdio.
- From a checkout: run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients.

After updating, restart every client, then Lightroom Classic.

**Changes since 0.1.0-rc.3**

- Lightroom renders no preview of the photo open in Develop after an edit, so `get_photo_preview`, `get_photo_previews`, `get_photo_stats` and `find_duplicate_groups` failed for it after about 20 s. They now render that photo from Library: Lightroom shows Library for about a second and returns to Develop with the photo, selection and source restored; an open masking panel and the Develop tool are not restored. In a batch, that photo is rendered last.

**Known issue**

- The first reset after Lightroom starts can come back `unknown` with nothing changed, most often right after a read of that photo's settings; read the photo and call again.

The full description of this release candidate's behaviour is in the 0.1.0-rc.1 notes below.

# lightroom-agent 0.1.0-rc.3

The fourth release candidate of lightroom-agent. Codex now offers every tool, and a server started from an outdated client no longer replaces a newer Lightroom plug-in.

**Install**

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`; to update, `codex plugin marketplace upgrade lightroom-agent`, then start a new session.
- Claude Desktop: open the `.mcpb` attached to this release.
- Any MCP client: `npx -y lightroom-agent@0.1.0-rc.3` over stdio.
- From a checkout: run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients.

After updating, restart every client, then Lightroom Classic: the server that holds the Lightroom connection installs the new plug-in when it starts.

**Changes since 0.1.0-rc.2**

- Codex installs the plugin from a separate package in `codex/`. Codex hides the tools of an Agent Plugins server beyond 64 KB of tool descriptions and offered 17 of 80; the separate package is outside that limit. In `codex exec` the tools arrive a few seconds after the session starts.
- A server installs the Lightroom plug-in on its own only where none is installed, over an older version, or to repair its own build. Over a newer version, or over another build of the same version, it leaves the plug-in alone, does not connect, and every call says what to update. `install-plugin` still replaces any copy and says when that is a downgrade.

**Known issue**

- The first reset after Lightroom starts can come back `unknown` with nothing changed, most often right after a read of that photo's settings; read the photo and call again.

The full description of this release candidate's behaviour is in the 0.1.0-rc.1 notes below.

# lightroom-agent 0.1.0-rc.2

The third release candidate of lightroom-agent, for testing the installs before 0.1.0. It fixes resets that answered done while nothing was reset.

**Install**

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`; to update, `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`.
- Codex: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`.
- Claude Desktop: open the `.mcpb` attached to this release.
- Any MCP client: `npx -y lightroom-agent@0.1.0-rc.2` over stdio.

After updating, restart every client, then Lightroom Classic: the server that holds the Lightroom connection installs the new plug-in when it starts.

**Changes since 0.1.0-rc.1**

- `reset_develop_adjustments` answers `reset` only when a read of the photo 4 s after the reset shows its edits changed; otherwise the photo is `unknown`, to be read before grading on top.
- Every call that reads a photo's develop settings waits for the Develop calls before it, across all clients, instead of reading while another call works in Develop; such a read could void a running reset. Catalog work, previews and metadata writes still run alongside.

**Known issues**

- In `codex exec`, Codex does not yet offer the plugin's tools to the model, although the server starts.
- The first reset after Lightroom starts can come back `unknown` with nothing changed, most often right after a read of that photo's settings; read the photo and call again.

The full description of this release candidate's behaviour is in the 0.1.0-rc.1 notes below.

# lightroom-agent 0.1.0-rc.1

The second release candidate of lightroom-agent, for testing the installs before 0.1.0.

**Install**

- Claude Code: `/plugin marketplace add fadedDexofan/lightroom-agent`, then `/plugin install lightroom-agent@lightroom-agent`.
- Codex: `codex plugin marketplace add fadedDexofan/lightroom-agent`, then `codex plugin add lightroom-agent@lightroom-agent`.
- Claude Desktop: open the `.mcpb` attached to this release.
- Any MCP client: `npx -y lightroom-agent@0.1.0-rc.1` over stdio.
- From a checkout: after pulling, run `npm --prefix server run build`, restart every client, then restart Lightroom.

The server that holds the Lightroom connection installs the plug-in when it starts, or `install-plugin` does with every client quit: then restart Lightroom Classic and bring its window to the front; the plug-in starts its server. Needs Lightroom Classic 15.0 or later (checked on 15.6 and 16.0) on macOS.

**Known issue**

In `codex exec`, Codex does not yet offer the plugin's tools to the model, although the server starts; under investigation.

**What it does** (the design decisions behind it are in [docs/adr](https://github.com/fadedDexofan/lightroom-agent/tree/main/docs/adr))

- Every tool answers in one result envelope: `done`, `partial`, `failed` or `unknown`, decided by a per-call ledger of what the plug-in wrote, so `failed` always means nothing changed.
- Masks are listed, adjusted and deleted by id in the photo's saved settings, without opening Develop or depending on the selected mask; `invert_mask` still works in Develop. Constructing writes name the masks they add, so the ids they return work in the next call. While a mask on the photo has no id yet, value edits, `delete_masks` and constructing writes on that photo refuse and ask to call again.
- Subject, Sky, Background, People and Landscape masks and `combine_mask` components are written for Lightroom to compute and judged on the photo afterwards; a mask Lightroom finds nothing for is removed.
- Writes that construct masks are admitted by a per-machine certification of the running Lightroom build and the photo's process version; the live kit's throwaway catalog needs none.
- Develop writes are read back after Lightroom normalises them; a value stored differently is reported in `adjusted`. Slider changes pending in Develop are committed before a call reads or writes anything. `apply_auto_adjustments` returns once the saved values settle; `reset_develop_adjustments` returns without a read-back.
- The server checks that the Lightroom plug-in comes from its own build, and two clients sharing one Lightroom check each other's build. A server whose build does not match its plug-in folder refuses until it is rebuilt or reinstalled. The plug-in is installed by the server that holds the Lightroom connection or by `install-plugin` while no client runs, replacing an installed copy whose files differ.
- One repository installs as a plugin in Claude Code and Codex, and per their documentation in Cursor, Copilot CLI, Kiro and Goose; the npm package carries the plug-in and the bundled skill `lightroom-agent`, which teaches an agent to cull, develop, mask and export with these tools.
- A command line runs any tool: `tools`, `call <tool> [json]` and `install-plugin`.
- The Lightroom plug-in is `LightroomAgent.lrplugin`, with environment variables `LIGHTROOM_AGENT_*` and configuration in `~/.config/lightroom-agent/`. It uses the same ports as `LightroomMCP.lrplugin`, so remove that plug-in first if it is installed.
- Lightroom Classic 15.0 is the minimum.
