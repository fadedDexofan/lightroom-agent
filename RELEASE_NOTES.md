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
