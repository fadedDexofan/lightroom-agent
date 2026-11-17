local Contract = require 'Contract'

local PhotoMarks = {}

local RAW_KEYS = { 'rating', 'pickStatus', 'colorNameForLabel' }

function PhotoMarks.withRawKeys(keys)
    local all = {}
    for _, key in ipairs(keys) do all[#all + 1] = key end
    for _, key in ipairs(RAW_KEYS) do all[#all + 1] = key end
    return all
end

local FLAG_BY_PICK_STATUS = {}
for _, flag in ipairs(Contract.PHOTO_FLAGS) do FLAG_BY_PICK_STATUS[flag.pickStatus] = flag.name end

local LABEL_BY_COLOR_NAME = { gray = "none" }
for _, label in ipairs(Contract.COLOR_LABELS) do LABEL_BY_COLOR_NAME[label.name] = label.name end

function PhotoMarks.of(raw)
    local colorName = raw.colorNameForLabel
    return {
        rating = raw.rating or 0,
        flag = FLAG_BY_PICK_STATUS[raw.pickStatus or 0],
        color_label = colorName == nil and "none" or LABEL_BY_COLOR_NAME[colorName] or colorName,
    }
end

return PhotoMarks
