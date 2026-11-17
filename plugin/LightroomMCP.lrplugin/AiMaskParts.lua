local Contract = require 'Contract'

local AiMaskParts = {}

local ALL_PEOPLE_SUBTYPE = 3
local LANDSCAPE_SUBTYPE = 0
local MASK_VERSION = 1
local CENTRE_REFERENCE_POINT = "0.500000 0.500000"
local NO_ERROR = 0

local PEOPLE_PARTS = Contract.PEOPLE_MASK_PARTS
local LANDSCAPE_CATEGORIES = Contract.LANDSCAPE_MASK_CATEGORIES

local ZEROED_LOCAL_FIELDS = {
    "LocalExposure", "LocalContrast", "LocalClarity", "LocalBrightness",
    "LocalTemperature", "LocalTint", "LocalExposure2012", "LocalContrast2012", "LocalHighlights2012",
    "LocalShadows2012", "LocalWhites2012", "LocalBlacks2012", "LocalTexture", "LocalClarity2012",
    "LocalDehaze", "LocalHue", "LocalSaturation", "LocalSharpness", "LocalLuminanceNoise",
    "LocalMoire", "LocalDefringe", "LocalToningHue", "LocalToningSaturation", "LocalGrain",
}

local function indexByName(list)
    local byName = {}
    for _, spec in ipairs(list) do byName[spec.name] = spec end
    return byName
end

local PEOPLE_BY_NAME = indexByName(PEOPLE_PARTS)
local LANDSCAPE_BY_NAME = indexByName(LANDSCAPE_CATEGORIES)

local function specsOf(names, byName)
    local specs = {}
    for index, name in ipairs(names) do specs[index] = byName[name] end
    return specs
end

function AiMaskParts.parsePeople(args)
    return { kind = "people", specs = specsOf(args.parts, PEOPLE_BY_NAME) }
end

function AiMaskParts.parseLandscape(args)
    return { kind = "landscape", specs = specsOf(args.categories, LANDSCAPE_BY_NAME) }
end

local function newComponent(spec, request)
    local subType = LANDSCAPE_SUBTYPE
    local name = spec.label
    if request.kind == "people" then
        subType = ALL_PEOPLE_SUBTYPE
        name = "People - " .. spec.label
    end
    local component = {
        What = "Mask/Image",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskVersion = MASK_VERSION,
        MaskName = name,
        MaskSubType = subType,
        MaskSubCategoryID = spec.category,
        ReferencePoint = CENTRE_REFERENCE_POINT,
        ErrorReason = NO_ERROR,
    }
    return component, name
end

function AiMaskParts.newEntry(spec, request)
    local component, name = newComponent(spec, request)
    local entry = {
        What = "Correction",
        CorrectionName = name,
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionMasks = { component },
        CorrectionReferenceX = 0.5,
        CorrectionReferenceY = 0.5,
        LocalCurveRefineSaturation = 100,
    }
    for _, field in ipairs(ZEROED_LOCAL_FIELDS) do entry[field] = 0 end
    return entry
end

return AiMaskParts
