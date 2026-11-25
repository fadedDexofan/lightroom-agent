local Contract = require "Contract"
local Reply = require "Reply"

local MaskPointColors = {}

local STORED_SCALARS = { "SrcHue", "SrcSat", "SrcLum", "HueShift", "SatScale", "LumScale", "RangeAmount" }
local VARIANCE = "Variance"
local SCALARS = {
    { name = "SrcHue", required = true },
    { name = "SrcSat", required = true },
    { name = "SrcLum", required = true },
    { name = "HueShift" },
    { name = "SatScale" },
    { name = "LumScale" },
    { name = "RangeAmount" },
    { name = VARIANCE },
}

local RANGES = Contract.POINT_COLOR.ranges
local RANGE_EDGES = Contract.POINT_COLOR.range_edges

local STORED_FORMAT = "%f"
local STORED_SEPARATOR = ", "
local DEFAULT_VARIANCE = 0

local function storedNumbers(text)
    local numbers = {}
    if type(text) ~= "string" then return numbers end
    for item in text:gmatch("[^,]+") do
        numbers[#numbers + 1] = tonumber(item) or false
    end
    return numbers
end

local function storedCount() return #STORED_SCALARS + #RANGES * #RANGE_EDGES end

local function readable(numbers)
    if #numbers ~= storedCount() then return false end
    for _, number in ipairs(numbers) do
        if number == false then return false end
    end
    return true
end

function MaskPointColors.unreadableIndex(colors)
    for index, text in ipairs(type(colors) == "table" and colors or {}) do
        if not readable(storedNumbers(text)) then return index end
    end
    return nil
end

function MaskPointColors.fromStored(colors, variances)
    local swatches = {}
    if type(colors) ~= "table" then return swatches end
    local unreadable = MaskPointColors.unreadableIndex(colors)
    if unreadable then Reply.refuse("Lightroom stored an unreadable Point Color swatch at index " .. unreadable) end
    for index, text in ipairs(colors) do
        local numbers = storedNumbers(text)
        local swatch, position = {}, 0
        for _, name in ipairs(STORED_SCALARS) do
            position = position + 1
            swatch[name] = numbers[position]
        end
        for _, range in ipairs(RANGES) do
            swatch[range] = {}
            for _, edge in ipairs(RANGE_EDGES) do
                position = position + 1
                swatch[range][edge] = numbers[position]
            end
        end
        swatch[VARIANCE] = type(variances) == "table" and tonumber(variances[index]) or DEFAULT_VARIANCE
        swatches[index] = swatch
    end
    return swatches
end

function MaskPointColors.toStored(swatch)
    local texts = {}
    for _, name in ipairs(STORED_SCALARS) do
        texts[#texts + 1] = string.format(STORED_FORMAT, swatch[name])
    end
    for _, range in ipairs(RANGES) do
        for _, edge in ipairs(RANGE_EDGES) do
            texts[#texts + 1] = string.format(STORED_FORMAT, swatch[range][edge])
        end
    end
    return table.concat(texts, STORED_SEPARATOR), string.format(STORED_FORMAT, swatch[VARIANCE] or DEFAULT_VARIANCE)
end

function MaskPointColors.requireOrderedRanges(swatch, index)
    for _, range in ipairs(RANGES) do
        local edges = swatch[range]
        for position = 2, #RANGE_EDGES do
            if edges[RANGE_EDGES[position - 1]] > edges[RANGE_EDGES[position]] then
                local values = {}
                for _, edge in ipairs(RANGE_EDGES) do
                    values[#values + 1] = tostring(edges[edge])
                end
                Reply.refuse(
                    string.format(
                        "Point Color swatch %d's %s edges are not ordered (%s): %s; Lightroom drops"
                            .. " every swatch of a mask that holds such a range",
                        index,
                        range,
                        table.concat(RANGE_EDGES, " <= "),
                        table.concat(values, ", ")
                    )
                )
            end
        end
    end
end

function MaskPointColors.storedVariance(variances, index)
    if type(variances) == "table" and variances[index] ~= nil then return variances[index] end
    return string.format(STORED_FORMAT, DEFAULT_VARIANCE)
end

local function copyRange(range)
    local copied = {}
    for _, edge in ipairs(RANGE_EDGES) do
        copied[edge] = range[edge]
    end
    return copied
end

function MaskPointColors.copySwatch(swatch)
    local copied = {}
    for _, scalar in ipairs(SCALARS) do
        copied[scalar.name] = swatch[scalar.name]
    end
    for _, range in ipairs(RANGES) do
        if swatch[range] then copied[range] = copyRange(swatch[range]) end
    end
    return copied
end

function MaskPointColors.merge(current, patch)
    local merged = MaskPointColors.copySwatch(current)
    for _, scalar in ipairs(SCALARS) do
        if patch[scalar.name] ~= nil then merged[scalar.name] = patch[scalar.name] end
    end
    for _, range in ipairs(RANGES) do
        if patch[range] ~= nil then merged[range] = copyRange(patch[range]) end
    end
    return merged
end

local function storedText(value) return string.format(STORED_FORMAT, value) end

function MaskPointColors.sameSource(left, right)
    for _, name in ipairs({ "SrcHue", "SrcSat", "SrcLum" }) do
        if storedText(left[name]) ~= storedText(right[name]) then return false end
    end
    return true
end

local DEFAULT_RANGE_AMOUNT = 0.5
local DEFAULT_HUE_RANGE = { LowerNone = 0, LowerFull = 1 / 3, UpperFull = 2 / 3, UpperNone = 1 }
local FULL_HALF_WIDTH = 0.18
local FADE_WIDTH = 0.55
local SRGB_LINEAR_LIMIT = 0.0031308

local function srgbEncoded(linear)
    if linear <= SRGB_LINEAR_LIMIT then return 12.92 * linear end
    return 1.055 * linear ^ (1 / 2.4) - 0.055
end

local function rangeAround(centre)
    local lowerFull, upperFull = math.max(0, centre - FULL_HALF_WIDTH), math.min(1, centre + FULL_HALF_WIDTH)
    return {
        LowerNone = math.max(0, lowerFull - FADE_WIDTH),
        LowerFull = lowerFull,
        UpperFull = upperFull,
        UpperNone = math.min(1, upperFull + FADE_WIDTH),
    }
end

local SOURCE_STEP = 0.01

local function sourceOf(value) return math.floor(value / SOURCE_STEP + 0.5) * SOURCE_STEP end

function MaskPointColors.newSwatch(fields)
    local srcSat, srcLum = sourceOf(fields.SrcSat), sourceOf(fields.SrcLum)
    return {
        SrcHue = sourceOf(fields.SrcHue),
        SrcSat = srcSat,
        SrcLum = srcLum,
        HueShift = fields.HueShift or 0,
        SatScale = fields.SatScale or 0,
        LumScale = fields.LumScale or 0,
        RangeAmount = fields.RangeAmount or DEFAULT_RANGE_AMOUNT,
        Variance = fields.Variance or DEFAULT_VARIANCE,
        HueRange = copyRange(fields.HueRange or DEFAULT_HUE_RANGE),
        SatRange = copyRange(fields.SatRange or rangeAround(srcSat)),
        LumRange = copyRange(fields.LumRange or rangeAround(srgbEncoded(srcLum))),
    }
end

function MaskPointColors.indexed(swatches)
    local listed = {}
    for index, swatch in ipairs(swatches) do
        local entry = MaskPointColors.copySwatch(swatch)
        entry.index = index
        listed[index] = entry
    end
    return listed
end

return MaskPointColors
