local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local CatalogWrite = require 'CatalogWrite'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskSelection = require 'MaskSelection'
local Reply = require 'Reply'
local PhotoLookup = require 'PhotoLookup'

local MaskDeleteHandler = {}

local DELETION_SETTLE_TIMEOUT_SECONDS = 5
local SAVE_SETTLE_TIMEOUT_SECONDS = 5
local DELETE_API_FUNCTIONS = { "deleteMask", "deleteMaskTool", "selectTool" }
local DELETE_API_MINIMUM_VERSION = "Lightroom Classic 11"
local DELETE_EMPTY_MINIMUM_VERSION = "Lightroom Classic 14"

local function uniqueIds(values)
    local ids, seen = {}, {}
    for _, id in ipairs(values) do
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

local function parseTarget(args)
    if args.all then return { kind = "all" } end
    local kind = args.mask_ids ~= nil and "mask_ids" or "tool_ids"
    return { kind = kind, ids = uniqueIds(args[kind]) }
end

local function snapshotFromRaw(raw, photoId)
    local snapshot = { masksById = {}, maskOrder = {}, maskIdOfTool = {}, count = 0 }
    for _, mask in ipairs(raw) do
        local maskId = type(mask) == "table" and MaskSelection.idString(mask.ID)
        if not maskId then
            Reply.refuse("Lightroom returned a mask without an id for photo " .. photoId .. "; nothing was changed")
        end
        local toolIds = {}
        if type(mask.Tools) == "table" then
            for _, tool in ipairs(mask.Tools) do
                local toolId = type(tool) == "table" and MaskSelection.idString(tool.ID)
                if not toolId then
                    Reply.refuse("Lightroom returned a mask tool without an id for photo " .. photoId .. "; nothing was changed")
                end
                toolIds[#toolIds + 1] = toolId
                snapshot.maskIdOfTool[toolId] = maskId
            end
        end
        snapshot.masksById[maskId] = { id = maskId, toolIds = toolIds }
        snapshot.maskOrder[#snapshot.maskOrder + 1] = maskId
        snapshot.count = snapshot.count + 1
    end
    return snapshot
end

local function tryReadMaskSnapshot(photoId)
    local ok, snapshot = LrTasks.pcall(function()
        return snapshotFromRaw(LrDevelopController.getAllMasks() or {}, photoId)
    end)
    if ok then return snapshot end
    return nil
end

local function readSavedMasks(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    local saved = { maskIds = {}, toolIds = {}, groupCount = 0 }
    local groups = type(settings) == "table" and settings.MaskGroupBasedCorrections
    if type(groups) ~= "table" then return saved end
    for _, group in ipairs(groups) do
        saved.groupCount = saved.groupCount + 1
        if type(group) == "table" then
            if group.CorrectionID ~= nil then saved.maskIds[group.CorrectionID] = true end
            if type(group.CorrectionMasks) == "table" then
                for _, tool in ipairs(group.CorrectionMasks) do
                    if type(tool) == "table" and tool.MaskID ~= nil then
                        saved.toolIds[tool.MaskID] = true
                    end
                end
            end
        end
    end
    return saved
end

local function listUnknown(ids, isKnown)
    local unknown = {}
    for _, id in ipairs(ids) do
        if not isKnown(id) then unknown[#unknown + 1] = id end
    end
    return unknown
end

local function planDeletion(snapshot, target, photoId)
    local plan = { maskIds = {}, toolsByMask = {}, removedMaskIds = {}, removedToolIds = {} }

    if target.kind == "all" or target.kind == "mask_ids" then
        local maskIds = target.ids or snapshot.maskOrder
        local unknown = listUnknown(maskIds, function(id) return snapshot.masksById[id] ~= nil end)
        if #unknown > 0 then
            Reply.refuse("Unknown mask id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
                .. "; nothing was deleted")
        end
        for _, maskId in ipairs(maskIds) do
            plan.maskIds[#plan.maskIds + 1] = maskId
            plan.removedMaskIds[#plan.removedMaskIds + 1] = maskId
            for _, toolId in ipairs(snapshot.masksById[maskId].toolIds) do
                plan.removedToolIds[#plan.removedToolIds + 1] = toolId
            end
        end
        return plan
    end

    local unknown = listUnknown(target.ids, function(id) return snapshot.maskIdOfTool[id] ~= nil end)
    if #unknown > 0 then
        Reply.refuse("Unknown tool id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
            .. "; nothing was deleted")
    end
    local requestedToolIds = {}
    for _, toolId in ipairs(target.ids) do requestedToolIds[toolId] = true end
    for _, maskId in ipairs(snapshot.maskOrder) do
        local toolIds, remaining = {}, 0
        for _, toolId in ipairs(snapshot.masksById[maskId].toolIds) do
            if requestedToolIds[toolId] then
                toolIds[#toolIds + 1] = toolId
            else
                remaining = remaining + 1
            end
        end
        if #toolIds > 0 then
            plan.toolsByMask[#plan.toolsByMask + 1] = { maskId = maskId, toolIds = toolIds }
            for _, toolId in ipairs(toolIds) do
                plan.removedToolIds[#plan.removedToolIds + 1] = toolId
            end
            if remaining == 0 then
                plan.removedMaskIds[#plan.removedMaskIds + 1] = maskId
            end
        end
    end
    return plan
end

local function attempt(description, fn)
    local ok, err = LrTasks.pcall(fn)
    if not ok then
        error("Lightroom could not " .. description .. ": " .. tostring(err), 0)
    end
end

local function issueDeletions(plan)
    for _, maskId in ipairs(plan.maskIds) do
        attempt("delete mask " .. maskId, function()
            LrDevelopController.selectMask(maskId)
            LrDevelopController.deleteMask(maskId)
        end)
    end
    for _, entry in ipairs(plan.toolsByMask) do
        attempt("select mask " .. entry.maskId, function()
            LrDevelopController.selectMask(entry.maskId)
        end)
        for _, toolId in ipairs(entry.toolIds) do
            attempt("delete mask tool " .. toolId, function()
                LrDevelopController.deleteMaskTool(toolId)
            end)
        end
    end
end

local function deletionIsVisible(snapshot, plan)
    for _, maskId in ipairs(plan.removedMaskIds) do
        if snapshot.masksById[maskId] ~= nil then return false end
    end
    for _, toolId in ipairs(plan.removedToolIds) do
        if snapshot.maskIdOfTool[toolId] ~= nil then return false end
    end
    return true
end

local function deleteEmptiedMasksLeftBehind(snapshot, plan, alreadyDeleted)
    for _, maskId in ipairs(plan.removedMaskIds) do
        local mask = snapshot.masksById[maskId]
        if mask and #mask.toolIds == 0 and not alreadyDeleted[maskId] then
            alreadyDeleted[maskId] = true
            LrTasks.pcall(function()
                LrDevelopController.selectMask(maskId)
                LrDevelopController.deleteMask(maskId)
            end)
        end
    end
end

local function waitUntilDeletionIsVisible(photoId, plan)
    local emptiedMasksAlreadyDeleted = {}
    local latest
    local visible = DevelopSession.waitFor(function()
        latest = tryReadMaskSnapshot(photoId)
        if not latest then return false end
        deleteEmptiedMasksLeftBehind(latest, plan, emptiedMasksAlreadyDeleted)
        return deletionIsVisible(latest, plan)
    end, DELETION_SETTLE_TIMEOUT_SECONDS)
    if not visible then
        error("Lightroom did not remove the requested masks from photo " .. photoId
            .. " in Develop; the photo may be partly changed, so list_masks to check")
    end
    return latest
end

local function savedDeletionMatches(saved, plan)
    for _, maskId in ipairs(plan.removedMaskIds) do
        if saved.maskIds[maskId] then return false end
    end
    for _, toolId in ipairs(plan.removedToolIds) do
        if saved.toolIds[toolId] then return false end
    end
    return true
end

local function waitUntilDeletionIsSaved(catalog, photo, photoId, plan)
    local saved = DevelopSession.waitFor(function()
        return savedDeletionMatches(readSavedMasks(catalog, photo), plan)
    end, SAVE_SETTLE_TIMEOUT_SECONDS)
    if not saved then
        error("Lightroom showed the deletion in Develop but did not save it for photo " .. photoId
            .. "; list_masks to check, then call again")
    end
end

local function deletePhotoMasks(args, context)
    local target = parseTarget(args)
    MaskSelection.requireControllerFunctions("delete_masks", DELETE_API_FUNCTIONS, DELETE_API_MINIMUM_VERSION)

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)

    local plan, remainingCount
    DevelopSession.withPhoto(context, catalog, photo, function()
        local previousTool = MaskSelection.openMaskingTool()
        local ok, err = LrTasks.pcall(function()
            local snapshot = snapshotFromRaw(MaskSelection.readMasks(catalog, photo), photoId)
            plan = planDeletion(snapshot, target, photoId)
            if #plan.removedMaskIds == 0 and #plan.removedToolIds == 0 then return end
            issueDeletions(plan)
            remainingCount = waitUntilDeletionIsVisible(photoId, plan).count
        end)
        MaskSelection.restoreTool(previousTool)
        if not ok then error(err, 0) end
    end)

    if remainingCount == nil then
        remainingCount = 0
    else
        waitUntilDeletionIsSaved(catalog, photo, photoId, plan)
    end

    Log.info(string.format("Deleted %d masks and %d mask tools from photo %s",
        #plan.removedMaskIds, #plan.removedToolIds, photoId))

    return {
        photo_id = photoId,
        deleted_mask_ids = plan.removedMaskIds,
        deleted_tool_ids = plan.removedToolIds,
        remaining_mask_count = remainingCount,
    }
end

local function countGroups(catalog, photos)
    local counts = {}
    for _, photo in ipairs(photos) do
        counts[photo] = readSavedMasks(catalog, photo).groupCount
    end
    return counts
end

function MaskDeleteHandler.deleteEmptyMasks(args)
    local catalog = LrApplication.activeCatalog()
    if type(catalog.deleteAllEmptyMasks) ~= "function" then
        Reply.refuse("delete_empty_masks needs " .. DELETE_EMPTY_MINIMUM_VERSION .. " or later")
    end

    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    local photos = {}
    for i, entry in ipairs(entries) do photos[i] = entry.photo end

    local groupsBefore = countGroups(catalog, photos)
    CatalogWrite.run(catalog, "Delete Empty Masks", function()
        catalog:deleteAllEmptyMasks(photos)
    end)
    local groupsAfter = countGroups(catalog, photos)
    local changed = {}
    for _, photo in ipairs(photos) do
        local removed = groupsBefore[photo] - groupsAfter[photo]
        if removed > 0 then
            changed[#changed + 1] = { photo_id = tostring(photo.localIdentifier), masks_removed = removed }
        end
    end

    Log.info(string.format("Deleted empty masks: %d of %d photos changed (%d ids not found)",
        #changed, #photos, #notFound))

    return Reply.parts({ data = { photos_checked = #photos, changed = changed }, not_found = notFound })
end

function MaskDeleteHandler.deleteMasks(args, context)
    return deletePhotoMasks(args, context)
end

return MaskDeleteHandler
