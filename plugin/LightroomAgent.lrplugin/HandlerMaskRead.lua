local LrApplication = import "LrApplication"

local PhotoLookup = require "PhotoLookup"
local MaskValues = require "MaskValues"

local MaskReadHandler = {}

local KINDS = { "adjustments", "curves", "point_colors" }
local RESULT_FIELD = { adjustments = "adjustments", curves = "curves", point_colors = "swatches" }

local function kindsOf(value)
    if value == nil then return KINDS end
    local asked = {}
    for _, kind in ipairs(value) do
        asked[kind] = true
    end
    local ordered = {}
    for _, kind in ipairs(KINDS) do
        if asked[kind] then ordered[#ordered + 1] = kind end
    end
    return ordered
end

function MaskReadHandler.getMask(args)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local fields = {}
    for _, kind in ipairs(kindsOf(args.kinds)) do
        fields[#fields + 1] = RESULT_FIELD[kind]
    end
    local result = MaskValues.read(catalog, photo, args.mask_id, fields)
    result.photo_id = tostring(photo.localIdentifier)
    result.mask_id = args.mask_id
    return result
end

return MaskReadHandler
