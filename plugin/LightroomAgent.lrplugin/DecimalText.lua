local DecimalText = {}

local function requireFinite(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("cannot write the non-finite number " .. tostring(value), 0)
    end
end

local function localeSeparator() return string.format("%.1f", 0.5):sub(2, 2) end

function DecimalText.fixed(value, places)
    requireFinite(value)
    local scale = 10 ^ places
    local scaled = math.floor(math.abs(value) * scale + 0.5)
    local whole = math.floor(scaled / scale)
    local fraction = scaled - whole * scale
    local sign = (value < 0 and scaled > 0) and "-" or ""
    return string.format("%s%d.%0" .. places .. "d", sign, whole, fraction)
end

function DecimalText.significant(value, digits)
    requireFinite(value)
    local text = string.format("%." .. digits .. "g", value)
    local separator = localeSeparator()
    if separator ~= "." then text = text:gsub("%" .. separator, ".") end
    return text
end

function DecimalText.parse(text)
    if type(text) == "number" then return text end
    if type(text) ~= "string" then return nil end
    local separator = localeSeparator()
    if separator ~= "." then text = text:gsub("%.", separator) end
    return tonumber(text)
end

function DecimalText.number(value)
    requireFinite(value)
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format("%d", value) end
    for digits = 15, 16 do
        local text = DecimalText.significant(value, digits)
        if DecimalText.parse(text) == value then return text end
    end
    return DecimalText.significant(value, 17)
end

return DecimalText
