---
status: accepted
date: 2026-11-17
---

# Every tool answers in one result envelope, and its class comes from what the call wrote

## Context

Different response shapes made retries unsafe: a failed write looked the same as a write whose result was unknown, so an agent could not tell whether to retry or to read the photo first. A retry after an unknown result could duplicate masks and virtual copies.

## Decision

Every tool call returns one envelope with one of four outcomes: `done`, `partial`, `failed` or `unknown`. The server derives the outcome from what the plug-in reports. A handler returns what it confirmed (`data`) and lists what it did not (`failed`, `unknown`, `not_found`, `remaining`); it cannot state an outcome.

When a call stops, `failed` or `unknown` is decided by one rule over a per-call write ledger:

- A write is recorded where it can no longer be taken back. A catalog write gate whose writes Lightroom rolls back on an error is recorded when the gate returns.
- A write Lightroom does not roll back is recorded before it is made: a Develop controller call, an import, a preset, a file, an export. One table lists which SDK calls a failing gate rolls back, each with the observation behind it. A call that was never observed counts as not rolled back.
- A write is voided only by a read that shows its effect undone: a read of the store the write changed, made after the write can no longer land, covering everything it may have changed. A read through Develop never voids a write to the saved settings.
- No live entry: `failed`, nothing changed. Any live entry: `unknown`, and the error names what was written. Each item of a multi-photo call is classed by its own writes. A reply with neither data nor unknown items is `unknown` when the call left a write.
- A write that was sent and whose reply was lost is `unknown`. A read, or a call that was never sent, is `failed`.
- `isError` is true for every outcome except `done`. Returned photo identities are catalog-local strings, and a row's primary identity is `photo_id`.

## Considered options

- Per-tool response shapes, documented one by one. Rejected: each shape needs its own retry rule, and every new tool adds one.
- Letting each handler choose the class where it raises an error. Rejected: a handler cannot know there what earlier steps of the same call wrote, so the answer was wrong whenever an earlier step had written.
- Treating every error after the first write as `unknown`. Rejected: Lightroom rolls back most catalog gates on an error, so the honest answer there is `failed`.

## Consequences

- A partial batch sets `isError`. Clients that stop on `isError` must read `outcome` and `remaining` instead of treating the call as lost.
- A `failed` call can still leave its write and its restore as two steps in Lightroom's undo history.
- Every new SDK write goes through the wrapper that records it; a test scans the plug-in for Develop controller writes made outside it. A call whose rollback was never observed answers `unknown` on an error until it is observed.
- When Lightroom's AI compute runs during a call, the call is voided only if the photo's whole develop settings read back as they were, because the compute is photo-wide.
