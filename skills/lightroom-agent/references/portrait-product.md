# Portrait, product and food

Apply the [foundations](foundations.md), then choose how truthful the picture must be and which materials matter.

## People

First choose what the picture is about: contact, character, a relationship, or the person in a place. Compare expressions, gesture, head angle, catchlights and distracting overlaps before pixel-level work. Closed eyes, movement and shallow depth of field can be intentional; reject them only when they defeat this picture's purpose.

Skin lives mostly in the orange HSL family and the red curve, so a look that pushes red midtones also reaches skin. Balance skin against its surroundings and the actual light; a consistently orange face is no evidence of correct white balance. Mixed light can keep its character when the main face convinces. A People mask (`create_mask` with `type: "people"` and `parts` such as `face_skin`, `iris_and_pupil`, `hair`, `teeth`) can isolate parts, but it always takes the first person and its edge must survive hair, brows, nostrils, teeth, glasses and clothing. Protect identity and expression: detailed eye, skin or body retouching needs an actual request, not an automatic beauty standard.

Texture and Clarity treat skin differently from eyes and hair. Reduce distracting texture with restraint, keeping pores and transitions; plastic skin is not an improvement. Brightened eyes and teeth must stay believable in the scene's light. A tight portrait strengthens expression at the cost of place: compare both.

## Product and food

Establish the task: catalogue accuracy, editorial atmosphere or personal interpretation. For accuracy protect packaging and brand colours, material identity, readable labels and shape. Accurate colour needs a reference in the shot (a grey card or colour target) and ideally a custom camera profile; without one, colour accuracy is judgment, not measurement. A mood grade that changes the product's colour has a real cost even when it looks good.

Inspect the whole object and its contour: handle, base, rim, contact shadow, reflections. A specular highlight can describe gloss or metal and need not hold texture; decide whether it is useful before reducing every highlight. Do not neutralise deliberate warm food light into grey or erase the grounding shadow so the object floats. Check white surfaces for green or magenta contamination and saturated food for false hues or clipped channels. Separate object and background adjustments when their needs differ; Texture can clarify stone, ceramic and food but coarsen sauces, skin or smooth packaging. Changing product geometry or material is a separate creative decision. Small text, glass edges, thin stems and reflective boundaries need a detail crop.

## Sources

- [Karl Taylor: Clinique post-production](https://visualeducation.com/class/clinique-shoot-post-production-2-cleaning-bottles-creating-reflections/): material reads through reflected light and transitions (Photoshop retouching, not a Lightroom route).
- [PHLEARN: skin tones and colour grading](https://phlearn.com/tutorial/skin-tones-color-grading-photoshop-lightroom/): correction before grading, per-image exposure and white balance when synchronising.
- [Mareike Keicher: colour harmonies](https://www.captureone.com/blog/applying-color-harmonies-in-capture-one): colours that cannot change.

Research a specialist when a request goes beyond these principles: beauty retouching, commercial colour tolerances, jewellery or glass, food styling, a named artist's method.
