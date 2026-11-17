local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskSelection = require 'MaskSelection'
local MaskTypes = require 'MaskTypes'
local Reply = require 'Reply'

local MaskCombineHandler = {}

local SDK_FUNCTION_OF_OPERATION = {
    add = "addToCurrentMask",
    subtract = "subtractFromCurrentMask",
    intersect = "intersectWithCurrentMask",
}
local VERB_OF_OPERATION = {
    add = "add to",
    subtract = "subtract from",
    intersect = "intersect with",
}

local COMPONENT_DETECTION_TIMEOUT_SECONDS = 30
local COMPONENT_STABLE_POLLS = 10

local function toolIdSet(mask)
    local ids = {}
    for _, tool in ipairs(MaskSelection.toolsOf(mask)) do
        local id = type(tool) == "table" and MaskSelection.idString(tool.ID)
        if id then ids[id] = true end
    end
    return ids
end

local function toolsNotIn(mask, knownToolIds)
    local fresh = {}
    for _, tool in ipairs(MaskSelection.toolsOf(mask)) do
        local id = type(tool) == "table" and MaskSelection.idString(tool.ID)
        if id and not knownToolIds[id] then fresh[#fresh + 1] = tool end
    end
    return fresh
end

local function awaitNewComponents(maskId, knownToolIds)
    local fresh, stablePolls, lastCount = {}, 0, 0
    local settled = DevelopSession.waitFor(function()
        local target = MaskSelection.findMask(MaskSelection.readMasksOrNil(), maskId)
        fresh = target and toolsNotIn(target, knownToolIds) or {}
        if #fresh > 0 and #fresh == lastCount then
            stablePolls = stablePolls + 1
        else
            stablePolls = 0
        end
        lastCount = #fresh
        return stablePolls >= COMPONENT_STABLE_POLLS
    end, COMPONENT_DETECTION_TIMEOUT_SECONDS)
    if not settled then return nil end
    return fresh
end

local function raiseNothingFound(catalog, photo, nothingFound, before)
    local masks = MaskSelection.readMasksOrNil()
    local maskId, photoId = nothingFound.maskId, nothingFound.photoId
    if masks and MaskSelection.fingerprint(masks) == before.masks then
        if MaskSelection.holdsSavedMasks(catalog, photo, masks) then
            Reply.refuse(nothingFound.message .. "; mask " .. maskId .. " is unchanged")
        end
        error(string.format("%s; Develop lists fewer masks than photo %s's saved settings hold, so whether mask %s"
            .. " changed is unknown: check mask %s with list_masks afterwards", nothingFound.message, photoId, maskId,
            maskId), 0)
    end
    local target = masks and MaskSelection.findMask(masks, maskId)
    if target and MaskSelection.fingerprint(target) ~= before.target then
        error(string.format("Lightroom changed mask %s on photo %s without adding a %s component (%s)",
            maskId, photoId, nothingFound.typeName, nothingFound.operation), 0)
    end
    if target then
        error(nothingFound.message .. "; Lightroom changed the photo's other masks, so check the masks with list_masks"
            .. " afterwards", 0)
    end
    error(nothingFound.message .. "; Lightroom lists no masks while the alert is open, so check mask " .. maskId
        .. " with list_masks afterwards", 0)
end

local function combineComponent(catalog, photo, photoId, maskId, operation, typeName, spec)
    local previousTool = MaskSelection.openMaskingTool()
    local ok, outcome = LrTasks.pcall(MaskSelection.withMaskSelected, catalog, photo, maskId, function(masks)
        local target = MaskSelection.findMask(masks, maskId)
        local knownToolIds = toolIdSet(target)
        local before = { masks = MaskSelection.fingerprint(masks), target = MaskSelection.fingerprint(target) }
        local functionName = SDK_FUNCTION_OF_OPERATION[operation]
        local called, callError = LrTasks.pcall(LrDevelopController[functionName], spec.toolType, spec.subtype)
        if not called then
            error("Lightroom could not run " .. functionName .. " on mask " .. maskId .. ": " .. tostring(callError), 0)
        end
        local fresh = awaitNewComponents(maskId, knownToolIds)
        if not fresh then
            raiseNothingFound(catalog, photo, {
                maskId = maskId,
                photoId = photoId,
                typeName = typeName,
                operation = operation,
                message = string.format("Lightroom found no %s to %s mask %s on photo %s; Lightroom shows an alert"
                    .. " such as \"No %s detected\" for this, so click OK in Lightroom before the next Develop call",
                    typeName, VERB_OF_OPERATION[operation], maskId, photoId, typeName),
            }, before)
        end
        if #fresh > 1 then
            error(string.format("Lightroom added %d components to mask %s on photo %s while one %s component"
                .. " was expected; check the mask with list_masks", #fresh, maskId, photoId, typeName), 0)
        end
        return fresh[1]
    end)

    MaskSelection.restoreTool(previousTool)
    if not ok then error(outcome, 0) end

    return outcome, MaskSelection.findMask(MaskSelection.readMasksOrNil(), maskId)
end

function MaskCombineHandler.combineMask(args, context)
    local maskId = args.mask_id
    local operation = args.operation
    local typeName, spec = args.type, MaskTypes.SPECS[args.type]
    MaskSelection.requireControllerFunctions("combine_mask",
        { "selectTool", "getSelectedMask", SDK_FUNCTION_OF_OPERATION[operation] }, "Lightroom Classic 11")

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)

    local result = DevelopSession.withPhoto(context, catalog, photo, function()
        local component, after = combineComponent(catalog, photo, photoId, maskId, operation, typeName, spec)
        return { component = component, mask = after }
    end)

    local component = MaskSelection.normalizeTool(result.component, photoId)
    Log.info(string.format("Combined mask %s on photo %s (%s %s) -> component %s",
        maskId, photoId, operation, typeName, tostring(component.id)))

    local response = {
        photo_id = photoId,
        mask_id = maskId,
        operation = operation,
        type = typeName,
        tool_id = component.id,
        tool = component,
    }
    if result.mask then
        response.mask = MaskSelection.normalizeMask(result.mask, photoId)
    end
    return response
end

return MaskCombineHandler
