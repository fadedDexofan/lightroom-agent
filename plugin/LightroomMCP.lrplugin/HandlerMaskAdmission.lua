local LrApplication = import 'LrApplication'

local GuardedMaskWrite = require 'GuardedMaskWrite'
local MaskWriteAdmission = require 'MaskWriteAdmission'
local PhotoLookup = require 'PhotoLookup'

local HandlerMaskAdmission = {}

local function photoAdmission(catalog, photoId)
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then error("Photo not found: " .. tostring(photoId), 0) end
    local state = GuardedMaskWrite.inspect(catalog, photo)
    local decision = MaskWriteAdmission.decide(catalog, state.process_version)
    local result = {
        photo_id = tostring(photo.localIdentifier),
        process_version = state.process_version,
        mask_count = state.mask_count,
        schema_problems = state.schema_problems,
        admitted = decision.admitted and #state.schema_problems == 0,
        reason = decision.reason,
    }
    if decision.admitted and #state.schema_problems > 0 then
        result.reason = "The masks already on this photo do not match the pinned mask format."
    end
    return result
end

function HandlerMaskAdmission.get(args)
    args = args or {}
    local photoId = args.photo_id
    if photoId ~= nil and type(photoId) ~= "string" and type(photoId) ~= "number" then
        error("photo_id must be a photo ID or file path", 0)
    end
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
