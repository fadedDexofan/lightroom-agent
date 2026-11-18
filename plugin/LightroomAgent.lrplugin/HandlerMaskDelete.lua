local LrApplication = import 'LrApplication'

local CatalogWrite = require 'CatalogWrite'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local JsonValue = require 'JsonValue'
local Log = require 'Log'
local Reply = require 'Reply'
local PhotoLookup = require 'PhotoLookup'

local MaskDeleteHandler = {}


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

local function listUnknown(ids, isKnown)
    local unknown = {}
    for _, id in ipairs(ids) do
        if not isKnown(id) then unknown[#unknown + 1] = id end
    end
    return unknown
end

local function componentsOf(entry)
    return type(entry) == "table" and type(entry.CorrectionMasks) == "table" and entry.CorrectionMasks or {}
end

local function idOf(value)
    return value ~= nil and tostring(value) or nil
end

local function planDeletion(entries, target, photoId)
    local maskIds, toolIds = {}, {}
    for _, entry in ipairs(entries) do
        if idOf(entry.CorrectionID) then maskIds[idOf(entry.CorrectionID)] = true end
        for _, component in ipairs(componentsOf(entry)) do
            if idOf(component.MaskID) then toolIds[idOf(component.MaskID)] = true end
        end
    end
    local removeMask, removeTool = {}, {}
    if target.kind == "mask_ids" then
        local unknown = listUnknown(target.ids, function(id) return maskIds[id] end)
        if #unknown > 0 then
            Reply.refuse("Unknown mask id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
                .. "; nothing was deleted")
        end
        for _, id in ipairs(target.ids) do removeMask[id] = true end
    elseif target.kind == "tool_ids" then
        local unknown = listUnknown(target.ids, function(id) return toolIds[id] end)
        if #unknown > 0 then
            Reply.refuse("Unknown tool id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
                .. "; nothing was deleted")
        end
        for _, id in ipairs(target.ids) do removeTool[id] = true end
    end
    local plan = { kept = {}, deletedMaskIds = {}, deletedToolIds = {}, removed = 0 }
    for _, entry in ipairs(entries) do
        local maskId = idOf(entry.CorrectionID)
        local survivors, removed, dropped = {}, {}, 0
        for _, component in ipairs(componentsOf(entry)) do
            local toolId = idOf(component.MaskID)
            if target.kind == "all" or removeMask[maskId] or removeTool[toolId] then
                dropped = dropped + 1
                removed[#removed + 1] = toolId
            else
                survivors[#survivors + 1] = component
            end
        end
        for _, toolId in ipairs(removed) do plan.deletedToolIds[#plan.deletedToolIds + 1] = toolId end
        plan.removed = plan.removed + dropped
        if target.kind == "all" or removeMask[maskId] or (dropped > 0 and #survivors == 0) then
            plan.removed = plan.removed + 1
            plan.deletedMaskIds[#plan.deletedMaskIds + 1] = maskId
        else
            if dropped > 0 then entry.CorrectionMasks = survivors end
            plan.kept[#plan.kept + 1] = entry
        end
    end
    return plan
end

local function nothingDeleted(plan)
    return plan.removed == 0
end

function MaskDeleteHandler.deleteMasks(args, context)
    local target = parseTarget(args)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local plan
    local submitted = GuardedMaskWrite.submit(context, catalog, photo, {
        description = "Delete Masks",
        unchanged = function(entries) return nothingDeleted(planDeletion(entries, target, photoId)) end,
        build = function(entries)
            plan = planDeletion(entries, target, photoId)
            if nothingDeleted(plan) then return nil end
            return plan.kept
        end,
        mismatches = JsonValue.differences,
    })
    plan = plan or { deletedMaskIds = {}, deletedToolIds = {} }

    Log.info(string.format("Deleted %d masks and %d mask tools from photo %s",
        #plan.deletedMaskIds, #plan.deletedToolIds, photoId))

    return {
        photo_id = photoId,
        deleted_mask_ids = plan.deletedMaskIds,
        deleted_tool_ids = plan.deletedToolIds,
        remaining_mask_count = #submitted.entries,
    }
end

local function countGroups(catalog, photos)
    local counts = {}
    for _, photo in ipairs(photos) do
        counts[photo] = #GuardedMaskWrite.readEntries(catalog, photo)
    end
    return counts
end

function MaskDeleteHandler.deleteEmptyMasks(args, context)
    local catalog = LrApplication.activeCatalog()

    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    local photos = {}
    for i, entry in ipairs(entries) do photos[i] = entry.photo end

    local groupsBefore = countGroups(catalog, photos)
    CatalogWrite.run(context, catalog, "Delete Empty Masks", function()
        CatalogWrite.call(context, catalog, "deleteAllEmptyMasks", photos)
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

return MaskDeleteHandler
