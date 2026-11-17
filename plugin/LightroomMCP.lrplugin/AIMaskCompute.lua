local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local Contract = require 'Contract'
local CatalogWrite = require 'CatalogWrite'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local JsonValue = require 'JsonValue'
local Reply = require 'Reply'

local AIMaskCompute = {}

AIMaskCompute.MINIMUM_VERSION = "Lightroom Classic 13.3"

local RECOMPUTED_EXISTING = "Lightroom recomputed AI settings for the whole photo, so its existing AI masks may have changed"

function AIMaskCompute.supported(photo)
    return type(photo.updateAISettings) == "function"
end

function AIMaskCompute.requireSupported(toolName, photo)
    if not AIMaskCompute.supported(photo) then
        Reply.refuse(toolName .. " needs " .. AIMaskCompute.MINIMUM_VERSION .. " or later")
    end
end

local function addedOf(entries, keep)
    local added = {}
    for index = keep + 1, #entries do added[#added + 1] = entries[index] end
    return added
end

local function stateOf(added)
    local state = "computed"
    for _, entry in ipairs(added) do
        local entryState = AIMaskData.computeState(entry)
        if entryState == "pending" then return "pending" end
        if entryState == "failed" then state = "failed" end
    end
    return state
end

function AIMaskCompute.rollBack(catalog, photo, change, reason)
    local removed, removeError = LrTasks.pcall(GuardedMaskWrite.apply, catalog, photo, {
        description = "Remove AI masks",
        build = function(entries)
            local restored = {}
            for index = 1, change.keep do restored[index] = entries[index] end
            for index = change.keep + 1, #change.previous do
                restored[index] = GuardedMaskWrite.deepClone(change.previous[index])
            end
            return restored
        end,
    })
    if not removed then
        error(reason .. "; the new masks could not be removed, check the photo's masks in Develop: "
            .. Reply.messageOf(removeError), 0)
    end
    if change.recomputedExisting then
        error(reason .. "; the new masks were removed, but " .. RECOMPUTED_EXISTING, 0)
    end
    Reply.refuse(reason .. "; the new masks were removed")
end

-- applyDevelopSettings has no AI flag and the applyDevelopPreset one reportedly
-- reopens the modal-dialog lockup, so recompute in a second write transaction
-- (same-transaction calls do not see the new settings).
local function updateAISettings(catalog, photo)
    local called, ok, err = false, false, nil
    local ran, gateError = LrTasks.pcall(CatalogWrite.run, catalog, "Update AI Settings", function()
        called = true
        ok, err = LrTasks.pcall(function() photo:updateAISettings() end)
    end)
    if not ran then return false, gateError, called end
    return ok, err, called
end

local function heldAIMasks(entries)
    return AIMaskData.containsAIMasks({ MaskGroupBasedCorrections = entries })
end

function AIMaskCompute.write(catalog, photo, request)
    local written = GuardedMaskWrite.apply(catalog, photo, { description = request.description, build = request.build })
    local keep = request.keepsExisting and #written.previous or 0
    local change = { previous = written.previous, keep = keep }
    local ok, err, called = updateAISettings(catalog, photo)
    change.recomputedExisting = called and keep > 0 and heldAIMasks(written.previous)
    if not ok then
        AIMaskCompute.rollBack(catalog, photo, change, "Lightroom could not compute the AI masks: " .. Reply.messageOf(err))
    end
    return change
end

local function warnRecomputed(context, photo)
    context:warn("Photo " .. tostring(photo.localIdentifier) .. ": " .. RECOMPUTED_EXISTING)
end

function AIMaskCompute.warnIfRecomputedExisting(context, photo, change)
    if change.recomputedExisting then warnRecomputed(context, photo) end
end

local function waitForNew(catalog, photo, newOf, timeoutSeconds)
    local added, state
    DevelopSession.waitFor(function()
        added = newOf(GuardedMaskWrite.readEntries(catalog, photo))
        state = stateOf(added)
        return state ~= "pending"
    end, timeoutSeconds)
    return added, state
end

function AIMaskCompute.waitForAdded(catalog, photo, change, timeoutSeconds)
    return waitForNew(catalog, photo, function(entries) return addedOf(entries, change.keep) end, timeoutSeconds)
end

local function entriesById(entries)
    local byId = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and entry.CorrectionID ~= nil then byId[tostring(entry.CorrectionID)] = entry end
    end
    return byId
end

local function changedIds(beforeById, after)
    local changed = {}
    for id, entry in pairs(entriesById(after)) do
        if beforeById[id] ~= nil and not JsonValue.equal(beforeById[id], entry) then changed[id] = true end
    end
    return changed
end

local function entriesJudged(entries, beforeById, changed)
    local judged = {}
    for _, entry in ipairs(entries) do
        local id = type(entry) == "table" and entry.CorrectionID ~= nil and tostring(entry.CorrectionID)
        if not id or beforeById[id] == nil or changed[id] then judged[#judged + 1] = entry end
    end
    return judged
end

local function notComputedReason(state, subject)
    if state == "failed" then return "Lightroom reported an error computing " .. subject end
    if state ~= "computed" then
        return string.format("Lightroom did not finish computing %s within %d s", subject, Contract.AI_MASK_COMPUTE_WAIT_SECONDS)
    end
    return nil
end

function AIMaskCompute.computeChanged(context, catalog, photo, subject, before)
    local beforeById = entriesById(before)
    local changed = changedIds(beforeById, GuardedMaskWrite.readEntries(catalog, photo))
    local ok, err, called = updateAISettings(catalog, photo)
    if called and heldAIMasks(before) then warnRecomputed(context, photo) end
    if not ok then return "Lightroom could not compute " .. subject .. ": " .. Reply.messageOf(err) end
    local _, state = waitForNew(catalog, photo, function(entries) return entriesJudged(entries, beforeById, changed) end,
        Contract.AI_MASK_COMPUTE_WAIT_SECONDS)
    return notComputedReason(state, subject)
end

function AIMaskCompute.requireComputed(catalog, photo, change, subject)
    local added, state = AIMaskCompute.waitForAdded(catalog, photo, change, Contract.AI_MASK_COMPUTE_WAIT_SECONDS)
    local reason = notComputedReason(state, subject)
    if reason then AIMaskCompute.rollBack(catalog, photo, change, reason) end
    return added
end

return AIMaskCompute
