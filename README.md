# lightroom-agent

[![CI](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Lightroom Classic 15+](https://img.shields.io/badge/Lightroom%20Classic-15%2B-31a8ff.svg)](#requirements)
[![Node.js 20+](https://img.shields.io/badge/node-20%2B-339933.svg)](#requirements)

Let an AI agent cull, develop, mask and export your photos in Adobe Lightroom Classic, and check every change on Lightroom's own render.

lightroom-agent is an MCP server and a Lightroom Classic plug-in. Claude Code, Codex or any other MCP client gets tools for the catalog, Develop, masks and export, and a bundled skill that teaches the agent to cull and edit with them. It is a fork of [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp).

## What an agent can do

- **Cull.** Search by rating, date, camera, lens, keyword or folder, compare frames on previews, and judge sharpness on 1:1 crops of a full-resolution render rather than on a scaled preview.
- **Develop.** Set develop sliders by their Lightroom SDK names; ranges are checked before the write and values are read back after Lightroom normalises them. Crop and straighten in the frame the agent sees, apply presets, match one photo's look on others, and keep the previous edit recoverable with snapshots and named virtual copies.
- **Mask.** Subject, Sky, Background, People and Landscape masks; linear and radial gradients, brushes, colour, luminance and depth ranges (depth photos only); per-mask sliders, curves and Point Color. If Lightroom finds no sky or subject, the call removes the empty mask and says so. Building a mask needs a one-time [certification](docs/reference.md#mask-construction-and-certification) of your Lightroom build; slider, curve and Point Color edits work without it.
- **Organise.** Ratings, flags, colour labels, keywords, collections, metadata and GPS, plus a private score and reason per photo, kept out of IPTC and XMP.
- **Export.** To a folder or through an export preset; the reply lists the files written.

Things to ask for:

- *Cull yesterday's bird photos. Reject what is soft at 1080 px wide and tell me why.*
- *Develop DSC_0412 for a quiet, warm look, but snapshot the current edit first.*
- *Darken the sky on the selected photos with a Sky mask and show me before and after.*
- *Prepare my five-star photos from this week for an Instagram feed at 4:5.*

## How it differs from lightroom-mcp

| | lightroom-mcp | lightroom-agent |
| --- | --- | --- |
| Result of a call | Plain errors; a failed write looks like one whose result is unknown | One envelope: `done`, `partial`, `failed`, `unknown`, decided by what was written; `failed` means nothing changed |
| Mask edits | Sliders, curves and deletions act on the mask selected in Develop, which a click can change mid-call | By mask id in the photo's saved settings, read back after the write (`invert_mask` still works in Develop) |
| Mask construction on a new Lightroom build | Allowed for a list of versions in the source | Allowed once the live test suite has passed on this machine for that build |
| Agent guidance | A preset-building workflow: culling, closed-loop edits, lighting-cluster presets, XMP fallback | A skill for culling, developing, masking and exporting with these tools, with technical and editorial gates |

The decisions behind the first three rows are in [docs/adr](docs/adr/). A [live test kit](tests/e2e/live/README.md) builds a throwaway catalog from fixed images and checks the tools against Lightroom's renders.

## When not to use it

- **Lightroom (the cloud app) or Lightroom Classic before 15.0.** Only Lightroom Classic 15.0 or later runs the plug-in.
- **Windows, if you need it proven.** The server builds and passes CI on Windows, but nobody has run it against Lightroom there.
- **Building masks without a Mac.** Certification runs the live kit, which needs macOS.
- **A catalog you cannot afford to touch.** The tools write to the open catalog. Start with `LIGHTROOM_AGENT_READ_ONLY=true`, or let the agent work on snapshots and virtual copies, which the bundled skill does by default.

## Quick start

### Requirements

- Lightroom Classic 15.0 or later; checked live on 15.6 and 16.0, while 15.0–15.5 are untested.
- macOS.
- Node.js 20 or later (26.13.1 for development, as `.mise.toml` pins).

### 1. Build and install the plug-in

lightroom-agent is not on npm yet. Build it from the repository:

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build
node server/dist/index.js install-plugin
```

`install-plugin` copies `plugin/LightroomAgent.lrplugin` into Lightroom's Modules folder (`~/Library/Application Support/Adobe/Lightroom/Modules/` on macOS, `%APPDATA%\Adobe\Lightroom\Modules\` on Windows). It replaces an installed copy from another version and leaves a current one alone; the server does the same when it starts. If a `LightroomMCP.lrplugin` is installed, it refuses, because both use the same ports: quit Lightroom and delete that folder first.

### 2. Start it in Lightroom

Quit and reopen Lightroom Classic, open **File → Plug-in Manager**, select **Lightroom Agent** and click **Start Server**.

### 3. Connect your agent

From the `lightroom-agent` folder:

```sh
# Claude Code
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"

# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

`all` adds the Develop and mask tools to the default `core` set. Any other MCP client runs the same command over stdio, with an absolute path.

Check it works by asking your agent: *List my Lightroom collections.*

**Updating.** Pull and rebuild, then restart your client: the server replaces the installed plug-in when its version differs, and refuses tool calls, naming both versions, until Lightroom has been restarted onto the new one. To uninstall, delete that folder, `~/.config/lightroom-agent` and the client's server entry.

## The bundled skill

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) teaches an agent how to work with these tools on photographs. It culls in two passes (technical, then editorial), develops one representative frame per lighting situation before copying to the rest, inspects mask edges, and checks each exported file.

The server offers the whole skill as the MCP prompt `lightroom-agent`. To install it as a skill, copy or symlink the folder into `~/.claude/skills/` for Claude Code or `~/.codex/skills/` for Codex; `agents/openai.yaml` carries Codex's metadata.

## Configuration and reference

The server reads `LIGHTROOM_AGENT_TOOLSETS`, `LIGHTROOM_AGENT_READ_ONLY`, the two port variables and `LIGHTROOM_AGENT_TOKEN_PATH` when it starts. [docs/reference.md](docs/reference.md) lists them with their defaults, and covers the toolsets, read-only mode, the command line and mask certification.

## Security

Starting the plug-in's server writes a random token to `~/.config/lightroom-agent/token`. The MCP server sends it with every request, and the plug-in listens on localhost only, so the remaining risk is another user or process on the same machine. Lightroom's plug-in sandbox cannot set file permissions; on a shared machine run `chmod 700 ~/.config/lightroom-agent`. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Troubleshooting

The server writes its diagnostics to stderr, which MCP clients keep in their server log. **Plug-in Manager → Show Status** shows both sockets, the last event, the number of requests processed and the path of the plug-in log (`~/Documents/LrClassicLogs/LightroomAgent.log` by default).

| What you see | Cause and fix |
| --- | --- |
| Tools answer "Lightroom plugin not connected" | The plug-in's server is not running. Lightroom starts plug-ins only once its window has come to the front, so a Lightroom launched in the background has none yet: switch to it, or click **Start Server**. |
| `ECONNREFUSED` in the server log, or `failed to open localhost:58763` in the plug-in log after Reload Plug-in | The old plug-in task still holds the ports. Quit Lightroom and reopen it. |
| "Lightroom Agent token file not found" | **Start Server** has not run yet, or `LIGHTROOM_AGENT_TOKEN_PATH` points somewhere the plug-in never writes. |
| The connection opens and drops at once | The token does not match. The server reads the token again on every connect, so this happens when `LIGHTROOM_AGENT_TOKEN_PATH` points at an old copy. |
| A call times out | The handler is still running in Lightroom. Check **Last event** in Show Status and the plug-in log; a dialog in Lightroom (an AI update prompt during export, for example) blocks until you dismiss it. |

## Development

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, checks and pull requests. Planned work is in the [issues](https://github.com/fadedDexofan/lightroom-agent/issues), grouped by [milestone](https://github.com/fadedDexofan/lightroom-agent/milestones). [GLOSSARY.md](GLOSSARY.md) defines the terms the code and documents use, and [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) holds the instructions for coding agents.

## License

MIT, as upstream. lightroom-agent keeps upstream's architecture: a TypeScript MCP server talking over local sockets to a Lua plug-in inside Lightroom. It is not affiliated with or endorsed by Adobe.
