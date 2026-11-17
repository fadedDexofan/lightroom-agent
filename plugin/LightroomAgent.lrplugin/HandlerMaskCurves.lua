local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local JsonValue = require 'JsonValue'
local Log = require 'Log'
local MaskCurves = require 'MaskCurves'
local MaskValues = require 'MaskValues'

local MaskCurvesHandler = {}

function MaskCurvesHandler.setMaskCurves(args, context)
    local maskId = args.mask_id
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local result = MaskValues.write(context, catalog, photo, maskId, { curves = args.curves })

    local curves, changed, unchanged = {}, {}, {}
    for _, channel in ipairs(MaskCurves.channels) do
        if args.curves[channel.name] ~= nil then
            local from, to = result.before.curves[channel.name], result.after.curves[channel.name]
            curves[channel.name] = to
            if JsonValue.equal(from, to) then
                unchanged[#unchanged + 1] = channel.name
            else
                changed[#changed + 1] = { channel = channel.name, from = from, to = to }
            end
        end
    end

    Log.info(string.format("Mask %s on photo %s: %d curves changed, %d already at the value",
        maskId, photoId, #changed, #unchanged))

    return { photo_id = photoId, mask_id = maskId, curves = curves, changed = changed, unchanged = unchanged }
end

return MaskCurvesHandler
