local Contract = require 'Contract'

local LocalSliders = {}

LocalSliders.list = Contract.LOCAL_KEYS

LocalSliders.byStored = {}
for _, slider in ipairs(LocalSliders.list) do
    LocalSliders.byStored[slider.stored] = slider
end

function LocalSliders.neutralOf(slider)
    return slider.neutral or 0
end

function LocalSliders.storedNeutralOf(stored)
    local slider = LocalSliders.byStored[stored]
    return slider and LocalSliders.neutralOf(slider) / slider.scale or 0
end

return LocalSliders
