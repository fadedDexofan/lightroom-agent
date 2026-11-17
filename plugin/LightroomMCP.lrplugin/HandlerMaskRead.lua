local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local MaskSelection = require 'MaskSelection'
local Adjustments = require 'HandlerMaskAdjustments'
local Curves = require 'HandlerMaskCurves'
local PointColors = require 'HandlerMaskPointColors'

local MaskReadHandler = {}

local KINDS = { "adjustments", "curves", "point_colors" }
local READERS = {
    adjustments = { label = "Lightroom Classic 11",
        functions = { "getValue", "getSelectedMask" }, read = Adjustments.readSelected },
    curves = { label = "Lightroom Classic 12.3",
        functions = { "getValue", "getSelectedMask" }, read = Curves.readSelected },
    point_colors = { label = "Lightroom Classic 13.2",
        functions = { "getValue", "getSelectedMask", "getSelectedPointColorSwatchIndex" }, read = PointColors.readSelected },
}

local function kindsOf(value)
    if value == nil then return KINDS end
    local asked = {}
    for _, kind in ipairs(value) do asked[kind] = true end
    local ordered = {}
    for _, kind in ipairs(KINDS) do
        if asked[kind] then ordered[#ordered + 1] = kind end
    end
    return ordered
end

local function errorsMessage(errors)
    local messages = {}
    for _, kind in ipairs(KINDS) do
        if errors[kind] then messages[#messages + 1] = kind .. ": " .. errors[kind] end
    end
    return table.concat(messages, "; ")
end

function MaskReadHandler.getMask(args, context)
    local maskId = args.mask_id
    local kinds = kindsOf(args.kinds)
    local supported, errors = {}, {}
    for _, kind in ipairs(kinds) do
        local reader = READERS[kind]
        local ok, err = LrTasks.pcall(function()
            MaskSelection.requireControllerFunctions("get_mask " .. kind, reader.functions, reader.label)
        end)
        if ok then supported[#supported + 1] = kind else errors[kind] = tostring(err) end
    end
    if #supported == 0 then error(errorsMessage(errors), 0) end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)
    return DevelopSession.withPhoto(context, catalog, photo, function()
        return MaskSelection.withMaskSelected(catalog, photo, maskId, function()
            local result = { photo_id = photoId, mask_id = maskId }
            local completed = 0
            for _, kind in ipairs(supported) do
                local ok, values = LrTasks.pcall(READERS[kind].read, photoId, maskId)
                if ok then
                    for key, value in pairs(values) do
                        if key == "unavailable" then
                            result.unavailable = result.unavailable or {}
                            result.unavailable[kind] = value
                        else
                            result[key] = value
                        end
                    end
                    completed = completed + 1
                else
                    errors[kind] = tostring(values)
                end
            end
            if completed == 0 then error(errorsMessage(errors), 0) end
            if next(errors) then result.errors = errors end
            return result
        end)
    end)
end

return MaskReadHandler
