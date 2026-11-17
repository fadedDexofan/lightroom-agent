---
status: accepted
date: 2026-11-17
---

# Writes that construct masks are admitted only on a Lightroom build certified on this machine

## Context

Mask geometry and AI mask components have no SDK call. They are written through Lightroom's undocumented `MaskGroupBasedCorrections` setting. Upstream allowed those writes only on a list of tested Lightroom versions in source. Lightroom updates itself, so the list refused every such write the day 16.0 shipped, and adding a version to the list proves nothing about it.

## Decision

Constructing writes are the ones that add a mask entry or component: gradients, brushes, range masks, Subject, Sky, Background, People and Landscape parts, combines, and full copies that carry masks. Outside the live kit's throwaway catalog they are admitted only when a certification record names the running Lightroom version and build and the photo's process version.

The record is written by one live-kit command, only after its suite passed on a throwaway catalog on this machine, with read-back and render checks. On the throwaway catalog, recognised by the kit's marker file, constructing writes are always admitted, because that is where certification runs.

Writes that construct nothing need no admission: changing a mask's adjustments, curves or Point Color swatches, and deleting masks or components. They address the mask by id and are confirmed by an exact read-back of the whole mask array; Lightroom's own entries must come back byte for byte, or the array is restored.

Every write of the array keeps its own checks. The pinned format is checked on what the call constructs or changes. The whole array is written in one gate, read back, and restored on a mismatch, and the restore is confirmed by an exact read. Read-back proves persistence. The live suite also checks selected renders and the constructions that are known to crash Lightroom: for example, a colour range written with two samples crashed Lightroom and crash-looped the catalog on reopen.

## Considered options

- Keeping the version list and adding 16.0 after a manual check. Rejected: each update would block masks until a code change, and admission would rest on someone remembering to test.
- Admitting by schema evidence alone. Rejected: it cannot see a crash or a rendering change when the keys are the same.
- Requiring certification for value edits too. Rejected: they construct no mask component, and the exact read-back of the whole array confirms them.
- Letting Lightroom create each mask through Develop and editing only known fields. Rejected: it acts on the mask selected in Develop, which the user can change during the call.

## Consequences

- After every Lightroom update, including a build change inside one version, constructing writes are refused on other catalogs until certification has run again. Value edits and deletions keep working. The refusal names the running build, the certified build and the command.
- Admission is bound to the Lightroom build, not the plug-in revision. Rerun certification after installing a changed plug-in.
- The record belongs to the machine: it lives beside the plug-in's token in the user's configuration directory. A record that cannot be read admits nothing.
- Certification is as strong as the suite. A mask kind the suite does not exercise is listed in the record as not exercised and is still admitted by the build match.
