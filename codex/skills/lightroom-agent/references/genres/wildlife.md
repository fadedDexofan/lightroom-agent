# Birds and animals

Combine the foundations with the animal's behaviour, the recorded light and the detail that matters; do not turn every animal into the same isolated portrait.

## Cull the moment

Compare same-animal sequences, not detector pairs or single thumbnails. Run the technical gate on every frame of a sequence first, with eye crops at one magnification for eye-led frames and a crop of the carrying detail otherwise ([cull](../workflow/cull.md#the-procedure)), then apply the weak-sequence rule. Weigh differences in gaze, behaviour, wing and body shape, interaction and habitat. Keep four judgments apart: a technical failure that defeats the subject at the intended size; a weaker usable alternative; uncertain; a candidate with a clear development opportunity.

For action, check the eye first, then behaviour, then wing, leg and prey shape and overlaps, then background and crop. A sharp head with softer moving wings can succeed. Closed eyes can express rest; noise and shallow depth of field are not automatic failures. Image stabilisation addresses camera movement, not the animal's.

## Compose subject, habitat and water

Choose portrait, action, interaction or animal-in-environment. Keep the space the gaze, movement, wing, tail and reflection need rather than a fixed eye position. A tight crop costs context and magnifies noise and softness; keep the crop at or above the delivery size and judge a frame of marginal sharpness at delivery scale ([cull](../workflow/cull.md#the-procedure)). Quiet a competing background without a cut-out look; soft foreground can add depth when key anatomy still reads.

Water is a material: judge droplets, reflections, ripples and smooth water separately. Strong sharpening makes ripples brittle; strong noise reduction makes them plastic. A clear reflection can form one figure with the animal; a distorted one is no straightening reference. A wake can matter more than space in front of the beak. A single background mask need not get one uniform treatment.

## Develop the recorded light

Match the treatment to the light that is there. Directions to test, not recipes:

| Recorded situation | Direction to test | Cost to check |
| --- | --- | --- |
| Shaded animal, bright water | Open the subject locally, keep the warm reflected light and pale feathers | Noisy head, background dominance, warm cast on white |
| Side-lit face or body | Support the bright side, quiet distractions | Opening every shadow flattens the light; deep burning makes a cut-out |
| Soft light against pale water or sky | Airy tones with dark eye and beak anchors | Lost white detail; excess contrast kills the air |
| Backlit profile or rim | Graphic silhouette or restrained body detail | A silhouette gives up markings; a bright body weakens the rim |
| A real patch of forest light | Keep the light niche inside deep surroundings | Empty black habitat, or the mood lost by lifting all shadows |
| Soft foreground foliage | Keep a gentle depth frame, lower its contrast and colour | Added-looking haze, hidden anatomy |

Check feather, fur, whisker and limb-gap edges without an overlay. Keep important markings and white or black detail unless losing them is a chosen trade-off. For white plumage lower Highlights and Whites globally and in a subject mask, then check clipping on the render at delivery size. Check bright edges for purple and green fringes in a detail crop. Remove Chromatic Aberration first; use Defringe only on evidence, starting low (about 4 of 20) and raising in small steps while reading the same crop. Check that it does not desaturate genuinely purple, magenta or green plumage, flowers or leaf edges; a negative `local_Defringe` in a subject mask protects them. Global green HSL changes a green frog with its leaves; a background mask or a luminance separation may serve better.

## Detail

Inspect the eye or head, fine fur or feather structure and a smooth area before accepting noise reduction ([development](../workflow/development.md#detail-without-damage)). On the eye, enhance a catchlight that exists only modestly; never add one. In monochrome, verify that animal and habitat do not merge in grey.

## Capture lessons

Diagnose the cause of a failure only to improve the next shoot. In low light distinguish motion from stillness: motion may justify a higher ISO for a useful shutter speed; a still animal allows support, a slower shutter and several attempts. Do not underexpose to show a low ISO. Through a fence, a lens close to the mesh, a distant animal and a wide aperture reduce it; Dehaze can reveal residual mesh, and removing bars over an animal reconstructs content rather than recovers it. Never approach or cross barriers for a picture.

## Sources

- [birdphotography.com: sharp images](https://birdphotography.com/articles/achieving-sharp-images-troubleshooting-and-techniques/): eye-first sharpness, shutter-speed priors.
- [Feathered Photography: catchlights](https://featheredphotography.com/blog/2021/02/19/catch-lights-in-the-eyes-are-they-overrated/).
- [Brad James: bird light](https://www.naturettl.com/how-to-harness-light-in-bird-photography/); [Kevin Morgans: backlighting](https://www.naturettl.com/backlighting-wildlife-photography/); [Mike Atkinson: birds and water](https://mikeatkinson.net/Tutorial-8-Birds-and-Water.htm); [Will Nicholls: low light](https://www.naturettl.com/how-to-photograph-wildlife-in-low-light/); [Terry Thomas: zoo photography](https://www.nature-track.com/Zoo_Photography.html).
- [Julieanne Kost: Denoise in Lightroom Classic 12.3](https://jkost.com/blog/2023/04/denoise-masking-and-edit-in-photoshop-updates-in-lightroom-classic-v12-3.html).
