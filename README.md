English | [Русский](README.ru.md) | [繁體中文](README.zh-TW.md)

<h1 align="center">lightroom-agent</h1>

<p align="center">Let an AI agent cull, develop, mask and export your photos in Adobe Lightroom Classic, and check every change on Lightroom's own render.</p>

<div align="center">

<!-- Project -->
[![CI](https://img.shields.io/github/actions/workflow/status/fadedDexofan/lightroom-agent/ci.yml?branch=main&logo=github&label=CI)](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/fadedDexofan/lightroom-agent?include_prereleases&logo=github&label=release)](https://github.com/fadedDexofan/lightroom-agent/releases)
[![License](https://img.shields.io/github/license/fadedDexofan/lightroom-agent)](LICENSE)
[![Issues](https://img.shields.io/github/issues/fadedDexofan/lightroom-agent)](https://github.com/fadedDexofan/lightroom-agent/issues)

<!-- Package -->
[![npm](https://img.shields.io/npm/v/lightroom-agent?logo=npm&label=npm)](https://www.npmjs.com/package/lightroom-agent)
[![npm downloads](https://img.shields.io/npm/dm/lightroom-agent?logo=npm&label=downloads)](https://www.npmjs.com/package/lightroom-agent)
[![Node.js](https://img.shields.io/node/v/lightroom-agent?logo=nodedotjs&label=node)](#installation)

<!-- Runs in -->
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-D97757?logo=claude&logoColor=white)](#installation)
[![Codex](https://img.shields.io/badge/Codex-plugin-412991)](#installation)
[![Claude Desktop](https://img.shields.io/badge/Claude_Desktop-.mcpb-D97757?logo=claude&logoColor=white)](https://github.com/fadedDexofan/lightroom-agent/releases)
[![MCP](https://img.shields.io/badge/MCP-server-000000?logo=modelcontextprotocol&logoColor=white)](docs/reference.md)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-lightroom--agent-6E56CF)](skills/lightroom-agent/SKILL.md)

<!-- Lightroom -->
[![Lightroom Classic 15+](https://img.shields.io/badge/Lightroom_Classic-15%2B-31A8FF)](#installation)
[![macOS](https://img.shields.io/badge/macOS-tested-000000?logo=apple&logoColor=white)](#installation)

</div>

lightroom-agent is an MCP server and a Lightroom Classic plug-in. Claude Code, Codex or any other MCP client gets tools for the catalog, Develop, masks and export, and a bundled skill that teaches the agent to cull and edit with them. It is a fork of [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp).

## What an agent can do

- **Cull.** Search by rating, date, camera, lens, keyword or folder, compare frames on previews, and judge sharpness on 1:1 crops of a full-resolution render rather than on a scaled preview.
- **Develop.** Set develop sliders by their Lightroom SDK names; ranges are checked before the write and values are read back after Lightroom normalises them. Crop and straighten in the frame the agent sees, apply presets, match one photo's look on others, and keep the previous edit recoverable with snapshots and named virtual copies.
- **Mask.** Subject, Sky, Background, People and Landscape masks; linear and radial gradients, brushes, colour, luminance and depth ranges (depth photos only); per-mask sliders, curves and Point Color. If Lightroom finds no sky or subject, the call removes the empty mask and says so. Building a mask needs a [certification](docs/reference.md#mask-construction-and-certification) of your Lightroom build, rerun after each Lightroom update; slider, curve and Point Color edits work without it.
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

## Installation

You need Lightroom Classic 15.0 or later on macOS (checked live on 15.6 and 16.0; 15.0–15.5 and Windows are untested) and Node.js 20 or later. Install lightroom-agent in each agent you use; every route ends with the same [Lightroom step](#finish-in-lightroom).

### Claude Code

```text
/plugin marketplace add fadedDexofan/lightroom-agent
/plugin install lightroom-agent@lightroom-agent
```

The plugin brings the server with every toolset and the bundled [skill](#the-bundled-skill). To update, run `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`; to uninstall, `claude plugin uninstall lightroom-agent@lightroom-agent`.

<details>
<summary><b>Codex</b></summary>

```sh
codex plugin marketplace add fadedDexofan/lightroom-agent
codex plugin add lightroom-agent@lightroom-agent
```

The plugin brings the server and the skill, as in Claude Code. In `codex exec`, Codex does not yet offer the plugin's tools to the model. To update, run `codex plugin marketplace upgrade lightroom-agent` and add the plugin again; to uninstall, `codex plugin remove lightroom-agent@lightroom-agent`.

</details>

<details>
<summary><b>Claude Desktop</b></summary>

Download `lightroom-agent-<version>.mcpb` from the [latest release](https://github.com/fadedDexofan/lightroom-agent/releases) and open it; Claude Desktop installs it as an extension. Its settings set the toolsets and read-only mode. To update, open the newer release's `.mcpb`; to uninstall, remove the extension in Claude Desktop's settings.

</details>

<details>
<summary><b>Any other MCP client</b></summary>

Run the npm package over stdio, pinned to the [latest release](https://github.com/fadedDexofan/lightroom-agent/releases)'s version:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "npx",
      "args": ["-y", "lightroom-agent@<version>"],
      "env": { "LIGHTROOM_AGENT_TOOLSETS": "all" }
    }
  }
}
```

`all` adds the Develop and mask tools to the default `core` set. Keep the version pinned: the server refuses to work with a plug-in of another build, so every client should run the same one. To update, change the version in every client. The server offers the skill as the MCP prompt `lightroom-agent`.

</details>

<details>
<summary><b>From source</b></summary>

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build

# Claude Code
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

To update, pull and rebuild. [CONTRIBUTING.md](CONTRIBUTING.md) covers working on the code.

</details>

### Finish in Lightroom

The server that holds the Lightroom connection installs the plug-in when it starts. Then quit and reopen Lightroom Classic and bring its window to the front: the plug-in starts its server. If **File → Plug-in Manager** shows Lightroom Agent stopped, click **Start Server**.

Ask your agent: *List my Lightroom collections.* It answers with your collections by name.

After any update, restart all your clients first, then Lightroom: every server refuses tool calls, naming both builds, until Lightroom has loaded the new plug-in.

<details>
<summary>Installing the plug-in by hand, and uninstalling</summary>

`node server/dist/index.js install-plugin` (or `npx -y lightroom-agent@<version> install-plugin`) copies the plug-in over its existing copy in Lightroom's Modules or Plugins folder, otherwise into the Modules folder (`~/Library/Application Support/Adobe/Lightroom/Modules/` on macOS, `%APPDATA%\Adobe\Lightroom\Modules\` on Windows). It replaces an installed copy whose files differ from its build and leaves an identical one alone. It refuses while a running lightroom-agent server on the same ports owns the plug-in, so quit your clients first; with custom ports, run it with the same port variables and quit clients on any other ports too, since every port pair installs into the same folder. If a `LightroomMCP.lrplugin` is installed, it refuses, because both use the same ports: quit Lightroom and delete that folder first.

To uninstall, remove the agent's plugin or server entry, then delete the installed `LightroomAgent.lrplugin` folder (Plug-in Manager shows where it is) and `~/.config/lightroom-agent`.

</details>

## The bundled skill

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) teaches an agent how to work with these tools on photographs. It culls in two passes (technical, then editorial), develops one representative frame per lighting situation before copying to the rest, inspects mask edges, and checks each exported file.

The Claude Code and Codex plugins load it, and the server offers it to any client as the MCP prompt `lightroom-agent`. To install it by hand, copy or symlink the folder into `~/.claude/skills/` for Claude Code or `~/.codex/skills/` for Codex; `agents/openai.yaml` carries Codex's metadata. The skill describes the tools of the server it ships with, so replace a copied folder whenever you update the server.

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
| "The Lightroom Agent token does not match the running plug-in" | The server reads the token file again on every connect, so this happens when `LIGHTROOM_AGENT_TOKEN_PATH` points at an old copy. Click **Stop Server**, then **Start Server**, and check the variable. |
| "Lightroom has loaded a different plug-in build" | The plug-in Lightroom has loaded is not this server's build; the message names both. If the intended build was installed or repaired, restart Lightroom. Otherwise quit the connected clients, run this build's `install-plugin`, check its result, restart Lightroom and reconnect. Another client running a different build is one possible cause: use one build in every client. |
| "This server and the server that owns the Lightroom connection differ in …" | Two clients run different lightroom-agent builds, and the first one started holds the connection. Use one build in every client, then restart them. |
| "This server's build does not match its plug-in folder" | A checkout pulled or edited without a rebuild. Run `npm --prefix server run build` in the checkout, then restart your client. |
| "This server's installation is damaged" | An npm or Claude Desktop installation whose plug-in no longer matches its server. Reinstall lightroom-agent, then restart your client. |
| "This server has no bundled Lightroom plug-in" | The installation is incomplete. Reinstall lightroom-agent. |
| A call times out | The handler is still running in Lightroom. Check **Last event** in Show Status and the plug-in log; a dialog in Lightroom (an AI update prompt during export, for example) blocks until you dismiss it. |

## Development

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, checks and pull requests. Planned work is in the [issues](https://github.com/fadedDexofan/lightroom-agent/issues), grouped by [milestone](https://github.com/fadedDexofan/lightroom-agent/milestones). [GLOSSARY.md](GLOSSARY.md) defines the terms the code and documents use, and [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) holds the instructions for coding agents.

## License

MIT, as upstream. lightroom-agent keeps upstream's architecture: a TypeScript MCP server talking over local sockets to a Lua plug-in inside Lightroom. It is not affiliated with or endorsed by Adobe.
