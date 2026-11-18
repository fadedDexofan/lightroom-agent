# Reference

Configuration, toolsets, the command line and mask certification. Each tool describes its own arguments, limits and outcomes in its schema; `LIGHTROOM_AGENT_TOOLSETS=all node server/dist/index.js tools` prints every schema without connecting to Lightroom (with `LIGHTROOM_AGENT_READ_ONLY` unset or false; read-only mode prints only the read tools).

## Configuration

The server reads these environment variables when it starts:

| Variable | Default | Values |
| --- | --- | --- |
| `LIGHTROOM_AGENT_TOOLSETS` | `core` | `core` plus `develop`, `masks`, or `all`, comma-separated |
| `LIGHTROOM_AGENT_READ_ONLY` | `false` | `true`/`1` hides and refuses every tool that writes |
| `LIGHTROOM_AGENT_REQUEST_PORT` | `58763` | Must match the plug-in's request port |
| `LIGHTROOM_AGENT_RESPONSE_PORT` | `58764` | Must match the plug-in's response port |
| `LIGHTROOM_AGENT_TOKEN_PATH` | `~/.config/lightroom-agent/token` | Where the server reads the token |

To change the ports, set both variables and enter the same values in the plug-in's Plug-in Manager panel. Installation is serialised only among servers on one port pair, while every pair installs into the same folder: run `install-plugin` with the same port variables, and quit clients on other ports before installing. The plug-in always writes the token to `~/.config/lightroom-agent/token`.

## Toolsets

| Toolset | Contents |
| --- | --- |
| `core` | Catalog search, metadata (with GPS, location and private AI scores), keywords, collections, ratings, flags and labels, previews and detail crops, import, export, undo and removal from the catalog. Always on. |
| `develop` | Develop settings, crop, presets, style match, snapshots, virtual copies, treatment, process version, Lens Blur, Denoise, Auto, reset, and editing or deleting existing spot removals. |
| `masks` | Every mask tool: listing, geometry, AI masks, sliders, curves, Point Color, deletion. |
| `all` | All of the above. |

## Read-only mode

`LIGHTROOM_AGENT_READ_ONLY=true` hides every tool that writes and refuses calls to them before they reach Lightroom. A read still commits a slider change pending in Develop, as every call does.

- Exports count as writes.
- `get_photo_detail` counts as a write: its full-resolution render is an export, which leaves an Export step in the photo's history and marks the photo exported.
- Previews come from Lightroom's preview cache and stay available.

## Command line

The server runs tools from a shell:

```sh
node server/dist/index.js tools [name]          # print tool schemas
node server/dist/index.js call <tool> [json]    # call one tool, arguments as a JSON object
node server/dist/index.js install-plugin        # copy the plug-in into Lightroom
node server/dist/index.js --version
node server/dist/index.js --help
```

`call` uses the same toolsets and read-only setting as the MCP server, so `call set_develop_settings` needs `LIGHTROOM_AGENT_TOOLSETS=develop` (or `all`).

It prints the MCP response on stdout, for example `{"content":[{"type":"text","text":"{\"outcome\":\"done\",…}"}]}`. The first text block is the result envelope as JSON, with `outcome` and, depending on it, `data`, `error`, `failed`, `unknown`, `not_found`, `remaining` and `warnings`; image results follow as image blocks. `isError` is `true` for every outcome except `done`.

| Exit code | Meaning |
| --- | --- |
| 0 | `done` |
| 1 | Any other outcome, including arguments the tool's schema rejects or an invalid environment value |
| 2 | A malformed command line |

When the reply to a sent write is lost, the outcome is `unknown` and carries only the transport error, since the server cannot name writes it never heard about. A lost read, or a call that was never sent, is `failed`.

```sh
LIGHTROOM_AGENT_READ_ONLY=true node server/dist/index.js call search_photos '{"limit":5}'
```

## Mask construction and certification

The tools that construct masks (gradients, brushes, range masks, AI masks, combined masks, and full copies of develop settings when the source has masks to copy or the target has masks to remove) write an undocumented Lightroom format. Outside the live kit's throwaway catalog they run only when this machine holds a certification for the running Lightroom build and the photo's process version. Value edits (sliders, curves, Point Color) and deletions need none. `get_mask_write_admission` reports the current state for a photo.

To certify, set up the live kit as its [README](../tests/e2e/live/README.md) describes and run `node tests/e2e/live/certify-mask-writes.mjs` with the throwaway catalog open. The kit needs macOS. The record names the Lightroom build and the process versions the run exercised, not a plug-in revision, so rerun it after updating lightroom-agent. After a Lightroom update, mask construction is refused until the run passes again. [ADR 0002](adr/0002-mask-write-admission-by-certification.md) records why.
