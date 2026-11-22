local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local Contract = require 'Contract'
local CatalogWrite = require 'CatalogWrite'
local DevelopReadBack = require 'DevelopReadBack'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local JsonValue = require 'JsonValue'
local Reply = require 'Reply'

local AIMaskCompute = {}

-- applyDevelopSettings has no AI flag and the applyDevelopPreset one reportedly
-- reopens the modal-dialog lockup, so recompute in a second write transaction
-- (same-transaction calls do not see the new settings).
local function updateAISettings(context, catalog, photo)
    local entered, raised = false, nil
    local _, gateError = LrTasks.pcall(CatalogWrite.run, context, catalog, "Update AI Settings", function()
        entered = true
        local ok, err = LrTasks.pcall(CatalogWrite.call, context, photo, "updateAISettings")
        if not ok then raised = err end
    end)
    if not entered then return { error = gateError } end
    return { entered = true, error = raised }
end

local function entriesById(entries)
    local byId = {}
    for _, entry in ipairs(entries) do
        if entry.CorrectionID ~= nil then byId[tostring(entry.CorrectionID)] = entry end
    end
    return byId
end

local POLL_SECONDS = 0.1

local function idOf(entry)
    return entry.CorrectionID ~= nil and tostring(entry.CorrectionID) or nil
end

local function errorReasonOf(entry)
    for _, component in ipairs(entry.CorrectionMasks or {}) do
        if (component.ErrorReason or 0) ~= 0 then
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

local MAX_NAMED_KEYS = 10

local function keysOutsideMasksChangedSince(catalog, photo, settings)
    local now
    catalog:withReadAccessDo(function() now = DevelopReadBack.saved(photo) end)
    local seen, keys = {}, {}
    for _, path in ipairs(JsonValue.differences(settings or {}, now)) do
        local key = path:match("^[^.]+")
        if key ~= "MaskGroupBasedCorrections" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

local function namedKeys(keys)
    local named = {}
    for index = 1, math.min(#keys, MAX_NAMED_KEYS) do named[index] = keys[index] end
    if #keys > MAX_NAMED_KEYS then named[#named + 1] = string.format("%d more", #keys - MAX_NAMED_KEYS) end
    return table.concat(named, ", ")
end

local function restoreAndRefuse(context, catalog, photo, write, reason)
    if not GuardedMaskWrite.restore(context, catalog, photo, write.previous, write.from, write.to) then
        error(reason .. "; the new masks could not be confirmed removed, check the photo's masks in Develop", 0)
    end
    if #context.ledger:since(write.to) > 0 then
        local changed = keysOutsideMasksChangedSince(catalog, photo, write.settings)
        if #changed > 0 then
            error(reason .. "; the new masks were removed, but Update AI Settings also changed " .. namedKeys(changed)
                .. " on the photo", 0)
        end
        context.ledger:undone(write.to)
    end
    Reply.refuse(reason .. "; the new masks were removed")
end

local function aiComponentsById(entry)
    local byId = {}
    for index, component in ipairs(entry.CorrectionMasks or {}) do
        if component.What == AIMaskData.KIND then
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
            context:warn(string.format("Photo %s: mask %s was already failed (%s) before this call",
                photoId, idOf(entry), AIMaskData.errorReasonText(reason)))
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

local function failureText(spec, own, failedComponents, photoId)
    local names, reasons, nothingFound = {}, {}, true
    for _, component in ipairs(failedComponents) do
        local name = tostring(component.MaskName or component.MaskID or "an unnamed component")
        names[#names + 1] = name
        reasons[#reasons + 1] = name .. ": " .. AIMaskData.errorReasonText(component.ErrorReason)
        if component.ErrorReason ~= 1 then nothingFound = false end
    end
    if not nothingFound then
        return string.format("Lightroom could not compute %s on photo %s (%s)", spec.subject, photoId,
            table.concat(reasons, "; "))
    end
    if spec.nothingFound then return spec.nothingFound(own) end
    return string.format("Lightroom found nothing for %s on photo %s (%s)", spec.subject, photoId,
        table.concat(names, ", "))
end

function AIMaskCompute.run(context, catalog, photo, spec)
    local photoId = tostring(photo.localIdentifier)
    local previous = spec.before
    local write
    if spec.build then
        local from = context.ledger:mark()
        local applied = GuardedMaskWrite.apply(context, catalog, photo, { description = spec.description, build = spec.build })
        previous = applied.previous
        write = { previous = previous, settings = applied.settings, from = from, to = context.ledger:mark() }
    end
    local function fail(reason)
        if write then restoreAndRefuse(context, catalog, photo, write, reason) end
        error(reason, 0)
    end
    local compute = updateAISettings(context, catalog, photo)
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
    if #failedOwn > 0 then fail(failureText(spec, own, failedOwn, photoId)) end
    warnAboutExisting(context, photoId, existing, after)
    return { own = own, components = components, previous = previous }
end

return AIMaskCompute
