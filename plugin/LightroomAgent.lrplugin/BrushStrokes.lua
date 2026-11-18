local BrushFeather = require 'BrushFeather'
local Contract = require 'Contract'
local DecimalText = require 'DecimalText'
local Reply = require 'Reply'

local BrushStrokes = {}

local AGGREGATE_WHAT = "Mask/Aggregate"
BrushStrokes.PAINT_WHAT = "Mask/Paint"
local PAINT_WHAT = BrushStrokes.PAINT_WHAT

local DEFAULT_RADIUS = 0.14
local DEFAULT_FLOW = 1
local DEFAULT_DENSITY = 1
local MAX_DABS_PER_STROKE = 2000
local DAB_SPACING_IN_RADII = 0.5
local FLOW_TOKEN_DECIMALS = 10000
local STORED_PLACES = Contract.STORED_MASK_DECIMAL_PLACES
local STORED_SCALE = 10 ^ STORED_PLACES
local ERASE_VALUE = 0
local DISTANCE_EPSILON = 1e-9

local function fail(message)
    Reply.refuse(message)
end

local function roundFlow(value)
    return math.floor(value * FLOW_TOKEN_DECIMALS + 0.5) / FLOW_TOKEN_DECIMALS
end

local function roundStored(value)
    return math.floor(value * STORED_SCALE + 0.5) / STORED_SCALE
end

local function dabCountOf(points, radius)
    local spacing = radius * DAB_SPACING_IN_RADII
    local count = 1
    for index = 2, #points do
        local distance = math.sqrt((points[index].x - points[index - 1].x) ^ 2
            + (points[index].y - points[index - 1].y) ^ 2)
        count = count + math.ceil(distance / spacing - DISTANCE_EPSILON)
    end
    return count
end

local function requireDabBudget(field, dabCount, radius)
    if dabCount > MAX_DABS_PER_STROKE then
        fail(string.format(
            "%s would need %d dabs along its path at radius %s; at most %d are allowed (use a larger radius"
                .. " or a shorter path)", field, dabCount, tostring(radius), MAX_DABS_PER_STROKE))
    end
end

local function parseStroke(stroke)
    local feather = stroke.feather == nil and BrushFeather.SOFT or BrushFeather.fromPercent(stroke.feather)
    return {
        points = stroke.points,
        radius = (stroke.radius or DEFAULT_RADIUS) * BrushFeather.radiusScale(feather),
        flow = roundFlow(stroke.flow or DEFAULT_FLOW),
        centerWeight = roundStored(BrushFeather.centerWeight(feather)),
        density = roundStored(stroke.density or DEFAULT_DENSITY),
        erase = stroke.erase == true,
    }
end

function BrushStrokes.parseStrokes(strokes)
    local parsed = {}
    for index, stroke in ipairs(strokes) do
        parsed[index] = parseStroke(stroke)
    end
    return parsed
end

function BrushStrokes.toStoredFrame(strokes, frame)
    local mapped = {}
    for index, stroke in ipairs(strokes) do
        local points = {}
        for pointIndex, point in ipairs(stroke.points) do
            local x, y = frame.toStored(point.x, point.y)
            points[pointIndex] = { x = x, y = y }
        end
        local field = "strokes[" .. index .. "]"
        local radius = roundStored(frame.longEdgeToStored(stroke.radius))
        if radius <= 0 then fail(field .. ".radius is too small to paint") end
        requireDabBudget(field, dabCountOf(points, radius), radius)
        local copy = {}
        for key, item in pairs(stroke) do copy[key] = item end
        copy.points = points
        copy.radius = radius
        mapped[index] = copy
    end
    return mapped
end

local function clampUnit(value)
    return math.min(1, math.max(0, value))
end

local function dabText(x, y)
    return "d " .. DecimalText.fixed(clampUnit(x), STORED_PLACES) .. " " .. DecimalText.fixed(clampUnit(y), STORED_PLACES)
end

local function dabsAlong(stroke)
    local dabs = { dabText(stroke.points[1].x, stroke.points[1].y) }
    local spacing = stroke.radius * DAB_SPACING_IN_RADII
    for index = 2, #stroke.points do
        local from, to = stroke.points[index - 1], stroke.points[index]
        local distance = math.sqrt((to.x - from.x) ^ 2 + (to.y - from.y) ^ 2)
        local steps = math.ceil(distance / spacing - DISTANCE_EPSILON)
        for step = 1, steps do
            local fraction = step / steps
            dabs[#dabs + 1] = dabText(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction)
        end
    end
    local tokens = {}
    if stroke.flow < 1 then tokens[#tokens + 1] = "f " .. DecimalText.fixed(stroke.flow, 4) end
    if stroke.centerWeight > 0 and stroke.centerWeight < 1 then
        tokens[#tokens + 1] = "h " .. DecimalText.fixed(stroke.centerWeight, 4)
    end
    for index = #tokens, 1, -1 do table.insert(dabs, 1, tokens[index]) end
    return dabs
end

function BrushStrokes.newPaint(stroke)
    return {
        What = PAINT_WHAT,
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = stroke.erase and ERASE_VALUE or stroke.density,
        Flow = stroke.flow,
        Radius = stroke.radius,
        CenterWeight = stroke.centerWeight,
        Dabs = dabsAlong(stroke),
    }
end

function BrushStrokes.newAggregate(strokes)
    local paints = {}
    for index, stroke in ipairs(strokes) do paints[index] = BrushStrokes.newPaint(stroke) end
    return {
        What = AGGREGATE_WHAT,
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskName = "Brush",
        Masks = paints,
    }
end

function BrushStrokes.isBrush(component)
    if component.What ~= AGGREGATE_WHAT or type(component.Masks) ~= "table" then return false end
    for _, child in ipairs(component.Masks) do
        if type(child) ~= "table" or child.What ~= PAINT_WHAT then return false end
    end
    return true
end

function BrushStrokes.appendStrokes(aggregate, strokes)
    for _, stroke in ipairs(strokes) do
        aggregate.Masks[#aggregate.Masks + 1] = BrushStrokes.newPaint(stroke)
    end
    return #aggregate.Masks
end

return BrushStrokes
