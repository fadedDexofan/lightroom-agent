# Cull: selecting frames on the right evidence

The target is a set of frames that hold up for their intended presentation, not merely recognisable subjects. Do not invent a numeric quality score; give each frame a reason.

## Name the viewing contract

Before judging, state the output (a web post, a print, a client delivery), its **delivery size** (the pixel size the destination shows), the intended set and the critical content of each picture: an eye, a gesture, an architectural line, a material, an atmosphere.

The whole frame and the critical detail answer different questions. A whole-frame view (`review` preview or an export) shows composition, tone, colour, mask seams and halos. It never establishes fine sharpness, and a larger whole frame tempts the judge to skip detail crops without showing more. Two more limits: preview regions are cut from a capped render, and the client may downscale images before the model sees them, so account for the size you actually receive rather than the size you asked for.

For any crop you judge, record the render size and the crop's pixel box, and the scale at which you actually viewed it.

## The procedure

1. **Whole-frame pass at `cull` (864 px).** Judge subject, moment and composition. Reject only failures visible at that size: a gross smear as [SKILL.md](../../SKILL.md#judge-pictures-on-the-right-evidence) defines it, a cluttered frame, a closed eye where the moment needs an open one. Done when every frame is rejected with a reason visible at 864 px, marked for a detail crop, or marked uncertain.
2. **Detail crop** with `get_photo_detail`, regions placed on the cull preview in the same normalised coordinates. Which region:
   - eye-led subjects (animals, people): the nearest eye with a ring of feathers, fur or skin about three to five eye diameters wide, so the eye-ring edge, the catchlight and the nearest hair or feather structure are in one box;
   - a picture led by something else (flight shape, behaviour, a back view, a building edge): the detail that carries it;
   - a second or third region only when the verdict depends on it: the other subject in an interaction, a bright edge where fringing is suspected, a smooth area to judge noise.

   Typical eye boxes are 400 to 1024 px. Done when every marked frame has its crops, with render size and pixel boxes recorded.
3. **Decide the technical gate at delivery scale.** The crop shows the render at 1:1; the destination shows it at s = delivery long edge ÷ render long edge. Crisp at 1:1: passes, and stays usable for a tighter crop. Soft at 1:1: reduce the saved crop by s (any image tool that resamples) and judge again; it passes only if the criterion holds there, recorded as "passes at delivery scale only", and any tighter crop or format variant needs a new check. Soft at delivery scale: fails. (Untested as a rule.)
4. **Sequences.** Compare the frames' detail crops side by side; they share the 1:1 scale, so magnification matches when subject distance is similar. For a short selection, the default in a **weak sequence** (most frames questionable) is the best one or two that pass the technical gate, and none when none passes; when most frames are good, keep every variation that differs in gaze, behaviour, shape, interaction or setting. An archive or documentary brief may keep more: agree the rule with the person. Similarity alone does not make a good frame expendable.

The detail render has no output sharpening, so a sharpened export looks slightly crisper. When `get_photo_detail` is unavailable, leave fine sharpness unverified and say so: in a read-only session exports are blocked too, and a refusal for another reason needs its cause checked first. In a writable session where the person allows exports, one full-resolution export cut without resampling gives the same evidence.

## Diagnose what the frame contains

Compare subject detail, a smooth area, the focus planes and the sharpest nearby frame before accepting heavy noise reduction or sharpening: noise reduction can make missing detail look clean, and sharpening can put a crisp edge around a soft form.

| Observation | Candidate explanation and the decisive comparison |
| --- | --- |
| Random fine luminance or colour variation over real structure | Noise: compare a smooth area and the structure before and after NR |
| Smooth transitions, missing fine structure, no direction | Defocus: compare focus planes and a sharper neighbour |
| Directional traces, doubled edges | Camera or subject motion: does the surrounding share the direction? |
| Sharp eye, progressively soft near and far anatomy | Depth of field: does the required content still read? |
| Low contrast behind foreground mesh, leaves or flare | Obstruction or scatter: compare positions and the baseline rather than assume a focus error |

These are clues, not certain classifications. **For selection the cause does not matter:** critical detail that is soft at delivery scale fails whatever the cause. Diagnose the cause for capture lessons and for the one correctable case, a contrast veil from obstruction or flare that Dehaze or local contrast may reduce. Do not blame a lens from one photograph. Shutter speed in EXIF is a cheap prior for which frames to check first (slower than about 1/500–1/1000 s for a perched bird, 1/2000 s for action), never proof either way.

## Two gates

**Technical gate:** at delivery size the subject reads, critical detail is sufficient for the intended picture, and the treatment has no damaging halos, plastic texture, clipping, mask seams or geometry losses. For an eye-led subject the nearest eye at delivery scale shows a crisp eye-ring edge and resolved hair or feathers around it; a stretched or doubled catchlight signals motion, and a compact one is a strong positive, not a hard rule. A clear silhouette or intentional motion can pass without a sharp visible eye when that is the picture's purpose. Recognisability alone does not pass a detail-led portrait.

**Editorial gate:** the frame offers a strong moment, form, light, relationship or place and earns its position in the set. A technically fine but weaker duplicate can fail it; a rare moment can justify a documented technical compromise. Being the best of its sequence, or time already spent developing it, does not guarantee a place.

Verdicts: **ready** after both gates pass; **needs work** when a specific feasible correction or a missing check could settle it; **exclude for this use** when the limitation defeats the intended use. Give technical and editorial reasons separately. An exclusion for one use is not a catalog decision: apply Reject, flags and labels by the person's own scheme and the request, and keep your reasons in `set_ai_metadata` when the person wants them recorded.

Keep three things apart in your notes, because they change for different reasons: the selection verdict, the editing need (none, minor global, local work), and how sure you are.

## Bounded verification

For each candidate: one current whole-frame view and the necessary detail crops; a sharper neighbour or baseline when that decides it. Re-inspect after a material correction or an unresolved discrepancy, not indefinitely. Stop when every requested frame has bounded evidence and the uncertain ones are named.
