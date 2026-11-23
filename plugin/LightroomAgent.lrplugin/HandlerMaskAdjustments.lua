local LrApplication = import "LrApplication"

local PhotoLookup = require "PhotoLookup"
local LocalSliders = require "LocalSliders"
local Log = require "Log"
local MaskValues = require "MaskValues"

local MaskAdjustmentsHandler = {}

function MaskAdjustmentsHandler.setMaskAdjustments(args, context)
    local maskId = args.mask_id
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_ids[1])
    local photoId = tostring(photo.localIdentifier)

    local result = MaskValues.write(context, catalog, photo, maskId, { adjustments = args.adjustments })

    local adjustments, changed, unchanged = {}, {}, {}
    for _, slider in ipairs(LocalSliders.list) do
        if args.adjustments[slider.name] ~= nil then
            local from, to = result.before.adjustments[slider.name], result.after.adjustments[slider.name]
            adjustments[slider.name] = to
            if from == to then
                unchanged[#unchanged + 1] = slider.name
            else
                changed[#changed + 1] = { slider = slider.name, from = from, to = to }
            end
        end
    end

    Log.info(
        string.format(
            "Mask %s on photo %s: %d sliders changed, %d already at the value",
            maskId,
            photoId,
            #changed,
            #unchanged
        )
    )

    return { photo_id = photoId, mask_id = maskId, adjustments = adjustments, changed = changed, unchanged = unchanged }
end

return MaskAdjustmentsHandler
