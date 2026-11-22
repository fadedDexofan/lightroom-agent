local Contract = require "Contract"

local LocalSliders = {}

LocalSliders.list = Contract.LOCAL_KEYS

LocalSliders.byStored = {}
for _, slider in ipairs(LocalSliders.list) do
    LocalSliders.byStored[slider.stored] = slider
end

function LocalSliders.neutralOf(slider) return slider.neutral or 0 end

local REPORTED_DIGITS = "%.10g"

function LocalSliders.storedOf(slider, value)
    local places = slider.storedDecimals or Contract.STORED_MASK_DECIMAL_PLACES
    return tonumber(string.format("%." .. places .. "f", value / slider.scale))
end

function LocalSliders.valueOf(slider, stored) return tonumber(string.format(REPORTED_DIGITS, stored * slider.scale)) end

function LocalSliders.storedNeutralOf(stored)
    local slider = LocalSliders.byStored[stored]
    return slider and LocalSliders.neutralOf(slider) / slider.scale or 0
end

return LocalSliders
