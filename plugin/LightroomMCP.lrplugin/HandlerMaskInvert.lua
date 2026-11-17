local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskSelection = require 'MaskSelection'
local MaskValues = require 'MaskValues'
local Reply = require 'Reply'

local MaskInvertHandler = {}

local INVERSION_VISIBLE_TIMEOUT_SECONDS = 5
local INVERT_API_FUNCTIONS = { "goToMasking", "invertMask", "duplicateAndInvertMask" }
local INVERT_API_MINIMUM_VERSION = "Lightroom Classic 11.4"
local MODE_IN_PLACE = "in_place"
local MODE_COPY = "copy"

local function describeMask(mask)
    local tools = {}
    if type(mask.Tools) == "table" then
        for _, tool in ipairs(mask.Tools) do
            if type(tool) == "table" then
                tools[#tools + 1] = { id = MaskSelection.idString(tool.ID), inverted = tool.Inverted == true }
            end
        end
    end
    return { id = mask.ID, name = type(mask.Name) == "string" and mask.Name or nil, tools = tools }
end

local function callInvertFunction(name, maskId)
    LrDevelopController.goToMasking()
    local ok, result = LrTasks.pcall(LrDevelopController[name], maskId)
    if not ok then
        error("Lightroom could not run " .. name .. " on mask " .. maskId .. ": " .. tostring(result), 0)
    end
    if result == false then
        error("Lightroom refused " .. name .. " on mask " .. maskId, 0)
    end
end

local function invertInPlace(catalog, photo, photoId, maskId)
    local before = MaskSelection.requireMask(MaskSelection.readMasks(catalog, photo), maskId, photoId)
    local fingerprintBefore = MaskSelection.fingerprint(before)

    callInvertFunction("invertMask", maskId)

    local after
    local changed = DevelopSession.waitFor(function()
        after = MaskSelection.findMask(MaskSelection.readMasksOrNil(), maskId)
        return after ~= nil and MaskSelection.fingerprint(after) ~= fingerprintBefore
    end, INVERSION_VISIBLE_TIMEOUT_SECONDS)
    if not changed then
        error("Lightroom did not report mask " .. maskId .. " on photo " .. photoId
            .. " as changed after invertMask, so whether it is inverted is unknown; read it with list_masks"
            .. " before calling invert_mask again, which would flip it back", 0)
    end
    return {
        mode = MODE_IN_PLACE,
        mask_id = maskId,
        mask = describeMask(after),
    }
end

local function newMaskIds(knownIds, masksAfter)
    local fresh = {}
    for _, mask in ipairs(MaskSelection.masksNotIn(masksAfter, knownIds)) do
        fresh[#fresh + 1] = MaskSelection.idString(mask.ID)
    end
    return fresh
end

local function copyValues(catalog, photo, maskId, copyId)
    MaskValues.waitUntilSaved(catalog, photo, copyId, "the inverted copy")
    MaskValues.copy(catalog, photo, maskId, copyId)
end

local function duplicateInverted(context, catalog, photo, photoId, maskId, masksBefore)
    local originalFingerprint = MaskSelection.fingerprint(MaskSelection.findMask(masksBefore, maskId))
    local idsBefore = MaskSelection.idSet(masksBefore)

    callInvertFunction("duplicateAndInvertMask", maskId)

    local masksAfter
    local fresh = {}
    local copyAppeared = DevelopSession.waitFor(function()
        masksAfter = MaskSelection.readMasksOrNil()
        fresh = masksAfter and newMaskIds(idsBefore, masksAfter) or {}
        return #fresh > 0
    end, INVERSION_VISIBLE_TIMEOUT_SECONDS)
    if not copyAppeared then
        error("Lightroom did not create an inverted copy of mask " .. maskId .. " on photo " .. photoId, 0)
    end
    if #fresh > 1 then
        error("Lightroom created " .. #fresh .. " new masks on photo " .. photoId
            .. " while copying mask " .. maskId .. "; cannot tell which is the copy", 0)
    end

    local originalAfter = MaskSelection.findMask(masksAfter, maskId)
    local sourceChange
    if not originalAfter then
        sourceChange = string.format("Lightroom no longer lists the source mask %s on photo %s after making the"
            .. " inverted copy", maskId, photoId)
    elseif MaskSelection.fingerprint(originalAfter) ~= originalFingerprint then
        sourceChange = string.format("Lightroom changed the source mask %s on photo %s while making the inverted"
            .. " copy", maskId, photoId)
    end
    if sourceChange then context:warn(sourceChange .. "; read the masks with list_masks before editing it") end

    local copyId = fresh[1]
    local copied, copyError = LrTasks.pcall(copyValues, catalog, photo, maskId, copyId)
    if not copied then
        local failure = string.format("The adjustments of mask %s could not be copied to its inverted copy (%s)", maskId,
            Reply.messageOf(copyError))
        local problem = MaskSelection.problemUnlessAddedRemoved(catalog, photo, idsBefore, "the copy " .. copyId)
        if problem then error(failure .. "; " .. problem, 0) end
        if sourceChange then
            error(failure .. "; the copy was removed, but " .. sourceChange .. ": read the masks with list_masks"
                .. " before retrying", 0)
        end
        if not Reply.refusalOf(copyError) then
            error(failure .. "; the copy was removed: read the masks with list_masks before retrying", 0)
        end
        Reply.refuse(failure .. "; the copy was removed")
    end

    local copy = MaskSelection.findMask(MaskSelection.readMasksOrNil(), copyId)
    return {
        mode = MODE_COPY,
        source_mask_id = maskId,
        mask_id = copyId,
        mask = copy and describeMask(copy) or nil,
    }
end

local function invertAsCopy(context, catalog, photo, photoId, maskId)
    MaskValues.requireSaved(catalog, photo, maskId)
    local masksBefore = MaskSelection.readMasks(catalog, photo)
    MaskSelection.requireMask(masksBefore, maskId, photoId)
    local previousTool
    local ok, result = LrTasks.pcall(MaskSelection.keepingSelection, function()
        previousTool = MaskSelection.openMaskingTool()
        return duplicateInverted(context, catalog, photo, photoId, maskId, masksBefore)
    end)
    MaskSelection.restoreTool(previousTool)
    if not ok then error(result, 0) end
    return result
end

function MaskInvertHandler.invertMask(args, context)
    local maskId = args.mask_id
    local mode = args.mode
    MaskSelection.requireControllerFunctions("invert_mask", INVERT_API_FUNCTIONS, INVERT_API_MINIMUM_VERSION)

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)

    local result = DevelopSession.withPhoto(context, catalog, photo, function()
        if mode == MODE_COPY then return invertAsCopy(context, catalog, photo, photoId, maskId) end
        return invertInPlace(catalog, photo, photoId, maskId)
    end)

    Log.info(string.format("Inverted mask %s on photo %s (%s) -> %s", maskId, photoId, mode, result.mask_id))

    result.photo_id = photoId
    return result
end

return MaskInvertHandler
