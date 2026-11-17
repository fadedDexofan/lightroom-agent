# Masks

Use a mask when a global change cannot do the job: a subject that needs light the background must not get, a sky that needs restraint, an eye that needs a touch of clarity. Every mask is checked on the render, at its edges, before you go on.

## Addressing and vocabulary

- Masks and their components are addressed by the ids `list_masks` returns (masks, and per mask its tools with `type`, `subtype`, `part`, `inverted`), or by the ids a creating call returns. Edits can regenerate ids: use the latest ones.
- Sliders use one vocabulary everywhere: the `local_*` SDK names (`local_Exposure` −4..4, `local_Contrast`, `local_Highlights`, `local_Shadows`, `local_Texture`, `local_Clarity`, `local_Dehaze`, `local_Sharpness`, `local_LuminanceNoise`, `local_Defringe`, `local_colorgrade*`, `local_glow`, …), in the `adjustments` of every creating call and in `set_mask_adjustments`. Each range is in the schema; `describe_develop_keys` with a `mask_id` shows where Lightroom's live range differs.
- A new geometry mask without `adjustments`, and every new People or Landscape mask, applies no local adjustment until `set_mask_adjustments`, though on a RAW its creation can trigger a re-render ([below](#mask-writes-re-render-a-raw)).

## Values: read and written in the saved settings

`get_mask`, `set_mask_adjustments`, `set_mask_curves` and every action of `edit_mask_point_colors` work on the photo's saved settings by mask id, without opening Develop or selecting the mask.

- A write changes only the named sliders, channels or swatches and is read back exactly; a changed value adds one history step, and a request with nothing to change can write nothing. If Lightroom changed anything else or stored another value, the photo is put back and the call fails naming what Lightroom stored.
- The reply gives stored values: sliders to six decimals, colour-grade sliders as whole numbers (a hue of 212.4 is stored as 212), Point Color to six decimals.
- **A value write turns the mask on**, as Lightroom's own sliders do: a mask `list_masks` shows as `hidden` is shown again, with a warning. Check before writing to a mask the person switched off.
- Mask curves take at most 16 points; a straight `[0,0,255,255]` is stored as no curve, and a written channel replaces that channel's extended (HDR) curve.
- Point Color: `add` needs `SrcHue`, `SrcSat`, `SrcLum`; like Lightroom's own add it stores the source rounded to two decimals and gives the other fields Lightroom's defaults. A mask holds at most eight swatches, with no repeated source colour; `delete` moves later swatches up. Each range's edges must be ordered (LowerNone ≤ LowerFull ≤ UpperFull ≤ UpperNone), because Lightroom drops every swatch of the mask otherwise.
- Slider changes the person has pending in Develop on that photo are committed first. A read gives the saved state, which can trail a change made by hand a few seconds earlier.
- `delete_masks` removes masks or top-level components from the saved settings in one history step; `delete_empty_masks` removes masks with no tools over many photos, and keeps every mask that has a component, adjusted or not.

These value edits construct nothing, so they need no certification.

## Constructing writes need admission

Writes that construct mask data in Lightroom's undocumented format are guarded: `create_gradient_mask`, `update_gradient_mask`, `create_brush_mask`, `add_brush_strokes`, `create_range_mask`, `create_mask`, `create_mask_batch`, `combine_mask`, and a full `copy_develop_settings` that carries masks.

- They run on the throwaway catalog of the project's live test kit. On any other catalog they need a certification run on that machine that passed for the running Lightroom version and build and the photo's process version.
- `get_mask_write_admission` (with `photo_id`) reports admitted or not and why, without writing.
- A refusal names the reason; after a Lightroom update the guarded writes refuse until certification is rerun. Report that to the person instead of working around it.
- They check what they construct against the certified format, leave every other mask as Lightroom stored it, read the whole mask list back and roll back on a mismatch.
- `list_masks` reads the saved settings without Develop, newest mask first; an empty list means the photo holds no masks. `invert_mask` still acts in Develop on the active photo: it waits up to 5 s until Develop lists as many masks as the saved settings hold, and fails with nothing changed while it lists fewer: the masks are not loaded yet, or an alert such as "No sky detected" is open from the person's own work. Click OK in Lightroom if an alert is open, then call again.

## Positions

Gradient, brush and range positions are normalised 0..1 in the frame of the rendered preview, as `get_photo_preview` shows it: after crop, straighten and displayed orientation, origin top-left, y down. Read them straight off a preview; the tools convert to the frame Lightroom stores and answer in the preview frame. Gradient widths and heights are fractions of the preview's width and height, brush radius a fraction of its longer edge (default 0.14; dabs are spaced at most half a radius apart).

Lightroom stores masks before the crop, so a mask stays on the same part of the photo when the crop changes; re-read a mask's geometry after a crop change before reshaping it. With Upright, a manual Transform or manual distortion active, a position can land up to about 0.05 of the frame away near the edges (observed on Lightroom Classic 16.0); the write answers with a warning: check the render and move the geometry by the offset you see.

Range masks: luminance and depth bands at least 0.01 wide (depth needs a photo with a depth map); a colour range takes exactly one sample (a second one crashed Lightroom), given as Lightroom's own per-photo l, a, b rankings, not sRGB: read them from a colour range made in Lightroom, where `list_masks` gives one entry in the tool's `range.samples` per click (use one sample per range you create, adding more ranges to the mask for more samples), or copy a single-sample range with `copy_sample_from`.

## AI masks judged on the photo

Four calls write AI masks: `create_mask` (Subject, Sky, Background, People parts, Landscape categories), `create_mask_batch` (one Subject, Sky or Background mask on up to 200 photos), `combine_mask` (add, subtract or intersect a Subject, Sky or Background component) and a full copy with AI masks. Each writes the new mask into the saved settings, lets Lightroom compute it with one Update AI Settings, and judges its own masks on the photo:

- computed: `done`;
- Lightroom reports finding nothing, or could not compute: the new masks are removed, the photo's own masks are restored exactly, and the call fails naming the failed components; no alert needs dismissing;
- if that same compute also refreshed other settings (stale Lens Blur depth, Enhance filters, Remove areas, an adaptive profile), those are not rolled back: the call is `unknown` and names them, and the masks are as before;
- anything on the photo still computing 15 s later: `unknown`, and nothing more may be written to that photo until a read shows the compute finished;
- a preset is the exception: `apply_develop_preset` keeps the preset and answers `unknown` (check the masks in Develop before writing to the photo), and an apply that stops ends the batch with the rest in `remaining`;
- existing AI masks are never written, but the compute covers the whole photo: a warning names an existing mask whose result changed or was already failed. Render it before going on.

**Done is not found.** Lightroom does not always report an empty result (a Sky on a frame without sky computed a mask, observed on Lightroom Classic 16.0), and a computed mask can miss what matters. Verify every AI mask by giving it an obvious adjustment and comparing previews, or by its first real adjustment. An AI mask was in the preview about a second after the call (observed on Lightroom Classic 16.0); if a mask shows no effect, fetch the preview again before concluding.

`combine_mask` worked in all three forms on a dense subject with Exposure −1 (observed on Lightroom Classic 16.0): add darkened the subject like Subject alone, subtract left the subject and darkened the rest, intersect darkened only the overlap. Intersect is stored as a subtracted, inverted component. People parts: each part becomes its own mask, and there is no single-person choice (Lightroom masks the first person).

`invert_mask` `in_place` flips one component; `copy` makes Lightroom's inverted duplicate and writes every value of the source onto it. Use the returned `mask_id`.

## Mask writes re-render a RAW

On a RAW, the first gradient or brush mask, even one without adjustments, can make Lightroom re-render with a fine texture-level difference, and so can a parametric mask write on a photo that already holds an AI mask. The difference touched a fifth to a third of the pixels by more than 0.01 of full scale, with a mean near zero and no region (observed on Lightroom Classic 16.0, not on non-RAW files). After a mask change, wait for a fresh stable preview and compare regional tone as well as detail; do not assume that every unexpected change has this cause. Judge sharpening and noise reduction on the final state.

## Check every mask on the render

Look at the edges the mask had to find: hair, whiskers, feathers, fur against foliage, glass, thin branches against sky, the gap between a limb and the body. A successful selection or a mask overlay does not prove the final edge. Look for halos, a cut-out look, colour contamination and a background mask that treats very different areas the same. For a batch, inspect representatives plus every failed or exceptional target; do not substitute reading slider values for looking.
