# Looks and presets

A **look** is a visual goal, a **profile** is how the RAW is interpreted, and a **preset** is a stored group of settings.

## Define a look by its goals

Write the look as goals before numbers: how skin, greens, sky and neutrals should read, highlight roll-off, how open the shadows are, contrast, saturation, grain. When the person has reference images they approve, compare target and reference on exactly those points. Keep technical conditions apart from the look: low light, high ISO or mixed light are modifiers that change noise and white-balance handling under any look, not looks of their own. Do not promote one frame's slider values into a look's definition without seeing them work on other frames.

## Build and compare

Choose a representative frame with ordinary light for the set, then test the look on it and on at least one meaningfully different frame before calling it transferable. Use a light-faithful baseline to show what the look changes. An alternative earns its place by a distinct visual purpose, not a different name. Compare at the same framing and similar apparent brightness; name each one's benefit and cost. Values without a rendered comparison are proposals.

Directions to audition, not recipes; invent another when it serves the picture better:

| Direction | Useful relationship | Main risk |
| --- | --- | --- |
| Light-faithful colour | Existing light, believable material colour | Stays flat if the hierarchy is unresolved; neutral is not automatically good |
| Warm faded film | Soft highlight transition, lifted blacks, restrained greens, warm light | Orange cast, weak dark separation |
| Deep calm greens | Quiet foliage, strong subject separation | Uniform dead greens, shifted green subjects, cut-out edges |
| Cool shadows, amber light | Warm light against a cooler environment | Cyan whites or skin, muddy shadows, teal-orange everywhere |
| Cool stone | Moderate contrast, quiet saturation for concrete and overcast city | Dead brick, wood or evening light |
| Open colour | Gently opened midtones, restrained vibrance for travel and landscape | Lost distance, noisy shadows, loud sky |
| Soft portrait | Gentle highlight curve, restrained saturation, distinct skin and materials | Grey lips, flat face, washed clothing |
| Soft pastel, airy | Low visual density, gentle transitions | Weak subject, chalky highlights |
| Graphic high contrast | Shape, silhouette, decisive light and dark masses | Blocked detail, excessive edge contrast |
| Atmospheric low key | Depth, selective light, night or subdued habitat | The gesture disappears |
| Sculptural monochrome | Gesture, light, form, texture | Colours merge into one grey |

For film-inspired work, name the visible qualities you are after; curves and grain are not a faithful emulation of a film stock.

## Color Grading

Wheels for shadows, midtones, highlights and global, each with hue, saturation and luminance. Balance moves the boundary between the shadow and highlight tints; Blending (default 50) sets how much they overlap without making them stronger; neither affects the global wheel. Grading only adds colour and cannot desaturate; small saturations already show. Adobe's order: white balance and base tone first, then only the wheels you need, then Balance and Blending, global last if at all. Key names are in [tools](../tools/tools.md#write-develop-settings). Starting points to verify on the render: saturations of about 5–15 per wheel; for a warm/cool split, shadow hue around 200–230 and highlight hue around 40–55.

How a look divides between controls: the composite curve carries tone (fade, contrast, roll-off); the wheels carry the colour of each tonal band; HSL carries desaturation and hue shifts of colour families; per-channel curves stay for a tint pinned to a precise tonal point, such as a cross-processed crossover. Do not correct a colour cast with the wheels: that is white balance or a local correction. Color Grading transfers in a preset and through `match_photo_style`; white balance stays per photo.

## Glow (Lightroom Classic 16.0)

Glow diffuses highlights and makes light sources bloom; Range sets which tones it reaches, Spread how far it radiates, Warmth its colour. Styles: diffusion (an overall soft, misty rendering that lowers highlight contrast), bloom (light sources and speculars that radiate), halation (a warm film-like halo around bright edges against dark), motion and streak (directional streaks, set with `GlowDirection`). Inside masks only the amount is per mask; style, range, spread and warmth are shared with the global Glow.

Where it serves: sunrise and sunset, backlit or rim-lit scenes, glints on water, a window or street light at blue hour, airy or low-key looks. Do not use it on a detail-led portrait or wildlife frame as a global effect (it lowers micro-contrast on exactly the bright edges the technical gate reads), on descriptive architecture, to hide softness or noise, or on clipped highlights, which it spreads. Start low (amount about 10–25, Range low, Spread as the main control) and compare with and without on the whole frame and on a detail crop of the brightest important detail.

## Black and white

It serves when gesture, form, texture and light carry the picture and colour adds nothing or distracts: clashing colours in the surroundings, a grey day, mixed light no white balance settles, rim light and silhouettes, fur and feather pattern, architectural rhythm. It does not serve when colour is the subject, or when subject and background differ only in hue at the same lightness.

1. Convert a copy with `set_treatment` `black_and_white` ([tools](../tools/tools.md#black-and-white)) and judge the converted base before adding contrast.
2. The mix is the main control: name the colour families of the subject and its surroundings on the colour version, then move each family's `GrayMixer*` key to separate them (darken green and yellow to sink foliage behind a pale animal, darken blue for a deeper sky, lighten orange for skin or fur). Move in steps of about 15–25. Strong opposite moves on neighbouring hues tear smooth gradients and raise noise: check skies in a detail crop.
3. Then tone: contrast, curve, local light; grain only as a chosen quality.
4. Fringes: Defringe does not act here ([tools](../tools/tools.md#write-develop-settings)); a colour fringe becomes a light or dark edge whose brightness depends on the mix.

## Make a preset from a tuned look

Tune the look on the representative through Lightroom's render, then save only the look's components: curves, HSL and colour relationships, Color Grading, an intentionally chosen profile, grain or vignette when they are part of the style. Usually leave out Exposure, white balance, crop and transform, lens corrections, masks and healing, sharpening and Denoise: they depend on the scene, camera, geometry and output.

- `create_develop_preset` saves the chosen settings as a versioned plug-in checkpoint (hidden from Lightroom's preset panel); give each version a unique name. `compare_develop_presets` diffs it against an approved earlier preset (read one with `get_develop_preset`, by `preset_uuid` when names repeat). `export_develop_preset` writes the file without overwriting.
- A preset the person can see in the Develop panel is made in Lightroom's own New Preset dialog, ticking only the look's groups; File > Import Develop Profiles and Presets imports a compatible preset file; check that it appears in Develop afterwards.
- Before calling a preset done: apply it to test copies (`apply_develop_preset`, with `dry_run` first), read back the persisted settings and look at the renders. Report how far you validated it: saved; imported and visible in Lightroom; rendered and judged on named photos; portable within a stated scope (a typical frame, an extreme of the expected light and an expected failure case). A preset that needs major rescue on most targets is badly scoped: divide it by light instead of adding exceptions.
- `list_develop_presets` with `query` keeps presets whose folder or name holds every word, so `sky` finds Lightroom's built-in Adaptive: Sky group (built-in groups are folders). Apply or read one by the `uuid` it lists: that is Lightroom's own id for the preset, not the UUID written in its `.xmp` file.
- A preset with AI masks recomputes them on each target, and a target whose masks fail keeps the preset and is `unknown` ([masks](../tools/masks.md#ai-masks-judged-on-the-photo)); verify their edges per image.

## Sources

- [Julieanne Kost: Color Grading](https://jkost.com/blog/?p=18167); [Max Wendt: introducing Color Grading](https://blog.adobe.com/en/publish/2020/10/20/introducing-color-grading).
- [Lightroom Queen: what's new in Lightroom Classic 16.0](https://www.lightroomqueen.com/whats-new-in-lightroom-2026-11/): Glow styles and per-mask limits, Projection.
- [PHLEARN / Aaron Nace: creating presets](https://phlearn.com/tutorial/lightroom-classic-presets/): choose components, leave the hero frame's white balance out.
- [Ann and Steve Toon: black and white wildlife](https://www.naturettl.com/black-and-white-safari-photography/).
- [Adobe: apply presets](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/apply-presets.html).
