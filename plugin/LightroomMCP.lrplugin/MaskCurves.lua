local Contract = require 'Contract'

local MaskCurves = {}

MaskCurves.MINIMUM_VERSION_LABEL = "Lightroom Classic 12.3"

local MIN_PAIRS = 2
local VALUE_TOLERANCE = 1

MaskCurves.channels = Contract.MASK_CURVE_CHANNELS

function MaskCurves.requested(curves)
    local requested = {}
    for _, channel in ipairs(MaskCurves.channels) do
        local points = curves[channel.name]
        if points ~= nil then requested[#requested + 1] = { channel = channel, points = points } end
    end
    return requested
end

function MaskCurves.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local count = #raw
    if count < MIN_PAIRS * 2 or count % 2 ~= 0 then return nil end
    local points = {}
    for index = 1, count do
        if type(raw[index]) ~= "number" then return nil end
        points[index] = raw[index]
    end
    return points
end

function MaskCurves.same(left, right)
    if left == nil or right == nil or #left ~= #right then return false end
    for index = 1, #left do
        if math.abs(left[index] - right[index]) > VALUE_TOLERANCE then return false end
    end
    return true
end

function MaskCurves.copy(points)
    local copied = {}
    for index = 1, #points do
        copied[index] = points[index]
    end
    return copied
end

return MaskCurves
