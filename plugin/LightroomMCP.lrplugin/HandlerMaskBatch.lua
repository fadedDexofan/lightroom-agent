local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local AIMaskCompute = require 'AIMaskCompute'
local AIMaskData = require 'AIMaskData'
local DevelopBatch = require 'DevelopBatch'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local MaskCreate = require 'HandlerMaskCreate'
local MaskTypes = require 'MaskTypes'
local MaskWriteAdmission = require 'MaskWriteAdmission'
local Reply = require 'Reply'

local MaskBatchHandler = {}

local LAST_STEP_AND_RESTORE_SECONDS = 70

local SAVED_ENTRY_TIMEOUT_SECONDS = 10
local SAVED_ENTRY_STABLE_READS = 3

local CORRECTION_ID_FIELDS = { "CorrectionID", "CorrectionSyncID" }
local COMPONENT_ID_FIELDS = { "MaskID", "MaskSyncID" }

local function requireTemplateAdmitted(catalog, photo)
    local processVersion
    catalog:withReadAccessDo(function() processVersion = photo:getDevelopSettings().ProcessVersion end)
    MaskWriteAdmission.requireAdmitted(catalog, processVersion)
end

local function readSavedCorrection(catalog, photo, maskId)
    local previous, found
    local steadyReads = 0
    local ready = DevelopSession.waitFor(function()
        local _, correction = GuardedMaskWrite.findCorrection(GuardedMaskWrite.readEntries(catalog, photo), maskId)
        if correction and AIMaskData.computeState(correction) == "computed" and previous
            and #GuardedMaskWrite.compareEntries({ previous }, { correction }) == 0 then
            steadyReads = steadyReads + 1
        else
            steadyReads = 0
        end
        previous = correction
        found = correction
        return steadyReads >= SAVED_ENTRY_STABLE_READS
    end, SAVED_ENTRY_TIMEOUT_SECONDS)
    if ready then return found end
    return nil
end

local function recomputableCopyOf(correction)
    local copy = GuardedMaskWrite.deepClone(correction)
    for _, key in ipairs(CORRECTION_ID_FIELDS) do copy[key] = nil end
    for _, component in ipairs(copy.CorrectionMasks) do
        for _, key in ipairs(COMPONENT_ID_FIELDS) do component[key] = nil end
    end
    return AIMaskData.withoutComputedData({ MaskGroupBasedCorrections = { copy } }).MaskGroupBasedCorrections[1]
end

local function computedMaskOnTarget(context, catalog, photo, template, typeName)
    local change = AIMaskCompute.write(catalog, photo, {
        description = "Add " .. typeName .. " mask",
        keepsExisting = true,
        build = function(entries)
            entries[#entries + 1] = GuardedMaskWrite.deepClone(template)
            return entries
        end,
    })
    local added = AIMaskCompute.requireComputed(catalog, photo, change, "the " .. typeName .. " mask")
    AIMaskCompute.warnIfRecomputedExisting(context, photo, change)
    return added[1]
end

local function nothingFoundAlert(message, typeName)
    return message .. "; Lightroom probably shows a \"No " .. typeName
        .. " detected\" alert: click OK in Lightroom before the next Develop call"
end

function MaskBatchHandler.createMaskBatch(args, context)
    local typeName, spec = args.type, MaskTypes.SPECS[args.type]
    local values = args.adjustments or {}
    MaskCreate.requireCreateApi(context.title)

    local catalog = LrApplication.activeCatalog()
    local template
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = LAST_STEP_AND_RESTORE_SECONDS,
        prepare = function(photo) AIMaskCompute.requireSupported(context.title, photo) end,
        each = function(photo, state)
            local photoId = tostring(photo.localIdentifier)
            if not template then
                requireTemplateAdmitted(catalog, photo)
                local created, mask = LrTasks.pcall(function()
                    DevelopSession.openPhoto(catalog, photo, state)
                    return MaskCreate.createInDevelop(context, catalog, photo, photoId, typeName, spec, values)
                end)
                if not created then
                    if MaskCreate.isNothingFoundFailure(Reply.messageOf(mask)) then
                        DevelopBatch.halt(nothingFoundAlert(Reply.messageOf(mask), typeName))
                    end
                    error(mask, 0)
                end
                local saved = readSavedCorrection(catalog, photo, mask.ID)
                template = { photoId = photoId, copy = saved and recomputableCopyOf(saved) }
                return { status = "created", mask_id = mask.ID }
            end
            if not template.copy then
                Reply.refuse("Lightroom did not save the new mask on photo " .. template.photoId
                    .. ", so it could not be added here")
            end
            local computed = computedMaskOnTarget(context, catalog, photo, template.copy, typeName)
            return {
                status = "computed",
                mask_id = computed.CorrectionID ~= nil and tostring(computed.CorrectionID) or nil,
            }
        end,
    })
end

return MaskBatchHandler
