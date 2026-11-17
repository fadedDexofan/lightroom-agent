local LrApplication = import 'LrApplication'

local JSON = require 'JSON'
local JsonValue = require 'JsonValue'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local DevelopSettingsRead = {}

local MAX_REPLY_BYTES = 1000000
local REPLY_RESERVE_SECONDS = 5

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

function DevelopSettingsRead.values(settings, keys)
    local values, absent = {}, {}
    for _, key in ipairs(keys) do
        if settings[key] == nil then
            absent[#absent + 1] = key
        else
            values[key] = JsonValue.of(settings[key])
        end
    end
    return values, absent
end

local function photoReply(photo, settings, keys)
    local reply = { photo_id = tostring(photo.localIdentifier) }
    if keys == nil then
        reply.keys = keyList(settings)
    else
        reply.settings, reply.absent = DevelopSettingsRead.values(settings, keys)
    end
    return reply
end

function DevelopSettingsRead.get(args, context)
    local catalog = LrApplication.activeCatalog()
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    local photos, failed, remaining = {}, {}, {}
    local bytes = 0
    catalog:withReadAccessDo(function()
        for _, entry in ipairs(entries) do
            if #remaining > 0 or context:stopping(REPLY_RESERVE_SECONDS) then
                remaining[#remaining + 1] = entry.id
            else
                local reply = photoReply(entry.photo, entry.photo:getDevelopSettings() or {}, args.keys)
                local size = #JSON:encode(reply)
                if size > MAX_REPLY_BYTES then
                    failed[#failed + 1] = { photo_id = reply.photo_id, reason = string.format(
                        "The requested settings take %d bytes, over the %d-byte limit; request fewer keys",
                        size, MAX_REPLY_BYTES) }
                elseif bytes + size > MAX_REPLY_BYTES then
                    remaining[#remaining + 1] = entry.id
                else
                    bytes = bytes + size
                    photos[#photos + 1] = reply
                end
            end
        end
    end)
    return Reply.parts({
        data = #photos > 0 and { photos = photos } or nil,
        failed = failed,
        not_found = notFound,
        remaining = remaining,
    })
end

return DevelopSettingsRead
