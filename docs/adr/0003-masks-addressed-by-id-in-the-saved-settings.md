---
status: accepted
date: 2026-11-17
---

# Mask edits address the saved settings by mask id, not Develop's selection

## Context

The SDK's mask calls (`LrDevelopController`) act on the photo open in Develop and on the mask selected there. Selecting a mask, checking the selection and then writing always leaves a window: the user, Lightroom or a pending Develop edit can change the selection or the settings between the check and the write.

## Decision

Mask value edits, creation, combine and deletion address the photo and the mask's `CorrectionID` in the photo's saved `MaskGroupBasedCorrections`. The call reads the array inside its write gate, changes the named entry, writes the whole array and reads it back exactly. AI masks (Subject, Sky, Background, People and Landscape parts, combine) are written as a seed component in the same way, Lightroom's Update AI Settings computes them, and the call judges them on the photo by their stored state.

These facts were observed on Lightroom Classic 16.0 before the code was written:

- a saved write by id is kept and reads back exactly;
- slider values are stored to six decimals and colour-grade values as whole numbers;
- a written seed equals the component Lightroom's own command makes, after the compute, in every field but the ids;
- Lightroom resends its own entries unchanged in a whole-array write;
- a pending Develop edit overwrites a saved write about 2 s later unless Develop's pending edits are committed first.

## Considered options

- Keeping the selection and adding checks around it. Rejected: every check leaves a window between the check and the write.
- Using the controller for value edits and the saved settings only for geometry. Rejected: two ways to change one mask's values, and the controller path still depends on the selection.

## Consequences

- The call commits pending Develop edits before writing. Do not edit the same photo in Lightroom while a call runs: an edit made during the call may be lost.
- "Nothing found" for an AI mask is Lightroom's stored `ErrorReason` 1. The call refuses and puts the masks back; no alert appears.
- The fields Lightroom computes for the photo in an AI component (digests, sizes, origin, reference point, error) are never compared and never copied, so a mask copied to a photo of another size or orientation is computed for that photo.
- A constructing write names every entry and component it adds: `GuardedMaskWrite.apply` gives each one without an id a `CorrectionID` or `MaskID` in Lightroom's form (an uppercase dashed GUID) and requires it back exactly, so the reply's ids work in the next call. Lightroom Classic 16.0 keeps ids written this way; it assigns its own only some seconds after a write that carries none. Existing ids, a full copy's included, are never changed. While a mask or top-level component on the photo has no id yet, every whole-array write refuses and writes nothing, and a full copy checks before its first write: resent before Lightroom names it, that mask may not come back exactly, and Lightroom names it within seconds.
- Listing masks reads the same saved array: `list_masks` opens no Develop session and names each component in the words `create_mask` uses.
- Inverting a mask and Develop's live slider ranges for a selected mask still use the Develop controller. Spot tools address spots by index under the selection.
