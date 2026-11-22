local LrApplication = import "LrApplication"

local PhotoLookup = require "PhotoLookup"
local Log = require "Log"
local MaskValues = require "MaskValues"

local MaskPointColorsHandler = {}

function MaskPointColorsHandler.editMaskPointColors(args, context)
    local maskId = args.mask_id
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local result = MaskValues.write(
        context,
        catalog,
        photo,
        maskId,
        { swatch = { action = args.action, index = args.index, fields = args.swatch } }
    )
    local swatches, count = result.after.swatches, result.after.swatch_count
    if count then
        context:warn(
            string.format(
                "mask %s still holds a Point Color swatch Lightroom stored unreadably, so the reply"
                    .. " gives the swatch count instead of the swatches",
                tostring(maskId)
            )
        )
    end
    count = count or #swatches

    Log.info(
        string.format("Point Color %s on mask %s of photo %s: %d swatches now", args.action, maskId, photoId, count)
    )

    return {
        photo_id = photoId,
        mask_id = maskId,
        action = args.action,
        index = args.action == "add" and count or args.index,
        changed = #result.written > 0,
        swatches = swatches,
        swatch_count = result.after.swatch_count,
    }
end

return MaskPointColorsHandler
