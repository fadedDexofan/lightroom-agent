# Contributing

lightroom-agent has one maintainer, who reviews issues and pull requests as time allows. Keep each pull request to one change.

## What helps most

- **Bug reports** with the Lightroom Classic version, your MCP client and the tool's reply (the JSON envelope). Use the bug report form.
- **Fixes** for a reported bug.
- **Live observations** of Lightroom behaviour on a version or platform we have not tested, such as Windows, Lightroom Classic 15.0–15.5 or a new release.
- **Documentation** that is wrong or unclear.

For a new tool or a change in how an existing tool behaves, open an issue first, so we can agree on the shape before you write it. Tool names, arguments and outcomes are a contract with every agent that calls them.

## Set up

You need [mise](https://mise.jdx.dev/), which provisions the pinned Node.js, Lua 5.1.5 (the version Lightroom runs) with LuaRocks, selene and StyLua.

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
mise install
npm --prefix server ci
git config blame.ignoreRevsFile .git-blame-ignore-revs   # skip the formatting commits in git blame
```

To try your build in a client, point it at this checkout's server, for example in Claude Code: `claude mcp add lightroom-dev -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"`. The server that owns the plug-in connection installs your build's Lightroom plug-in when it becomes the owner, but only where none, an older version or your own build is installed; over another build whose version is newer, the same or cannot be compared, a published one included, it leaves the installed copy alone, refuses every call naming both builds and does not connect. To put your build in place, quit your clients, run `node server/dist/index.js install-plugin`, restart Lightroom, then start the clients. While your build is installed, a lightroom-agent server of another build refuses tool calls, naming both, and installs its own plug-in only when it owns the connection and its version is newer. Build first, then start clients: a client started while a build is running may refuse until it is restarted. After you pull or edit the plug-in's Lua, rebuild, quit your clients, run `install-plugin`, restart Lightroom, then start the clients: a server whose build does not match its plug-in folder refuses every call until it is rebuilt.

[CLAUDE.md](CLAUDE.md) describes the architecture, the conventions and the traps in Lightroom's SDK. Read the parts that cover what you change; [GLOSSARY.md](GLOSSARY.md) and [docs/adr](docs/adr/) define the terms and record the main decisions.

## Check your change

Run what CI runs, after your last edit:

```sh
cd server
npm run check          # type check
npm run lint
npm run format:check   # npm run format rewrites
npm run build          # regenerates generated files; commit them if they change
npm run test:coverage
cd ..
mise run lua:lint
mise run lua:test
mise run live:test
node --test "scripts/*.test.mjs"
node scripts/bump-version.mjs --check
```

Add or change a test with every behaviour change, and show it failing before your change. Tests run without Lightroom.

A change to how the plug-in writes masks, or to a develop key's range, needs evidence from a real Lightroom: the live kit in [tests/e2e/live](tests/e2e/live/README.md) builds a throwaway catalog for that. Never run it against your own catalog. If you cannot run it, say so in the pull request and describe what you observed.

## Commits and pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): imperative summary`, at most 72 characters, no final period. Use `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `build`, `ci` or `chore`. Add a body only to explain why.
- One logical change per pull request, against `main`. Pull requests are squash-merged.
- Fill in the pull request template; CI must pass.
- Do not add code comments that restate the code, and keep documents to the current state: history belongs in commits and the release notes.

AI-assisted changes are welcome. You are responsible for every line: read it, run the checks, and be ready to explain it.

## Security issues

Do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## License

Contributions are licensed under the project's [MIT license](LICENSE).
