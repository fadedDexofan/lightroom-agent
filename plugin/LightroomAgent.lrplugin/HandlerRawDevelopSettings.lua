local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"

local DevelopCurves = require "DevelopCurves"
local DevelopReadBack = require "DevelopReadBack"
local JSON = require "JSON"
local JsonValue = require "JsonValue"
local PhotoBatch = require "PhotoBatch"
local PhotoLookup = require "PhotoLookup"
local Reply = require "Reply"

local DevelopSettingsRead = {}

local MAX_DATA_BYTES = 1000000
local DATA_WRAPPER_BYTES = #JSON:encode({ photos = { 0 } }) - 1
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

local function dataBytes(rowBytes, rowCount) return DATA_WRAPPER_BYTES + rowBytes + rowCount - 1 end

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
    local sizes, bytes, rows = {}, 0, 0
    local batch = PhotoBatch.run(context, catalog, {
        inputs = args.photo_ids,
        reserveSeconds = REPLY_RESERVE_SECONDS,
        each = function(photo)
            local settings
            catalog:withReadAccessDo(function() settings = DevelopReadBack.saved(photo) end)
            local reply = photoReply(photo, settings, args.keys)
            local size = #JSON:encode(reply)
            if dataBytes(size, 1) > MAX_DATA_BYTES then
                Reply.refuse(
                    string.format(
                        "The requested settings take %d bytes, over the %d-byte limit; request fewer keys",
                        dataBytes(size, 1),
                        MAX_DATA_BYTES
                    )
                )
            end
            sizes[reply] = size
            return reply
        end,
        fits = function(reply)
            if dataBytes(bytes + sizes[reply], rows + 1) > MAX_DATA_BYTES then return false end
            bytes, rows = bytes + sizes[reply], rows + 1
            return true
        end,
    })
    return PhotoBatch.reply(batch, function(results) return { photos = results } end)
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
                        rowOf[photo] = read
                                and { photo_id = photoId, settings = (DevelopSettingsRead.values(settings, args.keys)) }
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
