local LrApplication = import 'LrApplication'

local JSON = require 'JSON'
local JsonValue = require 'JsonValue'
local PhotoLookup = require 'PhotoLookup'

local RawDevelopSettings = {}

local MAX_REPLY_BYTES = 1000000
local MAX_KEYS = 200

local function requirePhotoId(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" or value == "" then error("photo_id is required", 0) end
    return value
end

local function requireKeys(value)
    if value == nil then return nil end
    local problem = "keys must be an array of 1 to " .. MAX_KEYS .. " distinct non-empty setting names"
    if type(value) ~= "table" or JsonValue.shapeOf(value) ~= "array" or #value > MAX_KEYS then error(problem, 0) end
    local seen = {}
    for _, key in ipairs(value) do
        if type(key) ~= "string" or key == "" or seen[key] then error(problem, 0) end
        seen[key] = true
    end
    return value
end

local function keyList(settings)
    local keys = {}
    for _, key in ipairs(JsonValue.sortedKeys(settings)) do
        local value = settings[key]
        local entry = { name = tostring(key), type = type(value) }
        if type(value) == "table" then
            local _, count = JsonValue.shapeOf(value)
            entry.count = count
        end
        keys[#keys + 1] = entry
    end
    return keys
end

function RawDevelopSettings.get(args)
    args = args or {}
    local photoId = requirePhotoId(args.photo_id)
    local wanted = requireKeys(args.keys)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then error("Photo not found: " .. tostring(photoId), 0) end

    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    settings = settings or {}

    local result = { photo_id = tostring(photo.localIdentifier) }
    if wanted == nil then
        result.keys = keyList(settings)
        result.count = #result.keys
    else
        local values, missing = {}, {}
        for _, key in ipairs(wanted) do
            if settings[key] == nil then
                missing[#missing + 1] = key
            else
                values[key] = JsonValue.of(settings[key])
            end
        end
        result.settings = values
        result.missing = missing
    end

    local size = #JSON:encode(result)
    if size > MAX_REPLY_BYTES then
        error(string.format("The requested settings take %d bytes, over the %d-byte limit; request fewer keys",
            size, MAX_REPLY_BYTES), 0)
    end
    return result
end

return RawDevelopSettings
