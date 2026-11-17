local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local BrushStrokes = require 'BrushStrokes'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskValues = require 'MaskValues'
local Reply = require 'Reply'

local BrushMaskHandler = {}


local function resultFor(photoId, entries, location, strokesAdded)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    return {
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        strokes_added = strokesAdded,
        stroke_count = #component.Masks,
    }
end

local function addBrush(entries, request)
    local component = BrushStrokes.newAggregate(request.strokes)
    if request.maskId == nil then
        entries[#entries + 1] = GuardedMaskWrite.newCorrection(request.name or component.MaskName, { component })
        MaskValues.storeAdjustments(entries[#entries], request.adjustments)
        return { entry = #entries, component = 1 }
    end
    local index, entry = GuardedMaskWrite.findCorrection(entries, request.maskId)
    if not index then
        Reply.refuse("Mask not found on this photo: " .. request.maskId)
    end
    entry.CorrectionMasks[#entry.CorrectionMasks + 1] = component
    return { entry = index, component = #entry.CorrectionMasks }
end

function BrushMaskHandler.createBrushMask(args, context)
    local strokes = BrushStrokes.parseStrokes(args.strokes)
    local maskId = args.mask_id
    local name = args.name

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)
    local frame = ImageFrame.forPhoto(catalog, photo)
    local request = {
        strokes = BrushStrokes.toStoredFrame(strokes, frame),
        maskId = maskId,
        name = name,
        adjustments = args.adjustments,
    }

    local location
    local written = GuardedMaskWrite.apply(context, catalog, photo, {
        description = "Create brush mask",
        build = function(entries)
            location = addBrush(entries, request)
            return entries
        end,
    })

    if frame.warning then context:warn(frame.warning) end
    local result = resultFor(photoId, written.entries, location, #strokes)
    result.new_mask = maskId == nil
    Log.info(string.format("Painted %d brush stroke(s) as tool %s in mask %s on photo %s",
        #strokes, result.tool_id, result.mask_id, photoId))
    return result
end

local function appendToBrush(entries, request)
    local entryIndex, componentIndex, component = GuardedMaskWrite.findComponent(entries, request.toolId)
    if not entryIndex then
        Reply.refuse("Brush tool not found on this photo: " .. request.toolId)
    end
    if not BrushStrokes.isBrush(component) then
        Reply.refuse(string.format("Tool %s is a %s mask, not a brush", request.toolId, tostring(component.What)))
    end
    BrushStrokes.appendStrokes(component, request.strokes)
    return { entry = entryIndex, component = componentIndex }
end

function BrushMaskHandler.addBrushStrokes(args, context)
    local toolId = args.tool_id
    local strokes = BrushStrokes.parseStrokes(args.strokes)

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)
    local frame = ImageFrame.forPhoto(catalog, photo)
    local request = {
        toolId = toolId,
        strokes = BrushStrokes.toStoredFrame(strokes, frame),
    }

    local location
    local written = GuardedMaskWrite.apply(context, catalog, photo, {
        description = "Add brush strokes",
        build = function(entries)
            location = appendToBrush(entries, request)
            return entries
        end,
    })

    if frame.warning then context:warn(frame.warning) end
    local result = resultFor(photoId, written.entries, location, #strokes)
    Log.info(string.format("Added %d brush stroke(s) to tool %s in mask %s on photo %s",
        #strokes, result.tool_id, result.mask_id, photoId))
    return result
end

return BrushMaskHandler
