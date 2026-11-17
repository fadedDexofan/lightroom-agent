# Security policy

## Supported versions

lightroom-agent has no releases yet. Security fixes go to `main`; use the latest commit.

## Reporting a vulnerability

Report it privately through GitHub: [open a security advisory](https://github.com/fadedDexofan/lightroom-agent/security/advisories/new). Do not open a public issue.

Include what an attacker can do, the steps to reproduce, and your Lightroom Classic version, operating system and lightroom-agent commit. The maintainer replies as time allows and coordinates disclosure with you.

## Scope

The plug-in listens on localhost and accepts only requests carrying the token it writes to `~/.config/lightroom-agent/token`. Relevant reports include:

- a way for another local user or process to send requests without the token, or to read the token;
- a tool that writes outside what it is asked to change: other photos, other files, or the catalog when read-only mode is on;
- a path a tool argument can steer outside its intended folder.

A process running as the same user can read the token by design; that is outside scope.
