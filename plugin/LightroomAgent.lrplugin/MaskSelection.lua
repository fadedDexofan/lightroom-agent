local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local CatalogWrite = require 'CatalogWrite'
local Reply = require 'Reply'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'

local MaskSelection = {}

local MASK_LIST_TIMEOUT_SECONDS = 5
local MASK_SELECT_TIMEOUT_SECONDS = 8
local MASK_SELECT_SETTLE_SECONDS = 0.3

local TOOL_SWITCH_TIMEOUT_SECONDS = 5
local MASKING_TOOL = "masking"
local MASKING_TOOL_NAMES = { masking = true, local_point_color = true }

function MaskSelection.findMask(masks, maskId)
    for _, mask in ipairs(masks or {}) do
        if mask.ID == maskId then return mask end
    end
    return nil
end

local function savedMaskCount(catalog, photo)
    return #GuardedMaskWrite.readEntries(catalog, photo)
end

local function holdsSavedMasks(catalog, photo, masks)
    return #masks >= savedMaskCount(catalog, photo)
end

function MaskSelection.readMasks(catalog, photo)
    local photoId = tostring(photo.localIdentifier)
    local masks, lastError
    local ready = DevelopSession.waitFor(function()
        local ok, result = LrTasks.pcall(LrDevelopController.getAllMasks)
        if not ok then
            masks, lastError = nil, result
            return false
        end
        masks = result or {}
        return holdsSavedMasks(catalog, photo, masks)
    end, MASK_LIST_TIMEOUT_SECONDS)
    if ready then return masks end
    if masks == nil then
        Reply.refuse(string.format("Lightroom could not read the masks of photo %s: %s",
            photoId, Reply.messageOf(lastError)))
    end
    Reply.refuse(string.format("Develop lists %d of the %d masks in photo %s's saved settings; Develop has not"
        .. " loaded them yet or an alert such as \"No sky detected\" is open: click OK in Lightroom if one is open,"
        .. " then call again", #masks, savedMaskCount(catalog, photo), photoId))
end

function MaskSelection.readMasksOrNil()
    local ok, result = LrTasks.pcall(LrDevelopController.getAllMasks)
    if not ok then return nil end
    return result or {}
end

function MaskSelection.idSet(masks)
    local ids = {}
    for _, mask in ipairs(masks) do
        ids[mask.ID] = true
    end
    return ids
end

function MaskSelection.masksNotIn(masks, knownIds)
    local fresh = {}
    for _, mask in ipairs(masks) do
        if not knownIds[mask.ID] then fresh[#fresh + 1] = mask end
    end
    return fresh
end

local function idsOf(masks)
    local ids = {}
    for _, mask in ipairs(masks) do ids[#ids + 1] = tostring(mask.ID) end
    return ids
end

local function readMasksListingAll(knownIds)
    local masks = MaskSelection.readMasksOrNil()
    if not masks then return nil end
    local listed = MaskSelection.idSet(masks)
    for id in pairs(knownIds) do
        if not listed[id] then return nil end
    end
    return masks
end

function MaskSelection.problemUnlessAddedRemoved(context, catalog, photo, knownIds, subject)
    local masks
    local listed = DevelopSession.waitFor(function()
        masks = readMasksListingAll(knownIds)
        return masks ~= nil and holdsSavedMasks(catalog, photo, masks)
    end, MASK_LIST_TIMEOUT_SECONDS)
    local leftovers
    if listed then
        for _, mask in ipairs(MaskSelection.masksNotIn(masks, knownIds)) do
            LrTasks.pcall(CatalogWrite.develop, context, "deleteMask", mask.ID)
        end
        DevelopSession.waitFor(function()
            local after = readMasksListingAll(knownIds)
            leftovers = after and idsOf(MaskSelection.masksNotIn(after, knownIds)) or nil
            return leftovers ~= nil and #leftovers == 0
        end, MASK_LIST_TIMEOUT_SECONDS)
    end
    if leftovers == nil then
        return "Lightroom's mask list could not be read or did not list every mask on the photo, so " .. subject
            .. " may still be on the photo: call list_masks before retrying"
    end
    if #leftovers > 0 then
        return "could not remove " .. subject .. " (still listed: " .. table.concat(leftovers, ", ")
            .. "): call list_masks before retrying"
    end
    return nil
end

function MaskSelection.requireMask(masks, maskId, photoId)
    local mask = MaskSelection.findMask(masks, maskId)
    if mask then return mask end
    local ids = {}
    for _, listed in ipairs(masks) do ids[#ids + 1] = listed.ID end
    Reply.refuse(string.format("Mask not found on photo %s: %s (masks on this photo: %s)",
        photoId, tostring(maskId), #ids > 0 and table.concat(ids, ", ") or "none"))
end

local function readSelectedMask()
    local ok, id = LrTasks.pcall(LrDevelopController.getSelectedMask)
    if ok and type(id) == "string" and id ~= "" then return id end
    return nil
end

local function isSelected(maskId)
    return readSelectedMask() == maskId
end

function MaskSelection.selectableTool(tool)
    if MASKING_TOOL_NAMES[tool] then return MASKING_TOOL end
    return tool
end

local function selectedTool()
    local ok, tool = LrTasks.pcall(LrDevelopController.getSelectedTool)
    if ok and type(tool) == "string" then return MaskSelection.selectableTool(tool) end
    return nil
end

function MaskSelection.openMaskingTool()
    local previousTool = selectedTool()
    if previousTool == MASKING_TOOL then return previousTool end
    LrDevelopController.selectTool(MASKING_TOOL)
    if previousTool ~= nil then
        local opened = DevelopSession.waitFor(function()
            return selectedTool() == MASKING_TOOL
        end, TOOL_SWITCH_TIMEOUT_SECONDS)
        if not opened then
            LrTasks.pcall(LrDevelopController.selectTool, previousTool)
            Reply.refuse("Lightroom did not open the masking tool")
        end
    end
    return previousTool
end

function MaskSelection.restoreTool(previousTool)
    if previousTool == nil or previousTool == MASKING_TOOL then return end
    LrTasks.pcall(LrDevelopController.selectTool, previousTool)
end

local function openMaskingPanel()
    LrTasks.pcall(LrDevelopController.goToMasking)
end

local function selectMaskAndWait(maskId)
    return DevelopSession.retryUntil(function() return isSelected(maskId) end,
        function() LrTasks.pcall(LrDevelopController.selectMask, maskId) end, MASK_SELECT_TIMEOUT_SECONDS)
end

function MaskSelection.keepingSelection(body)
    local previousMask = readSelectedMask()
    local ok, result = LrTasks.pcall(body)
    if previousMask and readSelectedMask() ~= previousMask then
        LrTasks.pcall(LrDevelopController.selectMask, previousMask)
    end
    if not ok then error(result, 0) end
    return result
end

function MaskSelection.withMaskSelected(catalog, photo, maskId, body)
    local photoId = tostring(photo.localIdentifier)
    local masks = MaskSelection.readMasks(catalog, photo)
    MaskSelection.requireMask(masks, maskId, photoId)
    openMaskingPanel()
    return MaskSelection.keepingSelection(function()
        if not selectMaskAndWait(maskId) then
            Reply.refuse("Could not select mask " .. maskId .. " on photo " .. photoId .. " in Develop")
        end
        LrTasks.sleep(MASK_SELECT_SETTLE_SECONDS)
        local result = body(masks)
        local selected = readSelectedMask()
        if selected ~= maskId then
            Reply.refuse(string.format("%s became selected in Develop while mask %s was read on photo %s; call again"
                .. " without changing the selection", selected and "Mask " .. selected or "No mask", maskId, photoId))
        end
        return result
    end)
end

return MaskSelection
