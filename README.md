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

<p align="center">
  <img src="docs/assets/demo-before.jpg" alt="The Louvre and the Seine as shot" width="49%">
  <img src="docs/assets/demo-after.jpg" alt="The same photo after the agent's edit" width="49%">
</p>
<p align="center"><sub>Left: a CC0 Sony raw as shot. Right: the agent adjusted the whole photo and darkened the sky with a Sky mask.</sub></p>

lightroom-agent is an MCP server and a Lightroom Classic plug-in. Claude Code, Codex or any other MCP client gets tools for the catalog, Develop, masks and export, and a bundled skill that teaches the agent to cull and edit with them.

> **Works with:** Claude Code, Codex CLI, Claude Desktop and any other MCP client over stdio.<br>
> **Needs:** Lightroom Classic 15.0 or later on macOS (Windows is untested) and Node.js 20 or later.

## Quick start

1. In Claude Code, install the plugin:

   ```text
   /plugin marketplace add fadedDexofan/lightroom-agent
   /plugin install lightroom-agent@lightroom-agent
   ```

2. Quit Claude Code and start it again. Its lightroom-agent server starts with the session and installs the Lightroom plug-in: the folder `~/Library/Application Support/Adobe/Lightroom/Modules/LightroomAgent.lrplugin` appears.
3. Quit Lightroom Classic if it is running, open it and bring its window to the front. In **File → Plug-in Manager**, select **Lightroom Agent**: its status reads `Running: true`. If it reads `false`, click **Start Server**.
4. Ask Claude: *List my Lightroom collections.* It answers with your collection names, or says the catalog has none.

Codex, Claude Desktop and other clients are under [Installation](#installation).

### Something not working?

1. Bring Lightroom's window to the front once: Lightroom starts plug-ins only then.
2. In **Plug-in Manager**, click **Show Status** for Lightroom Agent. If `Running` is `false`, close the dialog and click **Start Server**. Once your agent's server has connected, `Request socket connected` and `Response socket connected` both read `true`. The dialog shows the state at the moment you open it; open it again for a fresh reading. If either line stays `false`, check that your client started its lightroom-agent server and that its ports match the ones in Plug-in Manager.
3. Look up the agent's error message in [Troubleshooting](#troubleshooting).

## What an agent can do

- **Cull.** Search by rating, date, camera, lens, keyword or folder, compare frames on previews, and judge sharpness on 1:1 crops of a full-resolution render rather than on a scaled preview. The photo open in Develop gets no preview; `render_photo` renders it, or any photo, by a short export.
- **Develop.** Set develop sliders by their Lightroom SDK names; ranges are checked before the write and values are read back after Lightroom normalises them. Crop and straighten in the frame the agent sees, apply presets, match one photo's look on others, and keep the previous edit recoverable with snapshots and named virtual copies.
- **Mask.** Subject, Sky, Background, People and Landscape masks; linear and radial gradients, brushes, colour, luminance and depth ranges (depth photos only); per-mask sliders, curves and Point Color. If Lightroom finds no sky or subject, the call removes the empty mask and says so. Building a mask needs a [certification](docs/reference.md#mask-construction-and-certification) on this machine that covers your Lightroom build and the photo's process version, rerun after each Lightroom update; slider, curve and Point Color edits work without it.
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
| Mask edits | Slider and curve edits take a mask id, select that mask in Develop and adjust the selection, which a click on another mask can change mid-call | By mask id in the photo's saved settings, read back after the write (`invert_mask` still works in Develop) |
| Mask construction on a new Lightroom build | Allowed for a list of versions in the source | Allowed once the live test suite has passed on this machine for that build and the photo's process version |
| Agent guidance | A preset-building workflow: culling, closed-loop edits, lighting-cluster presets, XMP fallback | A skill for culling, developing, masking and exporting with these tools, with technical and editorial gates |

The decisions behind the first three rows are in [docs/adr](docs/adr/). A [live test kit](tests/e2e/live/README.md) builds a throwaway catalog from fixed images and checks the tools against Lightroom's renders.

## When not to use it

- **Lightroom (the cloud app) or Lightroom Classic before 15.0.** Only Lightroom Classic 15.0 or later runs the plug-in.
- **Windows, if you need it proven.** The server builds and passes CI on Windows, but nobody has run it against Lightroom there.
- **Building masks without a Mac.** Certification runs the live kit, which needs macOS.
- **A catalog that must stay unchanged.** The tools write to the open catalog, so open a copy of it in Lightroom before connecting. `LIGHTROOM_AGENT_READ_ONLY=true` turns off the write tools for browsing, but every call, reads included and previews excepted, commits a slider change you left pending in Develop.

## Installation

Install lightroom-agent in each agent you use; every route ends with the same [Lightroom step](#finish-in-lightroom).

### Claude Code

Install it as in the [Quick start](#quick-start). The plugin brings the server with every toolset and the bundled [skill](#the-bundled-skill). To update, run `claude plugin marketplace update lightroom-agent`, then `claude plugin update lightroom-agent@lightroom-agent`; to uninstall, `claude plugin uninstall lightroom-agent@lightroom-agent`. After installing or updating, restart Claude Code.

<details>
<summary><b>Codex CLI</b></summary>

```sh
codex plugin marketplace add fadedDexofan/lightroom-agent
codex plugin add lightroom-agent@lightroom-agent
```

To update, run `codex plugin marketplace upgrade lightroom-agent`, start a new session, then restart Lightroom once; if the session has no Lightroom tools, remove the plugin and add it again. To uninstall, `codex plugin remove lightroom-agent@lightroom-agent`. `codex exec` starts the first turn without waiting for MCP servers, so the Lightroom tools can appear several seconds into the session. With Codex CLI 0.170.0, `codex exec` offered no MCP tools while `approval_policy` was `"never"`.

If the plugin's tools do not appear, declare the server in `~/.codex/config.toml`, with `<version>` replaced by your release (`codex plugin list` shows it). This entry replaces the plugin's server; keep its version equal to the plugin's when you update.

```toml
[mcp_servers.lightroom]
command = "npx"
args = ["-y", "lightroom-agent@<version>"]
env = { LIGHTROOM_AGENT_TOOLSETS = "all" }
```

</details>

<details>
<summary><b>Claude Desktop</b></summary>

Download `lightroom-agent-<version>.mcpb` from the [latest release](https://github.com/fadedDexofan/lightroom-agent/releases) and open it; Claude Desktop installs it as an extension. Its settings set the toolsets and read-only mode. To update, open the newer release's `.mcpb`; to uninstall, remove the extension in Claude Desktop's settings.

</details>

<details>
<summary><b>Any other MCP client</b></summary>

Set the command, arguments and environment below in your client's MCP settings. The example is for clients that accept an `mcpServers` object. Replace `<version>` with the [latest release](https://github.com/fadedDexofan/lightroom-agent/releases)'s version.

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
<summary><b>The plug-in from the release zip</b></summary>

The server installs the Lightroom plug-in when an MCP client starts it. The command line's `call` does not, so if you use only `call`, install the plug-in first:

1. Quit Lightroom Classic.
2. From the release that matches your server's version, download `LightroomAgent.lrplugin-<version>.zip` and unzip it.
3. If `LightroomAgent.lrplugin` is already in Lightroom's Modules or Plugins folder, update it in place with `npx -y lightroom-agent@<version> install-plugin` instead (see [Finish in Lightroom](#finish-in-lightroom)). Otherwise move the unzipped folder into the Modules folder: `~/Library/Application Support/Adobe/Lightroom/Modules/` on macOS, `%APPDATA%\Adobe\Lightroom\Modules\` on Windows. Create `Modules` if it does not exist. If `LightroomMCP.lrplugin` is installed, delete it: both plug-ins use the same ports.
4. Open Lightroom and check its status as in steps 2 and 3 of [Finish in Lightroom](#finish-in-lightroom). Then run `npx -y lightroom-agent@<version> call list_collections` with the version from step 2. It prints the result as JSON and exits with code 0 when the call succeeds.

The zip and the npm package of one release carry the same plug-in build, so that release's server accepts the copy and leaves it alone.

</details>

<details>
<summary><b>From source</b></summary>

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build

# Claude Code, in this directory only (add --scope user for all projects)
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

To update, pull, run `npm --prefix server run build`, quit every client, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients. A server updates an older plug-in on its own; a checkout whose version equals the installed one but whose build differs needs this explicit install. [CONTRIBUTING.md](CONTRIBUTING.md) covers working on the code.

</details>

### Finish in Lightroom

1. Start your agent. Its lightroom-agent server installs the Lightroom plug-in, updates an older one or repairs its own build.
2. Quit Lightroom Classic if it is running, open it and bring its window to the front. Lightroom starts plug-ins only then.
3. In **File → Plug-in Manager**, select **Lightroom Agent**: its status reads `Running: true`. If it reads `false`, click **Start Server**.
4. Ask your agent: *List my Lightroom collections.* It answers with your collection names, or says the catalog has none. If it does not, see [Something not working?](#something-not-working)

After any update, restart all your clients first, then Lightroom, so that it loads the installed plug-in. Until it does, tool calls fail with "Lightroom has loaded a different plug-in build". If a client refuses the plug-in installed on disk, find its message in [Troubleshooting](#troubleshooting).

<details>
<summary>Installing the plug-in with <code>install-plugin</code>, and uninstalling</summary>

`node server/dist/index.js install-plugin` (or `npx -y lightroom-agent@<version> install-plugin`) copies the server's plug-in over its existing copy in Lightroom's Modules or Plugins folder, otherwise into the Modules folder. It replaces an installed copy whose Lua files differ from its build's, older or newer alike, says so when that is a downgrade, and leaves an identical one alone. It refuses while a running lightroom-agent server on the same ports owns the plug-in, so quit your clients first; with custom ports, see [docs/reference.md](docs/reference.md#configuration). If a `LightroomMCP.lrplugin` is installed, it refuses, because both use the same ports: quit Lightroom and delete that folder first. It also writes two Develop presets that hold only a profile, `lightroom-agent Adobe Color.xmp` and `lightroom-agent Adobe Landscape.xmp`, into Camera Raw's settings folder (`~/Library/Application Support/Adobe/CameraRaw/Settings` on macOS, `%APPDATA%\Adobe\CameraRaw\Settings` on Windows), in the group "lightroom-agent profiles"; Lightroom registers them when it starts, and `set_profile` applies them. Camera Raw sees them too. Each install, and each server start that holds the Lightroom connection, rewrites a copy it wrote that has changed or gone missing, and leaves alone a file of that name it did not write (`set_profile` then refuses that profile).

To uninstall, remove the agent's plugin or server entry, then delete the installed `LightroomAgent.lrplugin` folder (Plug-in Manager shows where it is), the two `lightroom-agent` presets in Camera Raw's settings folder and `~/.config/lightroom-agent`.

</details>

## The bundled skill

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) teaches an agent how to work with these tools on photographs. It culls in two passes (technical, then editorial), develops one representative frame per lighting situation before copying to the rest, inspects mask edges, and checks each exported file.

The Claude Code and Codex plugins load it, and the server offers it to any client as the MCP prompt `lightroom-agent`. For other agents, `npx skills add fadedDexofan/lightroom-agent -g` installs it and asks which agents to install it for; the server still needs its own MCP entry, as under "Any other MCP client" in [Installation](#installation). To install it by hand, copy or symlink the folder into `~/.claude/skills/` for Claude Code or `~/.codex/skills/` for Codex; `agents/openai.yaml` carries Codex's metadata. The skill describes the tools of the server it ships with, so install it again whenever you update the server.

## Configuration and reference

The server reads `LIGHTROOM_AGENT_TOOLSETS`, `LIGHTROOM_AGENT_READ_ONLY`, the two port variables and `LIGHTROOM_AGENT_TOKEN_PATH` when it starts. [docs/reference.md](docs/reference.md) lists them with their defaults, and covers the toolsets, read-only mode, the command line and mask certification.

## Security

Starting the plug-in's server writes a random token to `~/.config/lightroom-agent/token`. The MCP server sends it with every request, and the plug-in listens on localhost only, so the remaining risk is another user or process on the same machine. Lightroom's plug-in sandbox cannot set file permissions; on a shared machine run `chmod 700 ~/.config/lightroom-agent`. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Troubleshooting

The server writes its diagnostics to stderr, which MCP clients keep in their server log. **Plug-in Manager → Show Status** shows both sockets, the last event, the number of requests processed and the path of the plug-in log (`~/Documents/LrClassicLogs/LightroomAgent.log` by default).

| What you see | Cause and fix |
| --- | --- |
| Tools answer "Lightroom plugin not connected" | The server has no connection to one or both of the plug-in's sockets. Lightroom starts plug-ins only once its window has come to the front, so a Lightroom launched in the background has none yet: switch to it, or click **Start Server**. Otherwise follow [Something not working?](#something-not-working) |
| `ECONNREFUSED` in the server log, or `failed to open localhost:58763` in the plug-in log after Reload Plug-in | The old plug-in task still holds the ports. Quit Lightroom and reopen it. |
| "Lightroom Agent token file not found" | **Start Server** has not run yet, or `LIGHTROOM_AGENT_TOKEN_PATH` points somewhere the plug-in never writes. |
| "The Lightroom Agent token does not match the running plug-in" | The server reads the token file again on every connect, so this happens when `LIGHTROOM_AGENT_TOKEN_PATH` points at an old copy. Click **Stop Server**, then **Start Server**, and check the variable. |
| "Lightroom has loaded a different plug-in build" | The plug-in Lightroom has loaded is not this server's build; the message names both. If the intended build was installed or repaired, restart Lightroom. Otherwise quit the connected clients, run this build's `install-plugin`, check its result, restart Lightroom and reconnect. Another client running a different build is one possible cause: use one build in every client. |
| "Lightroom's installed plug-in is version …, newer than this server's" | This client runs an older lightroom-agent than the installed plug-in, so its server leaves the plug-in alone and does not connect. Update lightroom-agent in this client, or remove an outdated server entry, then restart the client. |
| "Lightroom's installed plug-in is another build" | The installed plug-in has this server's version but another build, for example a server built from source and a plug-in installed from a release; the same error appears when the builds differ and the versions cannot be compared. The message gives each side's version and build. To install the server's build, quit the other clients, run `install-plugin` from the server's build, restart Lightroom, then start the clients. |
| "This server and the server that owns the Lightroom connection differ in …" | Two clients run different lightroom-agent builds, and the first one started holds the connection. Use one build in every client, then restart them. |
| "This server's build does not match its plug-in folder" | A checkout pulled or edited without a rebuild. Run `npm --prefix server run build` in the checkout, then restart your client. |
| "This server's installation is damaged" | An npm or Claude Desktop installation whose plug-in no longer matches its server. Reinstall lightroom-agent, then restart your client. |
| "This server has no bundled Lightroom plug-in" | The installation is incomplete. Reinstall lightroom-agent. |
| A call times out | Lightroom did not answer in time. A write may have been applied or may still be running. A Lightroom dialog (an AI update prompt during export, for example) blocks until you dismiss it. Check **Last event** in Show Status and the plug-in log, and read the settings or files back before retrying a write. |

## Development

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, checks and pull requests. Planned work is in the [issues](https://github.com/fadedDexofan/lightroom-agent/issues), grouped by [milestone](https://github.com/fadedDexofan/lightroom-agent/milestones). [GLOSSARY.md](GLOSSARY.md) defines the terms the code and documents use, and [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) holds the instructions for coding agents.

## License

MIT. lightroom-agent is a TypeScript MCP server that talks over local sockets to a Lua plug-in inside Lightroom. It is not affiliated with or endorsed by Adobe.
