local Contract = require 'Contract'

local MaskCurves = {}

local MIN_PAIRS = 2

MaskCurves.channels = Contract.MASK_CURVE_CHANNELS

MaskCurves.LINEAR = { 0, 0, 255, 255 }

local function isLinear(points)
    if #points ~= #MaskCurves.LINEAR then return false end
    for index, value in ipairs(MaskCurves.LINEAR) do
        if points[index] ~= value then return false end
    end
    return true
end

function MaskCurves.fromStored(strings)
    if type(strings) ~= "table" or #strings < MIN_PAIRS then return nil end
    local points = {}
    for _, pair in ipairs(strings) do
        if type(pair) ~= "string" then return nil end
        local input, output = pair:match("^%s*(%-?%d+)%s*,%s*(%-?%d+)%s*$")
        if not input then return nil end
        points[#points + 1] = tonumber(input)
        points[#points + 1] = tonumber(output)
    end
    return points
end

function MaskCurves.toStored(points)
    if isLinear(points) then return nil end
    local strings = {}
    for index = 1, #points, 2 do
        strings[#strings + 1] = string.format("%d,%d", points[index], points[index + 1])
    end
    return strings
end

function MaskCurves.ofEntry(entry, channel)
    local points = MaskCurves.fromStored(entry[channel.extended]) or MaskCurves.fromStored(entry[channel.stored])
    if points then return points end
    local linear = {}
    for index, value in ipairs(MaskCurves.LINEAR) do linear[index] = value end
    return linear
end

return MaskCurves
