local LrTasks = import 'LrTasks'

local Contract = require 'Contract'
local DevelopCurves = require 'DevelopCurves'
local JSON = require 'JSON'
local Reply = require 'Reply'

local DevelopReadBack = {}

local NORMALISE_SECONDS = 1
DevelopReadBack.REPLY_SECONDS = 2
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

local function keyChanged(key, before, stored)
    local was, now = DevelopCurves.read(before, key), DevelopCurves.read(stored, key)
    return (was == nil) ~= (now == nil) or (was ~= nil and not same(key, was, now))
end

local function unchanged(settings, before, stored)
    for _, key in ipairs(sortedKeys(settings)) do
        if keyChanged(key, before, stored) then return false end
    end
    return true
end

local LISTED_EDITS = {
    { "MaskGroupBasedCorrections", function(settings) return settings.MaskGroupBasedCorrections end },
    { "RetouchAreas", function(settings) return settings.RetouchAreas end },
    { "FilterList", function(settings) return type(settings.FilterList) == "table" and settings.FilterList.Filters end },
}

local function profileOf(settings)
    local look = type(settings.Look) == "table" and settings.Look or {}
    return { settings.CameraProfile, look.Name, look.Amount }
end

function DevelopReadBack.changedEdits(before, after)
    local changed = {}
    for _, key in ipairs(Contract.DEVELOP_KEYS) do
        if keyChanged(key.name, before, after) then changed[#changed + 1] = key.name end
    end
    for _, edit in ipairs(LISTED_EDITS) do
        local name, listOf = edit[1], edit[2]
        if #(listOf(after) or {}) < #(listOf(before) or {}) then changed[#changed + 1] = name end
    end
    local was, now = profileOf(before), profileOf(after)
    if was[1] ~= now[1] or was[2] ~= now[2] or was[3] ~= now[3] then changed[#changed + 1] = "profile" end
    return changed
end

function DevelopReadBack.saved(photo)
    local settings = photo:getDevelopSettings()
    if settings == nil then
        error("Lightroom returned no saved settings for photo " .. tostring(photo.localIdentifier), 0)
    end
    return settings
end

function DevelopReadBack.before(settings)
    local kept = {}
    for key, value in pairs(settings) do
        if KEYS[key] or DevelopCurves.isCompanion(key) then kept[key] = value end
    end
    return kept
end

function DevelopReadBack.check(context, catalog, written)
    if #written == 0 then return {} end
    LrTasks.sleep(NORMALISE_SECONDS)
    local checked = {}
    catalog:withReadAccessDo(function()
        for _, entry in ipairs(written) do
            local reached = context:timeLeft() >= DevelopReadBack.REPLY_SECONDS
            local read, stored = false, "not read back within the time budget"
            if reached then read, stored = LrTasks.pcall(DevelopReadBack.saved, entry.photo) end
            local result = { photo_id = tostring(entry.photo.localIdentifier), stored = {}, adjusted = {}, absent = {},
                notStored = {} }
            if not read then
                result.error = entry.error
                    or (reached and "the read-back failed: " .. Reply.messageOf(stored) or "written; " .. stored)
                result.written = entry.from and context.ledger:since(entry.from, entry.to) or {}
                if #result.written == 0 and entry.error == nil then result.written = { "the settings written before this read" } end
            elseif entry.error ~= nil then
                result.error = entry.error
                result.written = context.ledger:since(entry.from, entry.to)
                if #result.written == 0 and entry.before ~= nil and not unchanged(entry.settings, entry.before, stored) then
                    result.written = { "settings Lightroom now shows changed" }
                end
            else
            for _, key in ipairs(sortedKeys(entry.settings)) do
                local requested, value = entry.settings[key], DevelopCurves.read(stored, key)
                if value == nil and entry.before ~= nil and DevelopCurves.read(entry.before, key) == nil then
                    result.notStored[#result.notStored + 1] = key
                elseif value == nil then
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

function DevelopReadBack.confirmed(result)
    return result.error == nil and #result.absent == 0
end

function DevelopReadBack.parts(checked, data, lists)
    local parts = lists or {}
    parts.data = data
    parts.unknown = parts.unknown or {}
    local adjusted, notStored = {}, {}
    parts.failed = parts.failed or {}
    for _, result in ipairs(checked) do
        if not DevelopReadBack.confirmed(result) then
            local class, reason = "unknown", "Lightroom shows no " .. table.concat(result.absent, ", ") .. " after the write"
            if result.error ~= nil then class, reason = Reply.stopped(result.error, result.written) end
            local list = class == "failed" and parts.failed or parts.unknown
            list[#list + 1] = { photo_id = result.photo_id, reason = reason }
        end
        for _, item in ipairs(result.adjusted) do adjusted[#adjusted + 1] = item end
        if #result.notStored > 0 then
            notStored[#notStored + 1] = { photo_id = result.photo_id, keys = result.notStored }
            parts.warnings = parts.warnings or {}
            parts.warnings[#parts.warnings + 1] = string.format("Lightroom stores no %s for photo %s",
                table.concat(result.notStored, ", "), result.photo_id)
        end
    end
    if #notStored > 0 and data ~= nil then data.not_stored = notStored end
    if #adjusted > 0 then
        if data ~= nil then data.adjusted = adjusted end
        local named, shown = {}, data ~= nil and math.min(#adjusted, NAMED_IN_PROBLEM) or #adjusted
        for index = 1, shown do
            local item = adjusted[index]
            named[#named + 1] = string.format("%s %s on photo %s (written %s)",
                item.key, valueText(item.stored), item.photo_id, valueText(item.requested))
        end
        if #adjusted > shown then named[#named + 1] = string.format("%d more in adjusted", #adjusted - shown) end
        parts.problem = "Lightroom stored other values than written: " .. table.concat(named, ", ")
    end
    return Reply.parts(parts)
end

return DevelopReadBack
