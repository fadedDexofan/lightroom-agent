local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskValues = require 'MaskValues'
local MaskSelection = require 'MaskSelection'
local RangeMaskGeometry = require 'RangeMaskGeometry'
local Reply = require 'Reply'

local RangeMaskHandler = {}


local NO_DEPTH_MAP_PROBLEM = "Lightroom found no depth map on this photo, so a depth range would select nothing;"
    .. " depth range needs device depth such as an iPhone Portrait HEIC"

local function problemUnlessDepthMapFound(kind, component)
    if kind ~= "depth" or component.CorrectionRangeMask.LuminanceDepthSampleInfo ~= nil then return nil end
    return NO_DEPTH_MAP_PROBLEM
end

local function addRangeComponent(entries, request)
    local component = RangeMaskGeometry.newComponent(request)
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

local function sourceComponent(entries, copy, label)
    local _, entry = GuardedMaskWrite.findCorrection(entries, copy.maskId)
    if not entry then
        Reply.refuse(string.format("copy_sample_from: mask %s not found on photo %s", copy.maskId, label))
    end
    for _, component in ipairs(entry.CorrectionMasks or {}) do
        if component.MaskID ~= nil and tostring(component.MaskID) == copy.toolId then return component end
    end
    Reply.refuse(string.format("copy_sample_from: tool %s is not in mask %s on photo %s", copy.toolId, copy.maskId, label))
end

local function resolveCopiedSample(catalog, photo, photoId, request, context)
    local copy = request.copy
    local sourcePhoto = photo
    if copy.photoId ~= nil and copy.photoId ~= photoId then
        sourcePhoto = PhotoLookup.requireOne(LrApplication.activeCatalog(), copy.photoId)
    end
    local sourcePhotoId = tostring(sourcePhoto.localIdentifier)
    local component = sourceComponent(GuardedMaskWrite.readEntries(catalog, sourcePhoto), copy, sourcePhotoId)
    local sourceFrame = ImageFrame.forPhoto(catalog, sourcePhoto)
    local range, problem = RangeMaskGeometry.copiableColorRange(component, sourceFrame)
    if not range then
        Reply.refuse(string.format("copy_sample_from: tool %s %s", copy.toolId, problem))
    end
    if sourceFrame.warning and sourcePhotoId ~= photoId then
        context:warn("On the source photo " .. sourcePhotoId .. ": " .. sourceFrame.warning)
    end
    request.range.sample = range.sample
    if request.range.amount == nil then request.range.amount = range.amount end
    return sourcePhotoId
end

local function resultFor(photoId, entries, location, frame)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    local kind, range = RangeMaskGeometry.rangeOf(component, frame)
    local result = {
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        type = kind,
        mode = component.MaskBlendMode == 1 and "subtract" or "add",
        invert = component.MaskInverted == true,
    }
    if kind ~= nil then result[kind] = range end
    return result
end

function RangeMaskHandler.createRangeMask(args, context)
    local displayedRequest = RangeMaskGeometry.parseCreate(args)
    DevelopSession.requireMaskApi("create_range_mask")

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)
    local copiedFrom
    if displayedRequest.copy ~= nil then
        copiedFrom = resolveCopiedSample(catalog, photo, photoId, displayedRequest, context)
    end
    local frame = ImageFrame.forPhoto(catalog, photo)
    if displayedRequest.kind == "color" and frame.warning then context:warn(frame.warning) end
    local request = RangeMaskGeometry.toStoredFrame(displayedRequest, frame)
    request.adjustments = args.adjustments
    local existing = GuardedMaskWrite.preflight(catalog, photo)
    addRangeComponent(existing, request)

    local location
    local written = DevelopSession.withPhoto(context, catalog, photo, function()
        return GuardedMaskWrite.apply(catalog, photo, {
            description = "Create range mask",
            build = function(entries)
                location = addRangeComponent(entries, request)
                return entries
            end,
            crossCheck = function(actual)
                local entry = actual[location.entry]
                local component = entry.CorrectionMasks[location.component]
                return problemUnlessDepthMapFound(request.kind, component)
                    or MaskSelection.problemUnlessListed(entry.CorrectionID, component.MaskID, RangeMaskGeometry.TOOL_TYPE, request.kind)
            end,
        })
    end)

    local result = resultFor(photoId, written.entries, location, frame)
    result.new_mask = request.maskId == nil
    if copiedFrom ~= nil then
        result.copied_from = {
            photo_id = copiedFrom, mask_id = displayedRequest.copy.maskId, tool_id = displayedRequest.copy.toolId,
        }
    end
    Log.info(string.format("Placed %s range mask %s in mask %s on photo %s",
        request.kind, result.tool_id, result.mask_id, photoId))
    return result
end

return RangeMaskHandler
