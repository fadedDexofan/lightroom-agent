local LocalSliders = require 'LocalSliders'
local MaskSelection = require 'MaskSelection'

local MaskCreationAdjustments = {}

local CONFIRM_TIMEOUT_SECONDS = 2

function MaskCreationAdjustments.parse(args)
    if args.adjustments == nil then return nil end
    MaskSelection.requireControllerFunctions("mask creation adjustments",
        { "getValue", "getSelectedMask" }, "Lightroom Classic 11")
    return args.adjustments
end

local function eachRequested(values, fn)
    for _, slider in ipairs(LocalSliders.list) do
        if values[slider.name] ~= nil then fn(slider, values[slider.name]) end
    end
end

function MaskCreationAdjustments.write(entry, values)
    eachRequested(values or {}, function(slider, value) entry[slider.stored] = value / slider.scale end)
end

function MaskCreationAdjustments.confirmSelected(values)
    eachRequested(values, function(slider, value)
        if not MaskSelection.sliderKept(slider, value, CONFIRM_TIMEOUT_SECONDS) then
            error(MaskSelection.sliderNotKept(slider, value), 0)
        end
    end)
end

function MaskCreationAdjustments.confirm(catalog, photo, maskId, values)
    if values == nil then return end
    MaskSelection.withMaskSelected(catalog, photo, tostring(maskId), function()
        MaskCreationAdjustments.confirmSelected(values)
    end)
end

return MaskCreationAdjustments
