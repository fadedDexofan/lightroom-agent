# lightroom-agent

lightroom-agent lets an AI agent edit photos in Adobe Lightroom Classic: search and organize the catalog, change develop settings, build and adjust masks, and render previews and full-resolution crops to check the result. It is a fork of [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp), released under the same MIT license, and keeps its architecture: a TypeScript MCP server talking over local sockets to a Lua plug-in inside Lightroom. The fork is developed and tested on macOS; Windows is untested. It is not affiliated with or endorsed by Adobe.

## What differs from upstream

- **Every tool answers in one envelope.** The result is `done`, `partial`, `failed` or `unknown`, and the class comes from a per-call ledger of what the plug-in actually wrote, not from how an error was raised. `failed` means nothing changed and the call is safe to retry; `unknown` means something may have changed, so an agent reads the photo before trying again. See [ADR 0001](docs/adr/0001-one-result-envelope.md).
- **Masks are edited by id in the saved settings.** Mask sliders, curves, Point Color and deletions address a mask by its id in the photo's stored mask list and read the whole list back after the write. They do not depend on which mask is selected in Develop. See [ADR 0003](docs/adr/0003-masks-addressed-by-id-in-the-saved-settings.md).
- **AI masks are judged on the photo.** Subject, Sky, Background, People and Landscape masks are written as seeds for Lightroom to compute. The call then reports what Lightroom found on the photo, and a mask it could not find is removed.
- **Mask geometry writes need a per-machine certification.** Gradients, brushes, range masks and AI masks use an undocumented settings format. They run only after the live kit's test suite has passed on a throwaway catalog for the running Lightroom build. See [ADR 0002](docs/adr/0002-mask-write-admission-by-certification.md).
- **A live test kit.** [`tests/e2e/live/`](tests/e2e/live/README.md) builds a throwaway catalog from fixed fixtures and checks tools against Lightroom's own renders.

[GLOSSARY.md](GLOSSARY.md) defines the terms these documents use.

## Install from this checkout

Use Node.js 26.13.1, the version `.mise.toml` and CI pin; the built server itself runs on Node.js 20 or later. There is no published package yet, so build the server and the plug-in from the repository:

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build
node server/dist/index.js install-plugin
```

`install-plugin` copies `plugin/LightroomAgent.lrplugin` into Lightroom's Modules folder (`~/Library/Application Support/Adobe/Lightroom/Modules/` on macOS, `%APPDATA%\Adobe\Lightroom\Modules\` on Windows). It never replaces a plug-in that is already there. The server also installs it when it starts and finds no `LightroomAgent.lrplugin` in either the Modules or the Plugins folder.

Then quit and reopen Lightroom Classic, open **File → Plug-in Manager**, select **Lightroom Agent** and click **Start Server**.

The plug-in needs Lightroom Classic 15.0 or later; it was checked live on 15.6 and 16.0, and earlier versions are untested.

**Updating, or replacing upstream's plug-in.** Pull and rebuild the server, quit Lightroom, delete the installed `LightroomAgent.lrplugin` folder, or upstream's `LightroomMCP.lrplugin` (Plug-in Manager shows where it is, Modules or Plugins; `install-plugin` refuses while `LightroomMCP.lrplugin` is installed, since both bind the same ports), run `node server/dist/index.js install-plugin`, then restart Lightroom and your MCP client. The server and the plug-in must come from the same revision. To uninstall, delete that folder, `~/.config/lightroom-agent` and the client's server entry.

## Connect an agent

Point your client at `server/dist/index.js` with an absolute path. Codex:

```sh
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node /path/to/lightroom-agent/server/dist/index.js
```

Claude Code:

```sh
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node /path/to/lightroom-agent/server/dist/index.js
```

Any other MCP client runs the same command over stdio.

## The bundled skill

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) is a skill for agents that use these tools. It covers how to combine the tools and read their outcomes, and how to make photographic decisions while culling, developing, masking and exporting. `SKILL.md` is the entry point and links the files in `references/`. The server offers the whole skill as the MCP prompt `lightroom-agent`, with each reference appended under its path. `agents/openai.yaml` carries Codex's metadata for the skill.

## Toolsets and read-only mode

The server exposes only the core tools unless `LIGHTROOM_AGENT_TOOLSETS` asks for more:

| Toolset | Contents |
| --- | --- |
| `core` | Catalog search, metadata (with GPS, location and private AI scores), keywords, collections, ratings, flags and labels, previews and detail crops, import, export, undo and removal from the catalog. Always on. |
| `develop` | Develop settings, crop, presets, style match, snapshots, virtual copies, treatment, process version, Lens Blur, Denoise, Auto, reset, Remove spots. |
| `masks` | Every mask tool: listing, geometry, AI masks, sliders, curves, Point Color, deletion. |
| `all` | All of the above. |

Combine them with commas (`develop,masks`). `LIGHTROOM_AGENT_READ_ONLY=true` hides every tool that writes and refuses calls to them before they reach Lightroom. Exports count as writes, and so does `get_photo_detail`: its full-resolution render is an export, which leaves an Export step in the photo's history and marks it exported. Previews come from Lightroom's preview cache and stay available. Both settings are read when the server starts.

Each tool describes its arguments, limits and outcomes in its schema. `LIGHTROOM_AGENT_TOOLSETS=all node server/dist/index.js tools` prints every schema without connecting to Lightroom; without the variable it prints the core tools only.

## Command line

The same server runs tools from a shell:

```sh
node server/dist/index.js tools [name]          # print tool schemas
node server/dist/index.js call <tool> [json]    # call one tool, arguments as a JSON object
node server/dist/index.js install-plugin        # copy the plug-in into Lightroom
```

`call` prints the MCP response on stdout: `{"content":[{"type":"text","text":"…"}, …],"isError":true}`. The first text block is the result envelope as JSON, with `outcome` and, depending on it, `data`, `error`, `failed`, `unknown`, `not_found`, `remaining` and `warnings`; image results follow as image blocks. The command exits 0 for `done` and 1 for any other outcome, a call whose arguments the tool's schema rejects included; it exits 2 when the command line itself is malformed. When the reply from Lightroom is lost, the outcome is `unknown` and carries only the transport error, since the server cannot name writes it never heard about. For example:

```sh
LIGHTROOM_AGENT_READ_ONLY=true node server/dist/index.js call search_photos '{"limit":5}'
```

The ports default to 58763 and 58764. To change them, set `LIGHTROOM_AGENT_REQUEST_PORT` and `LIGHTROOM_AGENT_RESPONSE_PORT` and enter the same values in the plug-in's Plug-in Manager panel. `LIGHTROOM_AGENT_TOKEN_PATH` changes where the server reads the token; the plug-in always writes it to `~/.config/lightroom-agent/token`.

## Mask geometry and the certification

Until this machine has a certification for the running Lightroom build, the tools that construct masks refuse outside the live kit's throwaway catalog. Those are gradients, brushes, range masks and AI masks. Value edits (sliders, curves, Point Color) and deletions work without it. `get_mask_write_admission` reports the current state.

To certify, set up the live kit as its [README](tests/e2e/live/README.md) describes, including the pinned portrait it needs for the Subject and People steps (`LRAGENT_LIVE_PEOPLE_PHOTO`), and run `node tests/e2e/live/certify-mask-writes.mjs` with the throwaway catalog open. The record names the Lightroom build and the process versions the run exercised. It is not tied to a plug-in revision, and a mask kind the run did not exercise stays admitted with the rest, so rerun it after changing the plug-in. After a Lightroom update, mask construction stays refused until the run passes again.

## Security

Starting the plug-in's server writes a random token to `~/.config/lightroom-agent/token`. The MCP server sends it with every request, and the plug-in listens on localhost only, so the remaining risk is another user or process on the same machine. Lightroom's plug-in sandbox cannot set file permissions; on a shared machine run `chmod 700 ~/.config/lightroom-agent`.

## Not yet published

The fork has no npm package, `.mcpb` bundle, standalone binary or MCP registry entry yet. The npm package will be `lightroom-agent`; until it is published, install from a checkout as shown above.

## Roadmap

The [open issues](https://github.com/fadedDexofan/lightroom-agent/issues), grouped by [milestone](https://github.com/fadedDexofan/lightroom-agent/milestones).

## Development

`mise install` provisions Node.js, Lua with LuaRocks, and selene; `mise run lua:test` installs busted into `lua_modules/` on first use.

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

## Troubleshooting

The server writes its diagnostics to stderr, which MCP clients keep in their server log. **Plug-in Manager → Show Status** shows both sockets, the last event, the number of requests processed and the path of the plug-in log (`~/Documents/LrClassicLogs/LightroomAgent.log` by default).

| What you see | Cause and fix |
| --- | --- |
| Tools answer "Lightroom plugin not connected" | The plug-in's server is not running. Lightroom starts plug-ins only once its window has come to the front, so a Lightroom launched in the background has none yet: switch to it, or click **Start Server**. |
| `ECONNREFUSED` in the server log, or `failed to open localhost:58763` in the plug-in log after Reload Plug-in | The old plug-in task still holds the ports. Quit Lightroom and reopen it. |
| "Lightroom Agent token file not found" | **Start Server** has not run yet, or `LIGHTROOM_AGENT_TOKEN_PATH` points somewhere the plug-in never writes. |
| The connection opens and drops at once | The token does not match. The server reads the token again on every connect, so this happens when `LIGHTROOM_AGENT_TOKEN_PATH` points at an old copy. |
| A call times out | The handler is still running in Lightroom. Check **Last event** in Show Status and the plug-in log; a dialog in Lightroom (an AI update prompt during export, for example) blocks until you dismiss it. |

## License

MIT, as upstream. See [LICENSE](LICENSE).
