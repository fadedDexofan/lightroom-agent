local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local Reply = require 'Reply'
local MaskSelection = require 'MaskSelection'
local RangeMaskGeometry = require 'RangeMaskGeometry'

local MaskHandler = {}

local function storedRanges(catalog, photo)
    local entries = GuardedMaskWrite.readEntries(catalog, photo)
    local frame = ImageFrame.forPhoto(catalog, photo)
    local ranges = {}
    for _, entry in ipairs(entries) do
        for _, component in ipairs(entry.CorrectionMasks or {}) do
            local kind, range = RangeMaskGeometry.rangeOf(component, frame)
            if kind ~= nil then ranges[tostring(component.MaskID)] = range end
        end
    end
    return ranges
end

local function rangesByToolId(context, catalog, photo)
    local ok, ranges = LrTasks.pcall(storedRanges, catalog, photo)
    if ok then return ranges end
    context:warn(string.format("The stored ranges of photo %s could not be read, so range tools are listed without"
        .. " range: %s", tostring(photo.localIdentifier), Reply.messageOf(ranges)))
    return {}
end

function MaskHandler.listMasks(args, context)
    DevelopSession.requireMaskApi("list_masks")

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)

    local raw = DevelopSession.withPhoto(context, catalog, photo, function()
        return { masks = MaskSelection.readMasks(catalog, photo), ranges = rangesByToolId(context, catalog, photo) }
    end)

    local masks = {}
    for _, mask in ipairs(raw.masks) do
        masks[#masks + 1] = MaskSelection.normalizeMask(mask, raw.ranges)
    end

    Log.info(string.format("Listed %d masks on photo %s", #masks, photoId))

    return {
        photo_id = photoId,
        count = #masks,
        masks = masks,
    }
end

return MaskHandler
