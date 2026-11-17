# Publishing to a destination

From "prepare these for Instagram" to verified files. Preparing ends in exported files in a folder the person uploads from; posting is the person's own act. Do not change the masters' edits, ratings, flags or collections unless asked.

## Delivery facts

Examples; add the destination the person names, and check its current limits, since platforms change their formats (first-party pages, checked November 2026).

| Destination | Ratios (width:height) | Delivery size |
| --- | --- | --- |
| Instagram feed | app 1.91:1 to 3:4; publishing API 1.91:1 to 4:5; other ratios are cropped | 1080 px wide (the API accepts up to 1440 and converts to sRGB) |
| Pinterest | 2:3 recommended; taller pins may be cut off in feeds | 1000×1500 for 2:3, 1000 px wide otherwise |

Upload routes may resize or recompress the image: suggest posting one file privately first and checking the downloaded result.

## 1. Read the final crop

Read each photo's crop with `get_crop`: rectangle, angle and the cropped frame's `size` in pixels. Its ratio r = width ÷ height of that size. Do not compute size or ratio from the raw crop keys: with a straighten angle or a vertical frame they mislead.

## 2. Choose the format

A format fits when a box of its ratio inside the final crop (full height for a narrower format, full width for a wider one) contains the whole subject (with its reflection when that is part of the picture), cuts no second subject, and leaves room on the side the subject faces or moves. Plan the box on a preview of the final edit. For a destination that accepts several ratios, choose the accepted ratio that best preserves the composition; a taller format takes more of a feed's screen, and a common series ratio only when the person wants one. When nothing fits, say which subjects each format would cut instead of forcing one.

## 3. Make a variant only when the format needs a new crop

1. Make a virtual copy of the master named for the format (`create_virtual_copies` with `copy_name`, such as `IG 4x5`); it inherits the edit, crop and masks.
2. Inside the final crop (the default): on the copy, `set_crop` with `relative_to: "crop"`, the format as `aspect` and the planned box's `center` and `scale`, placed on the ordinary preview.
3. Outside the final crop only when the format needs room the crop lacks and that area holds nothing the person cropped out on purpose, by the re-crop route in [tools](../tools/tools.md#crop).
4. Check a fresh preview of the copy: the ratio, the whole subject and its room, nothing the final crop had removed on purpose, and mask effects still on the right areas (Lightroom stores masks before the crop, so they stay on the same part of the photo). Otherwise restore the kept crop on the copy and report the format as not made.
5. Add the copy to a collection when the person keeps variants that way; `add_to_collection` reports `already_in_collection` for photos already there.

## 4. Gates before export

- The crop is at least the delivery size in both dimensions, without enlargement (the `size` from `get_crop` or `set_crop`).
- The technical gate holds at that destination's delivery size; a tighter variant enlarges the subject on screen, so check its critical detail again ([cull](cull.md#the-procedure)).

## 5. Export and verify

Call `export_photos` with the master's or the copy's id, `format: "jpeg"`, an explicit `quality` (90–95 for web), the delivery `width`/`height` as maxima, `on_existing: "skip"` and a new destination folder. Without an export preset the plug-in exports sRGB and never enlarges, and it sets no output sharpening: state sharpening as unknown unless a preset sets it. Export a few photos per call, one call at a time; after an error inspect the folder before retrying.

Check every written file: one per photo, JPEG, the expected pixel size and an embedded sRGB profile. Report per photo the format chosen and, for a new crop, the copy id and what was given up; frames that do not suit the destination and why; the folder and file sizes; and what was not verified (full-resolution mask edges, output sharpening, how the platform renders the upload).

## Sources

- [Instagram Help: photo sizes](https://help.instagram.com/1631821640426723); [Instagram Content Publishing API](https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media).
- [Pinterest product specs](https://help.pinterest.com/en/business/article/pinterest-product-specs).
