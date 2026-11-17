local Contract = require 'Contract'
local DecimalText = require 'DecimalText'

local RangeMaskGeometry = {}

local LUMINANCE = "luminance"
local COLOR = "color"
local DEPTH = "depth"

local RANGE_TYPE_OF_KIND = { [COLOR] = 1, [LUMINANCE] = 2, [DEPTH] = -1 }
local KIND_OF_RANGE_TYPE = { [1] = COLOR, [2] = LUMINANCE, [-1] = DEPTH }
local TRAPEZOID_FIELD_OF_KIND = { [LUMINANCE] = "LumRange", [DEPTH] = "DepthRange" }
local NAME_OF_KIND = { [LUMINANCE] = "Luminance Range", [COLOR] = "Color Range", [DEPTH] = "Depth Range" }

local BLEND_MODE_OF_MODE = { add = 0, subtract = 1 }
local MASK_VALUE_OF_MODE = { add = 1, subtract = 0 }

local RANGE_VERSION = 3
local RANGE_SAMPLE_TYPE = 0
local POINT_MODEL_TRAILER = 0
local DEFAULT_FALLOFF = 0.1
local DEFAULT_COLOR_AMOUNT = 0.5
local STORED_PLACES = Contract.STORED_MASK_DECIMAL_PLACES
local STORED_SCALE = 10 ^ STORED_PLACES

local SAMPLE_FIELDS = { "x", "y", "l", "a", "b" }

local function round(value)
    return math.floor(value * STORED_SCALE + 0.5) / STORED_SCALE
end

local function parseTrapezoid(value)
    return { min = value.min, max = value.max, falloff = value.falloff or DEFAULT_FALLOFF }
end

local function parseColor(value)
    local sample = {}
    for _, field in ipairs(SAMPLE_FIELDS) do sample[field] = value.sample[field] end
    return { sample = sample, amount = value.amount or DEFAULT_COLOR_AMOUNT }
end

local function parseCopy(value)
    local photoId = value.photo_id
    if type(photoId) == "number" then photoId = tostring(photoId) end
    return { maskId = value.mask_id, toolId = value.tool_id, photoId = photoId }
end

local PARSER_OF_KIND = {
    [LUMINANCE] = parseTrapezoid,
    [COLOR] = parseColor,
    [DEPTH] = parseTrapezoid,
}

function RangeMaskGeometry.parseCreate(args)
    local kind = args.type
    local copy, range
    if args.copy_sample_from ~= nil then
        copy = parseCopy(args.copy_sample_from)
        range = { amount = (args.color or {}).amount }
    else
        range = PARSER_OF_KIND[kind](args[kind])
    end
    return {
        kind = kind, range = range, maskId = args.mask_id, mode = args.mode or "add", name = args.name,
        invert = args.invert == true, copy = copy,
    }
end

local function trapezoidOf(luminance)
    local lowerStart = round(math.max(0, luminance.min - luminance.falloff))
    local upperEnd = round(math.min(1, luminance.max + luminance.falloff))
    return { lowerStart, round(luminance.min), round(luminance.max), upperEnd }
end

local function rangeSettingsFor(kind, range)
    local settings = {
        Type = RANGE_TYPE_OF_KIND[kind],
        Version = RANGE_VERSION,
        SampleType = RANGE_SAMPLE_TYPE,
    }
    if TRAPEZOID_FIELD_OF_KIND[kind] ~= nil then
        local trapezoid = trapezoidOf(range)
        settings[TRAPEZOID_FIELD_OF_KIND[kind]] = table.concat({
            DecimalText.fixed(trapezoid[1], STORED_PLACES), DecimalText.fixed(trapezoid[2], STORED_PLACES),
            DecimalText.fixed(trapezoid[3], STORED_PLACES), DecimalText.fixed(trapezoid[4], STORED_PLACES),
        }, " ")
        return settings
    end
    local sample = range.sample
    settings.ColorAmount = round(range.amount)
    settings.PointModels = {
        table.concat({
            DecimalText.fixed(sample.l, STORED_PLACES), DecimalText.fixed(sample.a, STORED_PLACES), DecimalText.fixed(sample.b, STORED_PLACES),
            DecimalText.fixed(sample.x, STORED_PLACES), DecimalText.fixed(sample.y, STORED_PLACES), string.format("%d", POINT_MODEL_TRAILER),
        }, " "),
    }
    return settings
end

function RangeMaskGeometry.toStoredFrame(request, frame)
    if request.kind ~= COLOR then return request end
    local stored = {}
    for key, value in pairs(request) do stored[key] = value end
    local sample = {}
    for key, value in pairs(request.range.sample) do sample[key] = value end
    sample.x, sample.y = frame.toStored(sample.x, sample.y)
    stored.range = { sample = sample, amount = request.range.amount }
    return stored
end

function RangeMaskGeometry.newComponent(request)
    return {
        What = "Mask/RangeMask",
        MaskActive = true,
        MaskInverted = request.invert,
        MaskBlendMode = BLEND_MODE_OF_MODE[request.mode],
        MaskValue = MASK_VALUE_OF_MODE[request.mode],
        MaskName = NAME_OF_KIND[request.kind],
        CorrectionRangeMask = rangeSettingsFor(request.kind, request.range),
    }
end

local function numbersIn(text)
    local numbers = {}
    for token in tostring(text):gmatch("%S+") do
        local number = DecimalText.parse(token)
        if number == nil then return nil end
        numbers[#numbers + 1] = number
    end
    return numbers
end

function RangeMaskGeometry.kindOf(component)
    if component.What ~= "Mask/RangeMask" or type(component.CorrectionRangeMask) ~= "table" then return nil end
    return KIND_OF_RANGE_TYPE[component.CorrectionRangeMask.Type]
end

function RangeMaskGeometry.rangeOf(component, frame)
    local kind = RangeMaskGeometry.kindOf(component)
    if kind == nil then return nil end
    local range = component.CorrectionRangeMask
    if TRAPEZOID_FIELD_OF_KIND[kind] ~= nil then
        local values = numbersIn(range[TRAPEZOID_FIELD_OF_KIND[kind]])
        if values == nil or #values ~= 4 then return nil end
        return kind, {
            min = round(values[2]),
            max = round(values[3]),
            lower_falloff = round(values[2] - values[1]),
            upper_falloff = round(values[4] - values[3]),
        }
    end
    if kind == COLOR then
        if type(range.PointModels) ~= "table" or #range.PointModels == 0 then return nil end
        local samples = {}
        for index, model in ipairs(range.PointModels) do
            local point = numbersIn(model)
            if point == nil or #point < 5 then return nil end
            local x, y = frame.toDisplayed(point[4], point[5])
            samples[index] = {
                x = round(x), y = round(y),
                l = round(point[1]), a = round(point[2]), b = round(point[3]),
            }
        end
        return kind, { samples = samples, amount = round(range.ColorAmount) }
    end
    return nil
end

function RangeMaskGeometry.copiableColorRange(component, frame)
    if type(component) ~= "table" or component.What ~= "Mask/RangeMask"
        or type(component.CorrectionRangeMask) ~= "table" then
        return nil, "is not a range mask"
    end
    local stored = component.CorrectionRangeMask
    local kind = KIND_OF_RANGE_TYPE[stored.Type]
    if kind ~= COLOR then
        local description = kind ~= nil and (kind .. " range") or "range of an unsupported type"
        return nil, "is a " .. description .. ", not a color range"
    end
    if type(stored.PointModels) ~= "table" or #stored.PointModels ~= 1 then
        local count = type(stored.PointModels) == "table" and #stored.PointModels or 0
        return nil, string.format("has %d color sample points; exactly one can be copied", count)
    end
    local _, range = RangeMaskGeometry.rangeOf(component, frame)
    if range == nil then return nil, "has a color sample that cannot be read" end
    return { sample = range.samples[1], amount = range.amount }
end

return RangeMaskGeometry
