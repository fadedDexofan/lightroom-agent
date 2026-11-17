local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local Contract = require 'Contract'
local CatalogWrite = require 'CatalogWrite'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local Reply = require 'Reply'

local AIMaskCompute = {}

local MINIMUM_VERSION = "Lightroom Classic 13.3"

function AIMaskCompute.requireSupported(toolName, photo)
    if type(photo.updateAISettings) ~= "function" then
        Reply.refuse(toolName .. " needs " .. MINIMUM_VERSION .. " or later")
    end
end

-- applyDevelopSettings has no AI flag and the applyDevelopPreset one reportedly
-- reopens the modal-dialog lockup, so recompute in a second write transaction
-- (same-transaction calls do not see the new settings).
local function updateAISettings(catalog, photo)
    local entered, raised = false, nil
    local _, gateError = LrTasks.pcall(CatalogWrite.run, catalog, "Update AI Settings", function()
        entered = true
        local ok, err = LrTasks.pcall(function() photo:updateAISettings() end)
        if not ok then raised = err end
    end)
    if not entered then return { error = gateError } end
    return { entered = true, error = raised }
end

local function entriesById(entries)
    local byId = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and entry.CorrectionID ~= nil then byId[tostring(entry.CorrectionID)] = entry end
    end
    return byId
end

local POLL_SECONDS = 0.1

local function idOf(entry)
    return type(entry) == "table" and entry.CorrectionID ~= nil and tostring(entry.CorrectionID) or nil
end

local function errorReasonOf(entry)
    for _, component in ipairs(type(entry.CorrectionMasks) == "table" and entry.CorrectionMasks or {}) do
        if type(component) == "table" and type(component.ErrorReason) == "number" and component.ErrorReason ~= 0 then
            return component.ErrorReason
        end
    end
    return nil
end

local function anyPending(entries)
    for _, entry in ipairs(entries) do
        if AIMaskData.uncomputed(entry) then return true end
    end
    return false
end

local function settled(catalog, photo)
    local entries = GuardedMaskWrite.readEntries(catalog, photo)
    local waited = 0
    while anyPending(entries) and waited < Contract.AI_MASK_COMPUTE_WAIT_SECONDS do
        LrTasks.sleep(POLL_SECONDS)
        waited = waited + POLL_SECONDS
        entries = GuardedMaskWrite.readEntries(catalog, photo)
    end
    return entries, anyPending(entries)
end

local function restoreAndRefuse(catalog, photo, previous, reason)
    local restored, restoreError = LrTasks.pcall(GuardedMaskWrite.apply, catalog, photo, {
        description = "Remove AI masks",
        build = function() return GuardedMaskWrite.deepClone(previous) end,
    })
    if not restored then
        error(reason .. "; the new masks could not be removed, check the photo's masks in Develop: "
            .. Reply.messageOf(restoreError), 0)
    end
    Reply.refuse(reason .. "; the new masks were removed")
end

local function namesOf(entries)
    local names = {}
    for _, entry in ipairs(entries) do
        names[#names + 1] = entry.CorrectionName or (idOf(entry) and "mask " .. idOf(entry)) or "an unnamed mask"
    end
    return table.concat(names, ", ")
end

local function aiComponentsById(entry)
    local byId = {}
    for index, component in ipairs(type(entry) == "table" and type(entry.CorrectionMasks) == "table" and entry.CorrectionMasks or {}) do
        if type(component) == "table" and component.What == AIMaskData.KIND then
            byId[component.MaskID ~= nil and tostring(component.MaskID) or ("#" .. index)] = component
        end
    end
    return byId
end

local function changedByRecompute(previous, entry)
    local now = aiComponentsById(entry)
    for maskId, held in pairs(aiComponentsById(previous)) do
        local component = now[maskId]
        if AIMaskData.componentState(held) == "computed" and component ~= nil
            and (AIMaskData.componentState(component) == "failed"
                or component[AIMaskData.COMPUTATION_MARKER_KEY] ~= held[AIMaskData.COMPUTATION_MARKER_KEY]) then
            return true
        end
    end
    return false
end

local function warnAboutExisting(context, photoId, before, after)
    local beforeById = entriesById(before)
    for _, entry in ipairs(before) do
        local reason = AIMaskData.computeState(entry) == "failed" and errorReasonOf(entry)
        if reason then
            context:warn(string.format("Photo %s: mask %s was already failed (ErrorReason %s) before this call",
                photoId, idOf(entry), tostring(reason)))
        end
    end
    for _, entry in ipairs(after) do
        local previous = beforeById[idOf(entry) or ""]
        if previous and changedByRecompute(previous, entry) then
            context:warn(string.format("Photo %s: Lightroom's photo-wide AI recompute changed mask %s; check it",
                photoId, idOf(entry)))
        end
    end
end

local function ownOf(spec, existing, after)
    local own, components = {}, {}
    if spec.target then
        local _, held = GuardedMaskWrite.findCorrection(existing, spec.target)
        local _, entry = GuardedMaskWrite.findCorrection(after, spec.target)
        local known = aiComponentsById(held)
        if entry then
            own[1] = entry
            for maskId, component in pairs(aiComponentsById(entry)) do
                if known[maskId] == nil then components[#components + 1] = component end
            end
        end
        return own, components
    end
    local beforeById = entriesById(existing)
    for _, entry in ipairs(after) do
        if beforeById[idOf(entry) or ""] == nil then
            own[#own + 1] = entry
            for _, component in pairs(aiComponentsById(entry)) do components[#components + 1] = component end
        end
    end
    return own, components
end

local function failedEntries(own)
    local failed = {}
    for _, entry in ipairs(own) do
        if AIMaskData.computeState(entry) == "failed" then failed[#failed + 1] = entry end
    end
    return failed
end

function AIMaskCompute.run(context, catalog, photo, spec)
    local photoId = tostring(photo.localIdentifier)
    local previous = spec.before
    if spec.build then
        previous = GuardedMaskWrite.apply(catalog, photo, { description = spec.description, build = spec.build }).previous
    end
    local function fail(reason)
        if spec.build then restoreAndRefuse(catalog, photo, previous, reason) end
        error(reason, 0)
    end
    local compute = updateAISettings(catalog, photo)
    local computeError = compute.error
        and "Lightroom could not compute " .. spec.subject .. ": " .. Reply.messageOf(compute.error)
    if not compute.entered then fail(computeError) end
    local after, pending = settled(catalog, photo)
    if pending then
        error(string.format("%sLightroom has not finished computing the AI masks of photo %s within %d s, so nothing more"
            .. " was written to it. Do not write to this photo until its masks show in Develop: a write while"
            .. " Lightroom still computes can freeze Lightroom.", computeError and computeError .. "; " or "", photoId,
            Contract.AI_MASK_COMPUTE_WAIT_SECONDS), 0)
    end
    if computeError then
        context:warn(string.format("Photo %s: %s; nothing on the photo was still computing afterwards, so the call judged"
            .. " the photo as it stands", photoId, computeError))
    end
    local existing = spec.replaces and {} or previous
    local own, components = ownOf(spec, existing, after)
    local kept = spec.target and #components or #own
    if spec.expected and kept ~= spec.expected then
        fail(string.format("Lightroom kept %d of the %d requested masks on photo %s", kept, spec.expected, photoId))
    end
    local failedOwn = {}
    for _, component in ipairs(components) do
        if AIMaskData.componentState(component) == "failed" then failedOwn[#failedOwn + 1] = component end
    end
    if #failedOwn > 0 then
        local reason = spec.failure and spec.failure(own)
            or string.format("Lightroom could not compute %s on photo %s", namesOf(failedEntries(own)), photoId)
        fail(reason)
    end
    warnAboutExisting(context, photoId, existing, after)
    return { own = own, components = components, previous = previous }
end

return AIMaskCompute
