local LrApplication = import 'LrApplication'

local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local LensProfileHandler = {}

local FIELDS = {
    { "LensProfileEnable", "enabled", function(value) return value == 1 or value == true end },
    { "LensProfileSetup", "setup" },
    { "LensProfileName", "name" },
    { "LensProfileFilename", "filename" },
    { "LensProfileIsEmbedded", "embedded" },
    { "LensProfileDistortionScale", "distortion_scale" },
    { "LensProfileVignettingScale", "vignetting_scale" },
}

local function lensProfileOf(settings)
    local profile = {}
    for _, field in ipairs(FIELDS) do
        local value = settings[field[1]]
        if value ~= nil then
            if field[3] then value = field[3](value) end
            profile[field[2]] = value
        end
    end
    return profile
end

function LensProfileHandler.read(args)
    local catalog = LrApplication.activeCatalog()
    local found, missing = {}, {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
        if entry.photo then found[#found + 1] = entry.photo else missing[#missing + 1] = entry.id end
    end
    local photos = {}
    catalog:withReadAccessDo(function()
        for i, photo in ipairs(found) do
            photos[i] = {
                photo_id = tostring(photo.localIdentifier),
                lens_profile = lensProfileOf(photo:getDevelopSettings() or {}),
            }
        end
    end)
    Log.info(string.format("Read the lens profile of %d photos", #photos))
    return Reply.parts({ data = #photos > 0 and { photos = photos } or nil, not_found = missing })
end

return LensProfileHandler
