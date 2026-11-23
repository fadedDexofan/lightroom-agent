local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"

local AiMaskParts = require "AiMaskParts"
local BrushStrokes = require "BrushStrokes"
local GradientGeometry = require "GradientGeometry"
local GuardedMaskWrite = require "GuardedMaskWrite"
local ImageFrame = require "ImageFrame"
local Log = require "Log"
local MaskTypes = require "MaskTypes"
local PhotoLookup = require "PhotoLookup"
local RangeMaskGeometry = require "RangeMaskGeometry"
local Reply = require "Reply"

local MaskHandler = {}

local AI_SELECTION = "aiSelection"
local BRUSH = "brush"
local RANGE = "rangeMask"
local TYPE_OF_GRADIENT_SHAPE = { linear = "gradient", radial = "radialGradient" }

local function frameOf(context, catalog, photo)
    local ok, frame = LrTasks.pcall(ImageFrame.forPhoto, catalog, photo)
    if not ok then
        context:warn(
            string.format(
                "The colour samples of photo %s could not be placed, so colour ranges are listed"
                    .. " without range: %s",
                tostring(photo.localIdentifier),
                Reply.messageOf(frame)
            )
        )
        return nil
    end
    if frame.warning then context:warn(frame.warning) end
    return frame
end

local function describeTool(component, frameOfPhoto)
    local tool = { id = component.MaskID, inverted = component.MaskInverted == true }
    local name, part = MaskTypes.nameOf(component), AiMaskParts.partOf(component)
    if name ~= nil then
        tool.type, tool.subtype = AI_SELECTION, name
    elseif part ~= nil then
        tool.type, tool.subtype, tool.part = AI_SELECTION, part.kind, part.name
    elseif BrushStrokes.isBrush(component) then
        tool.type = BRUSH
    elseif GradientGeometry.shapeOf(component) ~= nil then
        tool.type = TYPE_OF_GRADIENT_SHAPE[GradientGeometry.shapeOf(component)]
    elseif RangeMaskGeometry.kindOf(component) ~= nil then
        tool.type, tool.subtype = RANGE, RangeMaskGeometry.kindOf(component)
    else
        tool.type = component.What
    end
    if tool.type == RANGE and tool.subtype ~= RangeMaskGeometry.COLOR then
        tool.range = select(2, RangeMaskGeometry.rangeOf(component))
    elseif tool.type == RANGE and frameOfPhoto() ~= nil then
        tool.range = select(2, RangeMaskGeometry.rangeOf(component, frameOfPhoto()))
    end
    return tool
end

local function describeMask(entry, frameOfPhoto)
    local tools = {}
    for _, component in ipairs(entry.CorrectionMasks or {}) do
        tools[#tools + 1] = describeTool(component, frameOfPhoto)
    end
    return {
        id = entry.CorrectionID,
        name = entry.CorrectionName,
        hidden = entry.CorrectionActive == false,
        tools = tools,
    }
end

function MaskHandler.listMasks(args, context)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_ids[1])
    local photoId = tostring(photo.localIdentifier)
    local entries = GuardedMaskWrite.readEntries(catalog, photo)
    local read, frame = false, nil
    local function frameOfPhoto()
        if not read then
            read, frame = true, frameOf(context, catalog, photo)
        end
        return frame
    end

    local masks = {}
    for index = #entries, 1, -1 do
        masks[#masks + 1] = describeMask(entries[index], frameOfPhoto)
    end

    Log.info(string.format("Listed %d masks on photo %s", #masks, photoId))
    return { photo_id = photoId, count = #masks, masks = masks }
end

return MaskHandler
