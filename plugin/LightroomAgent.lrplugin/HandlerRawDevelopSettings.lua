local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local DevelopCurves = require 'DevelopCurves'
local DevelopReadBack = require 'DevelopReadBack'
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
        local value = DevelopCurves.read(settings, key)
        if value == nil then
            absent[#absent + 1] = key
        else
            values[key] = JsonValue.of(value)
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
                local read, settings = LrTasks.pcall(DevelopReadBack.saved, entry.photo)
                local reply = read and photoReply(entry.photo, settings, args.keys)
                local size = read and #JSON:encode(reply)
                if not read then
                    failed[#failed + 1] = { photo_id = tostring(entry.photo.localIdentifier), reason = Reply.messageOf(settings) }
                elseif size > MAX_REPLY_BYTES then
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

function DevelopSettingsRead.byInput(args, context)
    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
    local rows, rowOf, stopped = {}, {}, false
    catalog:withReadAccessDo(function()
        for index, entry in ipairs(resolved) do
            local photo = entry.photo
            if not photo then
                rows[index] = { not_found = true }
            else
                if rowOf[photo] == nil then
                    stopped = stopped or context:stopping(REPLY_RESERVE_SECONDS)
                    if stopped then
                        rowOf[photo] = { remaining = true }
                    else
                        local photoId = tostring(photo.localIdentifier)
                        local read, settings = LrTasks.pcall(DevelopReadBack.saved, photo)
                        rowOf[photo] = read and { photo_id = photoId, settings = (DevelopSettingsRead.values(settings, args.keys)) }
                            or { photo_id = photoId, failed = Reply.messageOf(settings) }
                    end
                end
                rows[index] = rowOf[photo]
            end
        end
    end)
    return { rows = rows }
end

return DevelopSettingsRead
