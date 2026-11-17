local LrTasks = import 'LrTasks'

local Contract = require 'Contract'
local DevelopCurves = require 'DevelopCurves'
local JSON = require 'JSON'
local Reply = require 'Reply'

local DevelopReadBack = {}

local NORMALISE_SECONDS = 1
local NAMED_IN_PROBLEM = 10

local KEYS = {}
for _, key in ipairs(Contract.DEVELOP_KEYS) do KEYS[key.name] = key end

local function valueText(value)
    if type(value) == "table" then return JSON:encode(value) end
    return tostring(value)
end

local function same(key, requested, stored)
    if type(requested) == "number" and type(stored) == "number" then
        return math.abs(requested - stored) <= (KEYS[key].precision or 0) / 2 + 1e-9
    end
    if type(requested) == "table" and type(stored) == "table" then
        if #requested ~= #stored then return false end
        for index, value in ipairs(requested) do
            if value ~= stored[index] then return false end
        end
        return true
    end
    return requested == stored
end

local function sortedKeys(settings)
    local keys = {}
    for key in pairs(settings) do
        if KEYS[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

local function unchanged(settings, before, stored)
    for _, key in ipairs(sortedKeys(settings)) do
        local was, now = DevelopCurves.read(before, key), DevelopCurves.read(stored, key)
        if (was == nil) ~= (now == nil) or (was ~= nil and not same(key, was, now)) then return false end
    end
    return true
end

function DevelopReadBack.before(settings)
    local kept = {}
    for key, value in pairs(settings or {}) do
        if KEYS[key] or DevelopCurves.isCompanion(key) then kept[key] = value end
    end
    return kept
end

function DevelopReadBack.check(catalog, written)
    if #written == 0 then return {} end
    LrTasks.sleep(NORMALISE_SECONDS)
    local checked = {}
    catalog:withReadAccessDo(function()
        for _, entry in ipairs(written) do
            local stored = entry.photo:getDevelopSettings() or {}
            local result = { photo_id = tostring(entry.photo.localIdentifier), stored = {}, adjusted = {}, absent = {} }
            if entry.error ~= nil then
                result.error = entry.error
                result.untouched = entry.before ~= nil and unchanged(entry.settings, entry.before, stored)
            else
            for _, key in ipairs(sortedKeys(entry.settings)) do
                local requested, value = entry.settings[key], DevelopCurves.read(stored, key)
                if value == nil then
                    result.absent[#result.absent + 1] = key
                else
                    result.stored[key] = value
                    if not same(key, requested, value) then
                        result.adjusted[#result.adjusted + 1] = {
                            photo_id = result.photo_id, key = key, requested = requested, stored = value,
                        }
                    end
                end
            end
            end
            checked[#checked + 1] = result
        end
    end)
    return checked
end

function DevelopReadBack.parts(checked, data, lists)
    local parts = lists or {}
    parts.data = data
    parts.unknown = parts.unknown or {}
    local adjusted = {}
    parts.failed = parts.failed or {}
    for _, result in ipairs(checked) do
        if result.error ~= nil and result.untouched then
            parts.failed[#parts.failed + 1] = { photo_id = result.photo_id, reason = result.error }
        elseif result.error ~= nil then
            parts.unknown[#parts.unknown + 1] = {
                photo_id = result.photo_id,
                reason = result.error .. "; Lightroom may have stored part of the settings, read the photo before retrying",
            }
        end
        for _, item in ipairs(result.adjusted) do adjusted[#adjusted + 1] = item end
        if #result.absent > 0 then
            parts.unknown[#parts.unknown + 1] = {
                photo_id = result.photo_id,
                reason = "Lightroom shows no " .. table.concat(result.absent, ", ") .. " after the write",
            }
        end
    end
    if #adjusted > 0 then
        data.adjusted = adjusted
        local named = {}
        for index = 1, math.min(#adjusted, NAMED_IN_PROBLEM) do
            local item = adjusted[index]
            named[#named + 1] = string.format("%s %s on photo %s (written %s)",
                item.key, valueText(item.stored), item.photo_id, valueText(item.requested))
        end
        if #adjusted > NAMED_IN_PROBLEM then named[#named + 1] = string.format("%d more in adjusted", #adjusted - NAMED_IN_PROBLEM) end
        parts.problem = "Lightroom stored other values than written: " .. table.concat(named, ", ")
    end
    return Reply.parts(parts)
end

return DevelopReadBack
