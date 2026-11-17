local LrApplication = import 'LrApplication'

local AIMaskCompute = require 'AIMaskCompute'
local Log = require 'Log'
local MaskTypes = require 'MaskTypes'
local MaskValues = require 'MaskValues'
local PhotoLookup = require 'PhotoLookup'

local MaskCombineHandler = {}

local VERB_OF_OPERATION = {
    add = "add to",
    subtract = "subtract from",
    intersect = "intersect with",
}
local HISTORY_STEP_OF_OPERATION = {
    add = "Add to Mask",
    subtract = "Subtract from Mask",
    intersect = "Intersect with Mask",
}

function MaskCombineHandler.combineMask(args, context)
    local maskId = tostring(args.mask_id)
    local operation, typeName = args.operation, args.type
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local verb = VERB_OF_OPERATION[operation]
    local result = AIMaskCompute.run(context, catalog, photo, {
        description = HISTORY_STEP_OF_OPERATION[operation],
        subject = string.format("the %s to %s mask %s", typeName, verb, maskId),
        target = maskId,
        expected = 1,
        build = function(entries)
            local _, entry = MaskValues.savedEntry(photo, entries, maskId)
            entry.CorrectionMasks[#entry.CorrectionMasks + 1] = MaskTypes.component(typeName, operation)
            return entries
        end,
    })
    local toolId = tostring(result.components[1].MaskID)

    Log.info(string.format("Combined mask %s on photo %s (%s %s) -> component %s", maskId, photoId, operation, typeName,
        toolId))

    return { photo_id = photoId, mask_id = maskId, operation = operation, type = typeName, tool_id = toolId }
end

return MaskCombineHandler
