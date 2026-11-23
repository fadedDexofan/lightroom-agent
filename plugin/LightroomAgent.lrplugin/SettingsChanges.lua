local JsonValue = require "JsonValue"

local SettingsChanges = {}

local SHOWN_TEXT_LENGTH = 40

local BOOKKEEPING = {
    Version = true,
}

local function stored(value)
    if type(value) == "table" and next(value) == nil then return nil end
    return value
end

local function shape(value)
    if value == nil then return "absent" end
    if type(value) == "table" then
        if next(value) == nil then return "{}" end
        if #value > 0 then return "a list of " .. #value end
        return "a table"
    end
    local text = tostring(value)
    if #text > SHOWN_TEXT_LENGTH then return "a " .. type(value) end
    return text
end

function SettingsChanges.between(before, after, skip)
    local keys, seen = {}, {}
    for _, settings in ipairs({ before, after }) do
        for key in pairs(settings) do
            if not seen[key] and not BOOKKEEPING[key] and not (skip and skip(key)) then
                seen[key] = true
                if not JsonValue.equal(JsonValue.of(stored(before[key])), JsonValue.of(stored(after[key]))) then
                    keys[#keys + 1] = key
                end
            end
        end
    end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    local changes = {}
    for index, key in ipairs(keys) do
        changes[index] = {
            key = key,
            text = string.format("%s (was %s, now %s)", tostring(key), shape(before[key]), shape(after[key])),
        }
    end
    return changes
end

function SettingsChanges.listed(changes, limit)
    local shown = math.min(#changes, limit or #changes)
    local texts = {}
    for index = 1, shown do
        texts[index] = changes[index].text
    end
    if #changes > shown then texts[#texts + 1] = string.format("%d more", #changes - shown) end
    return table.concat(texts, ", ")
end

return SettingsChanges
