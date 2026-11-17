# lightroom-agent

[![CI](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Lightroom Classic 15+](https://img.shields.io/badge/Lightroom%20Classic-15%2B-31a8ff.svg)](#requirements)
[![Node.js 20+](https://img.shields.io/badge/node-20%2B-339933.svg)](#requirements)

Let an AI agent cull, develop, mask and export your photos in Adobe Lightroom Classic, and check every change on Lightroom's own render.

lightroom-agent is an MCP server and a Lightroom Classic plug-in. Claude Code, Codex or any other MCP client gets tools for the catalog, Develop, masks and export, plus a skill that tells the agent how to use them on photographs.

## What an agent can do

- **Cull.** Search by rating, date, camera, lens, keyword or folder; compare frames on previews; judge sharpness on 1:1 crops of a full-resolution render, not on a scaled preview.
- **Develop.** Write any develop setting by its Lightroom name. Ranges are checked before the write, and values are read back after Lightroom normalises them. Crop and straighten in the frame the agent sees; keep a way back with snapshots and named virtual copies; apply presets and match one photo's look on others.
- **Mask.** Subject, Sky, Background, People and Landscape masks; linear and radial gradients, brushes, colour, luminance and depth ranges; per-mask sliders, curves and Point Color.
- **Organise.** Ratings, flags, colour labels, keywords, collections, metadata and GPS, and private notes the agent keeps per photo.
- **Export.** To a folder or through an export preset; the reply lists the files written.

Ask for it in plain words:

> Cull yesterday's bird photos. Reject what is soft at 1080 px wide and tell me why.
>
> Darken the sky on the selected photos with a Sky mask and show me before and after.
>
> Develop DSC_0412 for a quiet, warm look, but snapshot the current edit first.
>
> Prepare my five-star photos from this week for an Instagram feed at 4:5.

## Built so an agent can trust what it did

| | Upstream lightroom-mcp | lightroom-agent |
| --- | --- | --- |
| Result of a call | A shape per tool; a failed write looks like one whose result is unknown | One envelope for every tool: `done`, `partial`, `failed` or `unknown`, decided by what the plug-in actually wrote. `failed` means nothing changed, so a retry is safe ([ADR 0001](docs/adr/0001-one-result-envelope.md)) |
| Mask edits | Through the mask selected in Develop, which a click can change mid-call | By mask id in the photo's saved settings, with the whole mask list read back after the write ([ADR 0003](docs/adr/0003-masks-addressed-by-id-in-the-saved-settings.md)) |
| Mask construction on a new Lightroom build | Allowed for a list of versions in the source | Allowed once the live test suite has passed on this machine for the running build ([ADR 0002](docs/adr/0002-mask-write-admission-by-certification.md)) |
| Guidance for the agent | A skill for generating XMP presets | A skill for culling, developing, masking and exporting with these tools |

AI masks are written for Lightroom to compute and judged on the photo afterwards: when Lightroom reports finding nothing, the mask is removed and the call says so, with no alert left open. A [live test kit](tests/e2e/live/README.md) builds a throwaway catalog from fixed images and checks the tools against Lightroom's renders. [GLOSSARY.md](GLOSSARY.md) defines the terms.

## Quick start

### Requirements

- Lightroom Classic 15.0 or later, checked live on 15.6 and 16.0; earlier versions are untested.
- macOS. Windows builds and passes CI but is untested against Lightroom.
- Node.js 20 or later (26.13.1 for development, as `.mise.toml` pins).

### 1. Build and install the plug-in

lightroom-agent is not on npm yet (the package will be `lightroom-agent`), so build it from the repository:

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build
node server/dist/index.js install-plugin
```

`install-plugin` copies `plugin/LightroomAgent.lrplugin` into Lightroom's Modules folder (`~/Library/Application Support/Adobe/Lightroom/Modules/` on macOS, `%APPDATA%\Adobe\Lightroom\Modules\` on Windows). It never replaces an installed plug-in, and it refuses while upstream's `LightroomMCP.lrplugin` is installed, because both use the same ports: delete that folder first.

### 2. Start it in Lightroom

Quit and reopen Lightroom Classic, open **File → Plug-in Manager**, select **Lightroom Agent** and click **Start Server**.

### 3. Connect your agent

Claude Code:

```sh
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node /path/to/lightroom-agent/server/dist/index.js
```

Codex:

```sh
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node /path/to/lightroom-agent/server/dist/index.js
```

Any other MCP client runs the same command over stdio, with an absolute path.

**Updating.** Pull and rebuild, quit Lightroom, delete the installed `LightroomAgent.lrplugin` folder (Plug-in Manager shows where it is), run `install-plugin` again, then restart Lightroom and your client. The server and the plug-in must come from the same revision. To uninstall, delete that folder, `~/.config/lightroom-agent` and the client's server entry.

## The bundled skill

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) tells an agent how to combine the tools, read their outcomes and make photographic decisions: two gates for culling, development in rendered passes on one representative per lighting situation, masks checked at their edges, exports checked file by file. `SKILL.md` routes to the files in `references/`. The server also offers the whole skill as the MCP prompt `lightroom-agent`, and `agents/openai.yaml` carries Codex's metadata for it.

## Reference

### Toolsets and read-only mode

The server exposes only the core tools unless `LIGHTROOM_AGENT_TOOLSETS` asks for more:

| Toolset | Contents |
| --- | --- |
| `core` | Catalog search, metadata (with GPS, location and private AI scores), keywords, collections, ratings, flags and labels, previews and detail crops, import, export, undo and removal from the catalog. Always on. |
| `develop` | Develop settings, crop, presets, style match, snapshots, virtual copies, treatment, process version, Lens Blur, Denoise, Auto, reset, Remove spots. |
| `masks` | Every mask tool: listing, geometry, AI masks, sliders, curves, Point Color, deletion. |
| `all` | All of the above. |

Combine them with commas (`develop,masks`). `LIGHTROOM_AGENT_READ_ONLY=true` hides every tool that writes and refuses calls to them before they reach Lightroom. Exports count as writes, and so does `get_photo_detail`: its full-resolution render is an export, which leaves an Export step in the photo's history and marks it exported. Previews come from Lightroom's preview cache and stay available. Both settings are read when the server starts.

Each tool describes its arguments, limits and outcomes in its schema. `LIGHTROOM_AGENT_TOOLSETS=all node server/dist/index.js tools` prints every schema without connecting to Lightroom.

### Command line

The same server runs tools from a shell:

```sh
node server/dist/index.js tools [name]          # print tool schemas
node server/dist/index.js call <tool> [json]    # call one tool, arguments as a JSON object
node server/dist/index.js install-plugin        # copy the plug-in into Lightroom
```

`call` prints the MCP response on stdout: `{"content":[{"type":"text","text":"…"}, …],"isError":true}`. The first text block is the result envelope as JSON, with `outcome` and, depending on it, `data`, `error`, `failed`, `unknown`, `not_found`, `remaining` and `warnings`; image results follow as image blocks. The command exits 0 for `done`, 1 for any other outcome (including arguments the tool's schema rejects) and 2 for a malformed command line. When the reply from Lightroom is lost, the outcome is `unknown` and carries only the transport error, since the server cannot name writes it never heard about.

```sh
LIGHTROOM_AGENT_READ_ONLY=true node server/dist/index.js call search_photos '{"limit":5}'
```

The ports default to 58763 and 58764. To change them, set `LIGHTROOM_AGENT_REQUEST_PORT` and `LIGHTROOM_AGENT_RESPONSE_PORT` and enter the same values in the plug-in's Plug-in Manager panel. `LIGHTROOM_AGENT_TOKEN_PATH` changes where the server reads the token; the plug-in always writes it to `~/.config/lightroom-agent/token`.

### Mask construction and certification

The tools that construct masks (gradients, brushes, range masks, AI masks) write an undocumented Lightroom format. Outside the live kit's throwaway catalog they run only when this machine holds a certification for the running Lightroom build. Value edits (sliders, curves, Point Color) and deletions need none. `get_mask_write_admission` reports the current state.

To certify, set up the live kit as its [README](tests/e2e/live/README.md) describes and run `node tests/e2e/live/certify-mask-writes.mjs` with the throwaway catalog open. The record names the Lightroom build and the process versions the run exercised; it does not name a plug-in revision, so rerun it after changing the plug-in. After a Lightroom update, mask construction is refused until the run passes again.

### Security

Starting the plug-in's server writes a random token to `~/.config/lightroom-agent/token`. The MCP server sends it with every request, and the plug-in listens on localhost only, so the remaining risk is another user or process on the same machine. Lightroom's plug-in sandbox cannot set file permissions; on a shared machine run `chmod 700 ~/.config/lightroom-agent`.

### Troubleshooting

The server writes its diagnostics to stderr, which MCP clients keep in their server log. **Plug-in Manager → Show Status** shows both sockets, the last event, the number of requests processed and the path of the plug-in log (`~/Documents/LrClassicLogs/LightroomAgent.log` by default).

| What you see | Cause and fix |
| --- | --- |
| Tools answer "Lightroom plugin not connected" | The plug-in's server is not running. Lightroom starts plug-ins only once its window has come to the front, so a Lightroom launched in the background has none yet: switch to it, or click **Start Server**. |
| `ECONNREFUSED` in the server log, or `failed to open localhost:58763` in the plug-in log after Reload Plug-in | The old plug-in task still holds the ports. Quit Lightroom and reopen it. |
| "Lightroom Agent token file not found" | **Start Server** has not run yet, or `LIGHTROOM_AGENT_TOKEN_PATH` points somewhere the plug-in never writes. |
| The connection opens and drops at once | The token does not match. The server reads the token again on every connect, so this happens when `LIGHTROOM_AGENT_TOKEN_PATH` points at an old copy. |
| A call times out | The handler is still running in Lightroom. Check **Last event** in Show Status and the plug-in log; a dialog in Lightroom (an AI update prompt during export, for example) blocks until you dismiss it. |

## Roadmap

The [open issues](https://github.com/fadedDexofan/lightroom-agent/issues), grouped by [milestone](https://github.com/fadedDexofan/lightroom-agent/milestones).

## Development

`mise install` provisions Node.js, Lua 5.1 (the version Lightroom runs) with LuaRocks, and selene; `mise run lua:test` installs busted into `lua_modules/` on first use.

```sh
cd server
npm run check          # type check
npm run lint
npm run build          # also regenerates plugin/LightroomAgent.lrplugin/Contract.lua
npm run test:coverage  # Jest with the coverage thresholds CI uses
cd ..
mise run lua:lint      # selene
mise run lua:test      # busted specs for the plug-in
mise run live:test     # unit tests of the live kit, no Lightroom needed
```

Instructions for coding agents working on this repository are in [CLAUDE.md](CLAUDE.md), also available as `AGENTS.md`.

## License

MIT. lightroom-agent is a fork of [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) and keeps its architecture: a TypeScript MCP server talking over local sockets to a Lua plug-in inside Lightroom. It is not affiliated with or endorsed by Adobe.
