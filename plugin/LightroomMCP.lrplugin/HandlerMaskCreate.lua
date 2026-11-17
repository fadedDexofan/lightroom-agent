local LrApplication = import 'LrApplication'

local AIMaskCompute = require 'AIMaskCompute'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local LocalSliders = require 'LocalSliders'
local Log = require 'Log'
local MaskTypes = require 'MaskTypes'
local MaskValues = require 'MaskValues'
local PhotoLookup = require 'PhotoLookup'

local MaskCreateHandler = {}

local function newEntry(typeName, values)
    local entry = GuardedMaskWrite.newCorrection(MaskTypes.SPECS[typeName].label, { MaskTypes.component(typeName, "add") })
    MaskValues.storeAdjustments(entry, values)
    return entry
end

local function storedAdjustments(entry, values)
    if next(values) == nil then return nil end
    local stored = {}
    for _, slider in ipairs(LocalSliders.list) do
        if values[slider.name] ~= nil then stored[slider.name] = LocalSliders.valueOf(slider, entry[slider.stored]) end
    end
    return stored
end

function MaskCreateHandler.createAIMask(context, catalog, photo, typeName, values)
    local photoId = tostring(photo.localIdentifier)
    local own = AIMaskCompute.run(context, catalog, photo, {
        description = "Add " .. MaskTypes.SPECS[typeName].label .. " Mask",
        subject = "the " .. typeName .. " mask",
        expected = 1,
        build = function(entries)
            entries[#entries + 1] = newEntry(typeName, values)
            return entries
        end,
        failure = function() return string.format("Lightroom found no %s on photo %s", typeName, photoId) end,
    }).own[1]
    return { mask_id = tostring(own.CorrectionID), adjustments = storedAdjustments(own, values) }
end

function MaskCreateHandler.createMask(args, context)
    if args.type == "people" or args.type == "landscape" then
        return (require 'HandlerAiMasks').createMask(args, context)
    end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)
    AIMaskCompute.requireSupported("create_mask", photo)

    local created = MaskCreateHandler.createAIMask(context, catalog, photo, args.type, args.adjustments or {})
    Log.info(string.format("Created %s mask %s on photo %s", args.type, created.mask_id, photoId))

    return { photo_id = photoId, type = args.type, mask_id = created.mask_id, adjustments = created.adjustments }
end

return MaskCreateHandler
