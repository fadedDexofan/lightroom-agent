# Adjustments when creating masks

`create_gradient_mask`, `create_brush_mask` and `create_range_mask` accept an
optional, non-empty `adjustments` object. It uses the same `local_*` slider
names as `create_mask`, for example `"adjustments": {"local_Exposure": 1}`.

The create call writes the sliders into the new mask's entry together with its
geometry, as Lightroom stores them, and confirms both by reading the saved
masks back; it restores the previous masks if either differs. Calls without
`adjustments` keep their behavior.

`adjustments` cannot be combined with `mask_id`: adding a component must
preserve that existing mask's sliders. Unknown sliders and out-of-range
values fail validation. The Lightroom 15.6 and process-version 15.4 limits
remain unchanged.
