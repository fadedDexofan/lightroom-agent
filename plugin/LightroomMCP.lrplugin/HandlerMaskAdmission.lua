local LrApplication = import 'LrApplication'

local GuardedMaskWrite = require 'GuardedMaskWrite'
local MaskWriteAdmission = require 'MaskWriteAdmission'
local PhotoLookup = require 'PhotoLookup'

local HandlerMaskAdmission = {}

local function photoAdmission(catalog, photoId)
    local photo = PhotoLookup.requireOne(catalog, photoId)
    local state = GuardedMaskWrite.inspect(catalog, photo)
    local decision = MaskWriteAdmission.decide(catalog, state.process_version)
    return {
        photo_id = tostring(photo.localIdentifier),
        process_version = state.process_version,
        mask_count = state.mask_count,
        schema_problems = state.schema_problems,
        admitted = decision.admitted,
        reason = decision.reason,
    }
end

function HandlerMaskAdmission.get(args)
    local photoId = args.photo_id
    local catalog = LrApplication.activeCatalog()
    local status = MaskWriteAdmission.status(catalog)
    local result = {
        admitted = status.admitted,
        reason = status.reason,
        running = status.running,
        certified = status.certified,
        throwaway_catalog = status.throwaway_catalog,
        certification_file = status.certification_file,
    }
    if photoId ~= nil then result.photo = photoAdmission(catalog, photoId) end
    return result
end

return HandlerMaskAdmission
