local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local LocalSliders = require 'LocalSliders'
local Log = require 'Log'
local MaskSelection = require 'MaskSelection'
local Reply = require 'Reply'

local MaskInvertHandler = {}

local INVERSION_VISIBLE_TIMEOUT_SECONDS = 5
local INVERT_API_FUNCTIONS = { "goToMasking", "invertMask", "duplicateAndInvertMask" }
local INVERT_API_MINIMUM_VERSION = "Lightroom Classic 11.4"
local COPY_PERSIST_SETTLE_SECONDS = 0.5
local NOT_COPIED = { "curves", "point_colors", "LocalHue" }
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

local function readSliderValues()
    local values = {}
    for _, slider in ipairs(LocalSliders.list) do
        values[slider.name] = MaskSelection.readSlider(slider.name)
    end
    return values
end

local function copyAdjustments(values, copyId, written)
    if not MaskSelection.selectMaskAndWait(copyId) then
        error("Could not select the inverted copy " .. copyId, 0)
    end
    for _, slider in ipairs(LocalSliders.list) do
        local wanted = values[slider.name]
        if wanted ~= nil and not MaskSelection.sliderNear(slider, MaskSelection.readSlider(slider.name), wanted) then
            local kept, problem, sent = MaskSelection.writeSlider(slider, wanted, copyId)
            if sent then written[#written + 1] = slider.name end
            if not kept then error(problem .. " on the copy", 0) end
        end
    end
    return #written
end

local function invertAsCopy(context, catalog, photo, photoId, maskId)
    return MaskSelection.withMaskSelected(catalog, photo, maskId, function(masksBefore)
        local originalFingerprint = MaskSelection.fingerprint(MaskSelection.findMask(masksBefore, maskId))
        local idsBefore = MaskSelection.idSet(masksBefore)
        local originalValues = readSliderValues()

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
        local written = {}
        local copiedOk, copiedCount = LrTasks.pcall(copyAdjustments, originalValues, copyId, written)
        if not copiedOk then
            local moved = #written > 0 and not MaskSelection.isSelected(copyId)
            local failure = string.format("Lightroom does not copy the local adjustments to an inverted copy and"
                .. " they could not be copied (%s)", Reply.messageOf(copiedCount))
            local problem = MaskSelection.problemUnlessAddedRemoved(catalog, photo, idsBefore, "the copy " .. copyId)
            if problem then error(failure .. "; " .. problem, 0) end
            if moved then
                error(failure .. "; the copy was removed, but written before the move: " .. table.concat(written, ", ")
                    .. "; read the masks with list_masks before retrying", 0)
            end
            if sourceChange then
                error(failure .. "; the copy was removed, but " .. sourceChange .. ": read the masks with list_masks"
                    .. " before retrying", 0)
            end
            Reply.refuse(failure .. "; the copy was removed")
        end
        if copiedCount > 0 then
            DevelopSession.flushPendingEdits()
            LrTasks.sleep(COPY_PERSIST_SETTLE_SECONDS)
        end

        local copy = MaskSelection.findMask(MaskSelection.readMasksOrNil(), copyId)
        return {
            mode = MODE_COPY,
            source_mask_id = maskId,
            mask_id = copyId,
            adjustments_copied = copiedCount,
            not_copied = NOT_COPIED,
            mask = copy and describeMask(copy) or nil,
        }
    end)
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
