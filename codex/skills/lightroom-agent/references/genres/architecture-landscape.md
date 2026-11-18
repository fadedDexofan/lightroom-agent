# Architecture, city and landscape

Tell a descriptive architectural image from an expressive one, and an atmospheric landscape from a demand for maximum detail.

## Geometry has different causes

Camera position sets the relative size of near and far things; a lens profile cannot restore a distant mountain's size. Camera tilt makes verticals converge. Barrel or pincushion distortion bends straight lines. Rectilinear projection stretches shapes near the edges of a wide frame even when lines are straight. Diagnose which one you face before correcting. Establish true lines first: a sloping street is not a horizontal, trees on a hillside need not be vertical.

For a descriptive facade, compare parallel verticals and faithful proportions; for a view up a tower, convergence can carry the height. After a correction check window shapes, width, people and circles at the edges, the roof and base, and the context. Correcting perspective costs image area and resolution at the stretched corners, and it does not move the camera: leave a margin around the subject when shooting.

## Upright and Projection

Upright modes, written as `PerspectiveUpright`: 1 auto (verticals and horizontals while keeping as much of the image as possible), 2 full (both, the strongest correction and crop), 3 level (horizon only), 4 vertical (verticals only), 0 off. Guided is not available through the tools. Lightroom applies the lens profile first, so turn it on before Upright. On test images (observed on Lightroom Classic 16.0) auto left part of a convergence, full and vertical made edges vertical, level levelled a horizon, and on a grid without real structure every mode rotated the frame wildly: weak or misleading lines produce a wrong correction.

Procedure (verify each step on the render):
1. **Decide whether to correct.** A frame without clear straight lines (trees, mountains, a curved interior) gets no Upright.
2. **Base first:** snapshot, lens profile and Remove Chromatic Aberration on, and keep the crop from `get_crop`.
3. **Mode:** vertical for a building shot tilted up with a roughly level horizon; auto if vertical crops too much or bends the horizontals; full when verticals and horizontals both converge, expecting the largest crop; level when only the horizon is tilted and the verticals should keep their convergence.
4. **After every Upright write** read back the setting and the crop, and look at a fresh `review` preview: verticals parallel or with the intended residual, no rotation or warp, blank wedges at the edges, roof and base kept, edges not stretched. Take a detail crop of a top corner: the stretch also softens it.
5. **Crop away the blank edges** with `set_crop` and `relative_to: "crop"` placed on the preview. The tool does not undo Upright, so the frame can sit up to about 0.05 away near the edges: leave a margin and adjust once.
6. **Manual fallback** when no mode looks right or a partial correction looks more natural: Upright off, then `PerspectiveVertical`, set from the image rather than a fixed value, `PerspectiveAspect` against a stretched look, `PerspectiveScale` to pull blank edges inside, `PerspectiveRotate` for a small tilt. A slight residual convergence often looks more natural than geometric parallels. Read the render after each.

**Projection** (`ReshapeAmount`, Lightroom Classic 16.0) reshapes the edges and corners of a wide frame to reduce the stretch of faces and round objects near the corners; on a facade it did not straighten verticals. Use it for a person, animal or round object stretched near the edge; do not use it as perspective correction or on descriptive architecture or a horizon near the edge, where it bends lines that must stay straight.

## Depth and atmosphere

Name the foreground, middle and far planes and their light. Support existing diagonals, light corridors, silhouettes, lit slopes and mist layers. Equal Clarity or Dehaze on every plane erases depth; a dark defined foreground against a soft distance may be the point of a fog picture.

Build the broad brightness hierarchy before local refinement. The sky is not simply the top half: inspect branches, antennas, bright buildings and ridge lines. Opening the land can leave a bright rim; darkening the sky can leave dark halos, grey twigs or an unnatural horizon. Toggle the effect at whole-frame and edge scale; reduce a correction whose edge dominates before refining it. Recheck colour and brightness after Dehaze. A daylight sky normally stays brighter than the land.

Keep sharpening off sky and smooth walls with Masking; use Texture rather than Clarity for foliage, and avoid strong Clarity on smooth skies unless the effect is intended. Water reflects: glints and reflected colour may dominate locally, and a specular highlight need not contain texture. Watch foliage for crunchy detail, uniform greens and oversaturated planes.

For blue hour protect the difference between the cool surroundings and warm windows; auto white balance can neutralise the very blue that makes the scene. A coloured source need not become white.

## Directions to test

| Direction | Preserve or strengthen | Stop or revise when |
| --- | --- | --- |
| Descriptive architecture | Proportions, material, controlled colour | Crop or stretch misrepresents the building |
| Dramatic geometry | Intentional convergence, diagonals, tonal hierarchy | The tilt looks accidental or shapes collapse |
| Airy landscape | Soft distance, light air, a readable anchor | The scene becomes shapeless grey |
| Light relief | Existing sun and shadow, separated planes | Mask edges show, or masks add light against the scene's direction |
| Blue hour | Cool ambient with warm inhabited light | Everything turns blue, or windows become orange blobs |
| Graphic monochrome | Form, rhythm, tonal plane separation | The colour story is lost or forms merge |

Exclude photo-specific geometry from any colour look you intend to reuse.

## Several frames

Panorama and HDR need several suitable originals; virtual copies of one RAW add neither coverage nor dynamic range. The tools have no merge route: use Lightroom's Photo Merge in the UI when the person asks for one.

## Sources

- [Cambridge in Colour: wide-angle lenses](https://cdn.cambridgeincolour.com/tutorials/wide-angle-lenses.htm): viewpoint, tilt, distortion and edge stretch.
- [Adobe: Upright](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/guided-upright-perspective-correction.html); [Adobe: masking](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/masking.html); [Adobe: panoramas](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/panorama.html).
- [David Chapman: landscape perspective](https://www.naturettl.com/perspective-in-landscape-photography/); [Mikko Lagerstedt: fog and mist](https://www.mikkolagerstedt.com/blog/how-to-photograph-fog-and-mist/); [Anton Gorlin: Dehaze](https://antongorlin.com/blog/how-to-use-photoshop-and-lightroom-dehaze/); [Tim Grey: blue-hour white balance](https://asktimgrey.com/2021/10/19/white-balance-for-blue-hour/).
