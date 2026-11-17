local JsonValue = {}

local MAX_DEPTH = 40
local MARKER = "$lua"

local function keyOrder(left, right)
    local leftType, rightType = type(left), type(right)
    if leftType ~= rightType then return leftType < rightType end
    if leftType == "number" or leftType == "string" then return left < right end
    return tostring(left) < tostring(right)
end

function JsonValue.sortedKeys(t)
    local keys = {}
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys, keyOrder)
    return keys
end

function JsonValue.shapeOf(t)
    local count, positional, highest, named = 0, 0, 0, 0
    for key in pairs(t) do
        count = count + 1
        if type(key) == "number" and key >= 1 and key == math.floor(key) then
            positional = positional + 1
            if key > highest then highest = key end
        elseif type(key) == "string" then
            named = named + 1
        end
    end
    if count == 0 then return "empty", 0 end
    if positional == count and highest == count then return "array", count end
    if named == count then return "object", count end
    return "mixed", count
end

local function convert(value, depth)
    if depth > MAX_DEPTH then
        error("the value nests deeper than " .. MAX_DEPTH .. " levels", 0)
    end
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return { [MARKER] = "number", value = tostring(value) }
        end
        return value
    end
    if kind ~= "table" then
        return { [MARKER] = kind, value = tostring(value) }
    end
    local shape, count = JsonValue.shapeOf(value)
    if shape == "empty" then return {} end
    local out = {}
    if shape == "array" then
        for index = 1, count do out[index] = convert(value[index], depth + 1) end
        return out
    end
    if shape == "object" then
        for key, item in pairs(value) do out[key] = convert(item, depth + 1) end
        return out
    end
    for _, key in ipairs(JsonValue.sortedKeys(value)) do
        out[#out + 1] = { convert(key, depth + 1), convert(value[key], depth + 1) }
    end
    return { [MARKER] = "table", entries = out }
end

function JsonValue.equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not JsonValue.equal(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

function JsonValue.of(value)
    return convert(value, 1)
end

return JsonValue
