local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local GradientGeometry = require 'GradientGeometry'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskValues = require 'MaskValues'
local Reply = require 'Reply'

local GradientMaskHandler = {}

local function placementFor(catalog, photo)
    local frame = ImageFrame.forPhoto(catalog, photo)
    return { frame = frame, storedAspect = frame.storedSize.width / frame.storedSize.height }
end

local function resultFor(photoId, entries, location, placement)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    local storedShape, storedGeometry = GradientGeometry.geometryOf(component, placement.storedAspect)
    local shape = storedShape
    local geometry = GradientGeometry.toDisplayedFrame(storedShape, storedGeometry, placement.frame)
    return {
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        shape = shape,
        mode = component.MaskBlendMode == 1 and "subtract" or "add",
        geometry = geometry,
    }
end

local function addGradient(entries, request, placement)
    local storedGeometry = GradientGeometry.toStoredFrame(request.shape, request.geometry, placement.frame)
    local component = GradientGeometry.newComponent(request.shape, storedGeometry, request.mode,
        placement.storedAspect)
    if request.maskId == nil then
        local name = request.name or component.MaskName
        entries[#entries + 1] = GuardedMaskWrite.newCorrection(name, { component })
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

function GradientMaskHandler.createGradientMask(args, context)
    local request = GradientGeometry.parseCreate(args)
    request.adjustments = args.adjustments

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)
    local placement = placementFor(catalog, photo)

    local location
    local written = GuardedMaskWrite.apply(context, catalog, photo, {
        description = "Create gradient mask",
        build = function(entries)
            location = addGradient(entries, request, placement)
            return entries
        end,
    })

    if placement.frame.warning then context:warn(placement.frame.warning) end
    local result = resultFor(photoId, written.entries, location, placement)
    result.new_mask = request.maskId == nil
    Log.info(string.format("Placed %s gradient %s in mask %s on photo %s",
        request.shape, result.tool_id, result.mask_id, photoId))
    return result
end

local function reshapeGradient(entries, request, placement)
    local entryIndex, componentIndex, component = GuardedMaskWrite.findComponent(entries, request.toolId)
    if not entryIndex then
        Reply.refuse("Gradient tool not found on this photo: " .. request.toolId)
    end
    local shape, storedGeometry = GradientGeometry.geometryOf(component, placement.storedAspect)
    if not shape then
        Reply.refuse(string.format("Tool %s is a %s mask, not a linear or radial gradient",
            request.toolId, tostring(component.What)))
    end
    local displayedGeometry = GradientGeometry.toDisplayedFrame(shape, storedGeometry, placement.frame)
    local merged = GradientGeometry.mergeChanges(shape, displayedGeometry, request.changes)
    local storedMerged = GradientGeometry.toStoredFrame(shape, merged, placement.frame)
    GradientGeometry.applyGeometry(shape, component, storedMerged, placement.storedAspect)
    local entry = entries[entryIndex]
    entry.CorrectionReferenceX = nil
    entry.CorrectionReferenceY = nil
    return { entry = entryIndex, component = componentIndex, shape = shape }
end

function GradientMaskHandler.updateGradientMask(args, context)
    local request = GradientGeometry.parseUpdate(args)

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)
    local placement = placementFor(catalog, photo)

    local location
    local written = GuardedMaskWrite.apply(context, catalog, photo, {
        description = "Update gradient mask",
        build = function(entries)
            location = reshapeGradient(entries, request, placement)
            return entries
        end,
    })

    if placement.frame.warning then context:warn(placement.frame.warning) end
    local result = resultFor(photoId, written.entries, location, placement)
    Log.info(string.format("Reshaped %s gradient %s in mask %s on photo %s",
        result.shape, result.tool_id, result.mask_id, photoId))
    return result
end

return GradientMaskHandler
