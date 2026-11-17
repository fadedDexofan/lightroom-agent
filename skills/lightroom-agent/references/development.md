# Development: a closed loop on Lightroom's own render

Judge colour and tone only on Lightroom's render of the RAW (a preview or an export with current settings). A camera JPEG beside the RAW can help with composition, focus and expression, not with colour.

## Terms

- **Base development:** the per-image correction that makes a RAW look right before any look: profile, white balance, tone, detail, lens and geometry. It belongs to one photo or one consistent scene.
- **Look** and **preset:** see [looks](looks.md); a preset can carry a look or a base, and its name does not say which.
- **Lab copy:** a virtual copy made only to test a treatment, kept apart from the master's edit.

## Cluster before editing

Group the set by lighting and intent, not by folder or event: open shade, direct sun, backlight, warm or mixed interior light, stage or night light, high ISO. Pick one representative per cluster with ordinary light for that cluster, and keep difficult outliers separate. Do not build one universal treatment for visibly different light.

## Passes on the representative

Preserve the starting edit first (snapshot or named virtual copy). Then change one concern per pass and look at a fresh `review` preview after each:

1. **Baseline.** Read the settings, take a preview, write down the intent in one sentence and what must stay true.
2. **Technical correction.** White balance, Exposure, Highlights, Shadows, Whites, Blacks: usable exposure, protected highlights that hold information, plausible shadows. No creative colour yet. Lens profile and Remove Chromatic Aberration belong here, as part of the camera and lens base.
3. **Geometry.** Upright or manual transform, then the final crop ([architecture and landscape](architecture-landscape.md#upright-and-projection), [foundations](foundations.md#intent-attention-and-frame)). Solve geometry before the final crop.
4. **Tonal shape.** Contrast, curve, local relationships. Describe the tonal goal (soft highlight roll-off, deep but open blacks) before setting numbers.
5. **Colour.** White balance refinements, then bounded HSL changes on visible subjects (skin, foliage, sky, neutrals). Do not map a scene label to arbitrary HSL values.
6. **Local light.** Masks where a global change cannot do it ([masks](masks.md)).
7. **Look,** if one is wanted ([looks](looks.md)).
8. **Detail and noise.** Judged on detail crops of the final state: sharpening, Texture, noise reduction. Low light is a modifier on any look, not a look.

Make one or two render-and-inspect cycles per pass. Stop when changes oscillate, the visible gain becomes negligible, or what remains is local or a matter of the person's taste; for the latter, show alternatives instead of deciding. Keep a short log per pass: values before and after, what improved, what got worse, accepted or reverted.

## Order of AI and Enhance work

Run Denoise early, before AI masks and Content-Aware Remove, then revisit sharpening and Texture (Adobe's guidance since Lightroom Classic 12.3). Denoise computes in the background after the tool reports applied. Do not run heavy processing across an unculled shoot by habit: cull first, then spend compute on the frames that stay. More pixels from Super Resolution are not more optical detail.

## Detail without damage

Inspect the eye or key detail, fine structure and a smooth area before accepting noise reduction. The amount depends on exposure, shadow lift, subject size and file, not only ISO; preserve structure rather than maximise cleanness. Texture works on mid-scale detail and barely raises noise; Clarity acts on broader structure and shifts tone and saturation and can look gritty. Sharpening's Masking slider keeps sharpening off smooth areas (sky, walls, skin) but a high value also withholds it from fine hair and feathers; lower Masking plus negative Texture in a background mask is the usual alternative. No slider restores focus. Judge sharpening on the final state, because mask writes on a RAW re-render it at texture level ([masks](masks.md#mask-writes-re-render-a-raw)).

## Highlights, shadows and mixed light

A Develop histogram shows the current rendering, not sensor clipping. A reversible Exposure or Highlights test shows whether bright detail and plausible colour remain; blank white turning blank grey is not recovered detail. When information is absent, consider allowed clipping, a silhouette, another crop or another frame. Lifting every shadow flattens the scene and shows noise; shadow visibility is not the objective. Extreme highlight recovery with strong shadow lifting can flatten tonal separation into the grey "HDR" look: inspect the result.

Choose white balance by the scene's intent: a fixed Kelvin number is not a transferable mood. Mixed sources can keep their character when the main subject is convincing; one white balance cannot neutralise every source, so correct an interfering cast locally when it matters.

## Copy across the cluster

Show the representative's before and after, and get agreement when the direction is the person's choice, before copying. Then copy only the keys meant for the cluster: `copy_develop_settings` with a `settings` list, or a preset made from the look ([looks](looks.md#make-a-preset-from-a-tuned-look)). Exposure, white balance, crop, transform, lens, masks and detail are per photo unless the light is truly the same; evaluate them on each target. Read back every target and look at its render; if several targets need major rescue, reconsider the cluster or the look; handle an isolated outlier separately.

## Final check

Read back changed values and snapshot or copy identity, then look at a fresh whole-frame render plus enough subject detail: mask edges, clipping, colour contamination, geometry and crop losses, noise and halos, at the delivery size. Do not repeat a successful check without a new change or concern. Report as [SKILL.md](../SKILL.md#the-workflow) says, separating executed changes from proposals.
