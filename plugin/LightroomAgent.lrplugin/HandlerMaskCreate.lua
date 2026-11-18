local LrApplication = import 'LrApplication'

local AIMaskCompute = require 'AIMaskCompute'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local HandlerAiMasks = require 'HandlerAiMasks'
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

function MaskCreateHandler.createAIMask(context, catalog, photo, typeName, values)
    local own = AIMaskCompute.run(context, catalog, photo, {
        description = "Add " .. MaskTypes.SPECS[typeName].label .. " Mask",
        subject = "the " .. typeName .. " mask",
        expected = 1,
        build = function(entries)
            entries[#entries + 1] = newEntry(typeName, values)
            return entries
        end,
    }).own[1]
    return { mask_id = tostring(own.CorrectionID), adjustments = next(values) and MaskValues.adjustmentsOf(own, values) or nil }
end

function MaskCreateHandler.createMask(args, context)
    if args.type == "people" or args.type == "landscape" then
        return HandlerAiMasks.createMask(args, context)
    end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local created = MaskCreateHandler.createAIMask(context, catalog, photo, args.type, args.adjustments or {})
    Log.info(string.format("Created %s mask %s on photo %s", args.type, created.mask_id, photoId))

    return { photo_id = photoId, type = args.type, mask_id = created.mask_id, adjustments = created.adjustments }
end

return MaskCreateHandler
