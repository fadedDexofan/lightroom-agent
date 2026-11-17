local Contract = require 'Contract'

local MaskTypes = {}

local AI_KIND = "Mask/Image"
local AI_MASK_VERSION = 1
local FORMS = {
    add = { MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    subtract = { MaskBlendMode = 1, MaskValue = 0, MaskInverted = false },
    intersect = { MaskBlendMode = 1, MaskValue = 0, MaskInverted = true },
}

MaskTypes.SPECS = {}
for _, maskType in ipairs(Contract.MASK_TYPES) do
    MaskTypes.SPECS[maskType.name] = { label = maskType.label, stored = maskType.stored }
end

function MaskTypes.nameOf(component)
    if component.What ~= AI_KIND then return nil end
    for _, maskType in ipairs(Contract.MASK_TYPES) do
        local matches = true
        for key, value in pairs(maskType.stored) do
            if component[key] ~= value then matches = false end
        end
        if matches then return maskType.name end
    end
    return nil
end

function MaskTypes.component(name, operation)
    local spec = MaskTypes.SPECS[name]
    local component = { What = AI_KIND, MaskVersion = AI_MASK_VERSION, MaskName = spec.label .. " 1", MaskActive = true }
    for key, value in pairs(spec.stored) do component[key] = value end
    for key, value in pairs(FORMS[operation]) do component[key] = value end
    return component
end

return MaskTypes
