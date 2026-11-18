# Tools: mechanics that decide whether a call does what you meant

Read the tool's own description before a call you have not made in this session; it states arguments, rules and outcomes exactly. This file adds how the tools fit together and what has been observed.

## Connection, toolsets and read-only mode

- The server talks to a plug-in inside a running Lightroom Classic. On a connection error read its text: check that Lightroom runs with the plug-in enabled, that ports match and the token is readable. Several clients normally share one server that owns the plug-in connection; an owner that stops answering needs diagnosis. Tell the person instead of retrying in a loop. Lightroom loads a plug-in only when it starts, and only the server elected to own the plug-in connection installs its plug-in, when it becomes the owner; a follower and a CLI call never install. If the error says Lightroom has loaded a different plug-in build, it names the loaded build and the one this server expects: if the intended build was installed or repaired, ask the person to restart Lightroom; otherwise ask them to quit the connected clients, run this build's `install-plugin`, check that it reports installed, replaced, repaired or already this build, restart Lightroom and reconnect. Another client running a different lightroom-agent build is one possible cause: then they should use one build in every client. If the error says this server's build does not match its plug-in folder, ask them to rebuild the checkout (`npm --prefix server run build`) and restart the client. If it says the installation is damaged or has no bundled plug-in, ask them to reinstall lightroom-agent and restart the client.
- Toolsets: core is always on; `develop`, `masks` or `all` add the rest. They are fixed at server start, so a changed setting needs a restarted server and does not add tools to a running session.
- Read-only mode hides and refuses every write, including exports, `export_photo_metadata`, `export_develop_preset` and `get_photo_detail`. Reads that use Develop (`describe_develop_keys`, `get_lens_blur`, `list_spots`) can still switch the module, photo or selected mask briefly, then restore the view; they change no photo data of their own, though like every call they commit a pending Develop edit first.
- `undo_last_step` undoes the last shared history step, which may be the person's or another plug-in's, and Lightroom can merge recent plug-in writes into one step. Use a snapshot or a recorded value to go back instead.

## Identify photos

- Resolved ids are catalog-local strings in every reply (`not_found` and `remaining` echo the inputs as given); an input takes the id (number or digit string) or an absolute file path. Prefer ids: a path names the master, never a virtual copy.
- A virtual copy keeps its master's filename. `get_photo_metadata` reports `is_virtual_copy` and `virtual_copy` (`master_photo_id`, `copy_name`, or a master's `copy_photo_ids`), and `stack` (`position`, `is_collapsed`, `top_photo_id`, `member_photo_ids`).
- `search_photos` does not see the hidden members of a collapsed stack; its warning names the stack tops on the page. Read a top's `member_photo_ids` to reach them.
- Follow pagination (`limit`, `offset`, `has_more`) until the set is complete.

## Outcomes, ordering and time

The outcome table is in [SKILL.md](../../SKILL.md#read-every-replys-outcome). In addition:

- `failed` covers every problem found before anything was written: a broken argument rule (each description lists its "Rules:", answered as "Invalid arguments for …"), an unknown id, a value out of range, a rule between develop keys. Fix the argument; nothing needs repair.
- `unknown` names what Lightroom reported written ("written before this stopped: …"); a reply lost in transit carries only its error. In a batch each photo is classed by what was written for it. A tool that wrote in Develop and then put things back (an inverted mask copy, a spot update, Denoise) still answers `unknown`: read the photo before retrying.
- Develop calls queue in arrival order across every client, and so do reads of a photo's develop settings, masks or snapshots (`get_develop_settings`, `get_crop`, `list_masks`, `get_mask`, `get_photo_detail`'s first step and the like), so a read never lands inside a running Develop call. A call whose turn does not come within its budget fails without effect: call again after the Develop call before it has answered. Catalog reads and writes, previews and exports do not wait. A call that timed out keeps the turn until Lightroom finishes it or 60 s pass; after that it can overlap the next call and stays `unknown`. Send one call, wait for its reply.
- A catalog write waits up to 10 s while Lightroom or another plug-in writes; a busy catalog fails a call that had written nothing.
- Batch tools stop starting photos before their time budget ends and list the rest in `remaining`; each description states its budget. Resend exactly `remaining`; never restart the whole list. A preview batch may list the item it was fetching; previews are read-only and safe to resend.
- Tools that open a photo in Develop restore the person's module, view source and selection afterwards. Every call but a ping first commits a slider change the person has pending in Develop, so do not run calls while the person is editing a photo.

## Read the state

- `get_develop_settings` is the one develop read, by the same SDK names `set_develop_settings` writes; `keys` is required for more than one photo, and `absent` lists keys a photo does not carry. A `ToneCurvePV2012*` channel reads the curve Lightroom renders (its extended HDR curve when there is one); name `ExtendedToneCurvePV2012*` to read that field as stored.
- `describe_develop_keys` lists each key's kind, the range the tools enforce and Lightroom's live range for this photo, marked `differs` where they disagree; local slider ranges need a `mask_id`. Keep values inside the live range; a value Lightroom stores differently comes back in `adjusted`.
- `get_crop` reads the crop as `set_crop` states it: the rectangle in the photo as displayed before any crop, the straighten angle and the cropped frame's size in pixels. It opens no Develop.
- `summarize_develop_settings` gives medians and ranges by camera and ISO for rated photos, useful to learn a person's habitual base before proposing values.

## Write develop settings

- `set_develop_settings` refuses a value outside its range before writing; Lightroom would otherwise clamp it or reset the setting to its default.
- It also refuses combinations that break a rule: crop edges, each Defringe hue pair at least 10 apart, `GlowStyle` only with Glow above 0, `GlowDirection` only with style 3 or 4, `GrayMixer*` only on a black and white photo, point curves of 2 to 16 points starting at input 0, ending at 255 with rising inputs.
- A number finer than Lightroom keeps is rounded, with a warning.
- About a second after the write the tool reads the keys back. A value stored differently is listed in `adjusted` and the outcome is `partial`; a key the photo held and lost makes it `unknown`. A key the photo cannot store at all, such as a RAW's Temperature and Tint on a JPEG, is listed in `not_stored` with a warning.
- Never write the raw `Crop*` keys: they are in the frame Lightroom stores, not as the photo is displayed. Use `set_crop`. Never invent key names: the schema lists every key the tool accepts.
- Colour Grading's shadow and highlight hue and saturation, and Balance, are stored under the `SplitToning*` names (`SplitToningShadowHue`, `SplitToningHighlightSaturation`, `SplitToningBalance`); their luminance (`ColorGradeShadowLum`, `ColorGradeHighlightLum`), midtones, global and blending under `ColorGrade*`.
- Keys that need their own tool: `ConvertToGrayscale` (`set_treatment`), Denoise (`apply_denoise`), Lens Blur (`set_lens_blur`), process version (`set_process_version`), crop (`set_crop`). Profile selection has no tool: use a preset that carries the profile, or Lightroom's UI.

Groups observed on Lightroom Classic 16.0 (range, read-back and a render that changed as expected, on test images):

| Group | Keys |
| --- | --- |
| Chromatic aberration | `AutoLateralCA` 0/1 (Remove Chromatic Aberration); `LensProfileEnable` 0/1 |
| Defringe | `DefringePurpleAmount`, `DefringeGreenAmount` 0..20; hue ranges `DefringePurpleHueLo/Hi`, `DefringeGreenHueLo/Hi`. Renders nothing on a black and white photo |
| Color Grading | as above; hues 0..360 (about 45 amber, 120 green, 220 blue, 300 magenta), saturations 0..100, luminances and balance −100..100, `ColorGradeBlending` 0..100 (default 50) |
| Black and white mix | `GrayMixerRed`, `GrayMixerOrange`, `GrayMixerYellow`, `GrayMixerGreen`, `GrayMixerAqua`, `GrayMixerBlue`, `GrayMixerPurple`, `GrayMixerMagenta` −100..100 |
| Upright and transform | `PerspectiveUpright` 0–4 ([modes](../genres/architecture-landscape.md#upright-and-projection)); `PerspectiveVertical`, `PerspectiveHorizontal`, `PerspectiveAspect`, `LensManualDistortionAmount` −100..100; `PerspectiveRotate` −10..10; `PerspectiveScale` 50..150 |
| Glow | `Glow`, `GlowRange`, `GlowSpread` 0..100, `GlowWarmth` −100..100, `GlowStyle` 0 diffusion, 1 bloom, 2 halation, 3 motion, 4 streak, `GlowDirection` −180..180 |
| Projection | `ReshapeAmount` 0..100 |

Not settable and not to be invented: legacy `ChromaticAberrationR/B` and `Defringe` (they read back and render nothing), profile, Upright Guided.

## Crop

- `set_crop` takes either a `rectangle` (left, top, right, bottom, 0..1) or an `aspect` ({width, height}, such as 4:5 or 1.91:1) with the largest frame that fits around a `center`, optionally reduced by `scale`, each with an optional straighten `angle` (−45..45; positive turns the frame clockwise, so the picture turns counter-clockwise).
- `relative_to: "photo"` (default) means the photo as displayed before any crop; `relative_to: "crop"` means the current crop as a preview shows it, and the angle adds to the current one.
- Before writing, the tool refuses a frame that would leave the photo (naming the largest that fits), a tall or wide frame whose turned corners would cross, and a total angle outside ±45. With Upright, Transform or manual distortion active the frame can sit up to about 0.05 of the photo away near the edges, with a warning.
- To re-crop: read and keep `get_crop`. A tighter frame inside the current crop is one `set_crop` with `relative_to: "crop"`, placed on an ordinary preview. A frame that needs area outside the crop needs the whole photo first, because previews show only the current crop. Set `set_crop` with rectangle 0, 0, 1, 1 and angle 0 (a full rectangle at any other angle leaves the photo and is refused) and look at a fresh preview. Then write the new frame with `relative_to: "photo"` and the intended angle; the tool checks that it fits. That preview is unrotated, so place the new frame's centre and size on it and let the angle turn the frame around that centre. To undo, write the kept rectangle and angle back.

## Black and white

`set_treatment` switches between `color` and `black_and_white` through Lightroom's own conversion. On a RAW it swaps the profile (Adobe Color to Adobe Monochrome) and removes or restores the HSL keys (observed on Lightroom Classic 16.0: also Saturation and Vibrance, and Monochrome brings its own tone curve and a little Clarity); the reply reports `convert_to_grayscale` and `profile {before, after}`. No tool writes a profile back, so a profile the conversion lost cannot be restored through the tools: convert a virtual copy rather than a master whose profile matters. `match_photo_style` fails a target whose treatment differs from the reference; convert it first.

## Snapshots, virtual copies, history

- Snapshots are stored per master: a virtual copy's snapshots are listed on its master and every copy, and deleting one through a copy deletes it for all. `apply_develop_snapshot` changes only the photo named. Name a snapshot after the photo and the moment (filename plus "before grading") and check the name before applying or deleting.
- `create_virtual_copies` names each copy `copy_name`, returns `copies` (`master_photo_id`, `copy_photo_id`) and keeps copies made before a failure in its data; a photo whose copy has another master or cannot be read back is `unknown`, and its reason names the copies created, so they can be found and removed. A new copy joins its master's stack (observed on Lightroom Classic 16.0). Edit through `copy_photo_id`. Also observed on Lightroom Classic 16.0: the call occasionally fails inside Lightroom without creating anything; read the master's `copy_photo_ids` before one retry.
- `match_photo_style` makes a recovery snapshot per target before writing; `apply_develop_snapshot` restores it.

## Presets, copying and automatic adjustments

- `copy_develop_settings` with a `settings` list copies only those keys and leaves the target's masks and process version alone (`ProcessVersion` cannot be named); without one it copies everything including masks, which then replace the target's masks through the guarded mask write (and a source without masks removes the target's masks). A full copy leaves out Enhance results (Denoise, Raw Details, Super Resolution); a RAW's white balance does not reach a non-RAW target (`not_stored`); a target on another process version first gets the source's, as its own history step when masks are copied or removed; if the mask step then fails, that process version stays written and the target is unknown: read it before retrying. Use `dry_run` first; it lists what would change. For a set, always name the keys.
- `apply_develop_preset` and `copy_develop_settings` compute AI masks on each target ([masks](masks.md#ai-masks-judged-on-the-photo)).
- `match_photo_style` transfers the global look (tone, colour, curves, detail, noise, grain, vignette) and leaves out what describes one photo: crop, perspective and Upright, white balance, lens corrections, local adjustments.
- Saving, comparing and exporting presets: [looks](../workflow/looks.md#make-a-preset-from-a-tuned-look).
- `apply_auto_adjustments` gives no completion signal: a photo where no change is seen within 8 s is `unknown`; read its settings before writing to it.
- `apply_denoise` computes in the background; "applied" does not mean every preview has caught up. An unsaved change answers `unknown`: read the Denoise state before retrying.
- `set_process_version` can change the look and refuses downgrades of photos with masks; `reset_develop_adjustments` removes every edit, crop and masks included. Both need the person's word. A reset answers `reset` only when a read 4 s later shows the photo's edits changed; an `unknown` photo may not have been reset (or had nothing to reset): read it before grading on top, and resend only after that read.

## Previews and detail crops

- `get_photo_preview` returns one render, whole or a `region` of the rendered frame (after crop, straighten and orientation). Named sizes: `cull` (864 px, the default) and `review` (1728 px); a number 64–2048 asks for that edge, and a whole frame is capped at 2000 px. `get_photo_previews` returns up to 20 photos (default edge 256).
- `width`/`height` are the pixels sent; the server never enlarges, and `scaled_by_server` only means Lightroom answered larger and the server reduced it. Right after a change Lightroom sometimes has no preview pixels; the call asks again for about 20 s and then fails: ask again later, and check whether the photo is the one active in Develop.
- `get_photo_detail` cuts one to four regions (normalised in the displayed, cropped frame) from a full-resolution render with the current settings, one rendered pixel per returned pixel. `max_edge` defaults to 1024 (at most 2048); keep it within what your model sees without downscaling. A region larger than `max_edge` is refused before rendering with the largest normalised size this photo allows: shrink to it. Each call adds one Export history step and the exported mark (so `summarize_develop_settings`' `exported_only` counts it); settings and pixels stay unchanged ([SKILL.md](../../SKILL.md#judge-pictures-on-the-right-evidence) for one call per photo). It shares a lock with `export_photos`: while one runs, the other is refused, not queued.
- `get_photo_stats` and `find_duplicate_groups` measure previews: useful to flag frames, never to rank sharpness or prove clipping. Duplicate groups are not reject lists, and similarity says nothing about which frame is better.

## Exports

- `export_photos` writes files: give a deliberate, new `destination` folder or a usable export preset (`list_export_presets`), `format`, an explicit `quality` and `on_existing` (`skip` or `rename`; `overwrite` is refused into catalog folders). `width`/`height` are maxima; Lightroom does not enlarge.
- The reply lists the written `files`; inspect those files, not the folder listing. A photo whose export session failed after it started is `unknown` and may carry an Export history step. Export in small batches, one call at a time, and inspect the folder before any retry.
- Keep exports to what the task needs and say where they are; never bulk-export a catalog to look at it.

## Annotations and metadata

- `set_rating_and_flag` (rating 0–5, flag `pick`, `reject` or `none`), `set_color_label` (`red`, `yellow`, `green`, `blue`, `purple`, `none`). Reads report the same words.
- `set_ai_metadata` stores a private score and reason per photo in the catalog, invisible to IPTC, keywords and exports: the place for your reasons. Read `get_ai_metadata` before replacing earlier notes.
- `set_keywords` with a dedicated parent (such as `AI Keywords`) keeps a tagging batch removable with `remove_keyword_subtree`.
