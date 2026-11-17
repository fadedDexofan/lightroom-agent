local Contract = require 'Contract'

local MaskTypes = {}

MaskTypes.SPECS = {}
for _, maskType in ipairs(Contract.MASK_TYPES) do
    MaskTypes.SPECS[maskType.name] = { toolType = maskType.toolType, subtype = maskType.subtype }
end

return MaskTypes
