local LrApplication = import 'LrApplication'

local Reply = require 'Reply'
local MaskCreate = require 'HandlerMaskCreate'
local PhotoLookup = require 'PhotoLookup'
local AIMaskCompute = require 'AIMaskCompute'
local AIMaskData = require 'AIMaskData'
local AiMaskParts = require 'AiMaskParts'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'

local AiMaskHandler = {}

local COMPUTE_TIMEOUT_SECONDS = 120

local stateOf = AIMaskData.computeState

local function labelOf(request, index)
    return request.specs[index].name
end

local function listNames(request, fresh, wantedState)
    local names = {}
    for index, entry in ipairs(fresh) do
        if stateOf(entry) == wantedState then names[#names + 1] = labelOf(request, index) end
    end
    return table.concat(names, ", ")
end

local function missingMessage(request, photoId, fresh)
    local missing = listNames(request, fresh, "failed")
    if request.kind == "people" then
        return string.format("Lightroom found no %s on any person in photo %s", missing, photoId)
    end
    return string.format("Lightroom found no %s in photo %s", missing, photoId)
end

local function appendEntries(entries, request)
    for _, spec in ipairs(request.specs) do
        entries[#entries + 1] = AiMaskParts.newEntry(spec, request)
    end
    return entries
end

local function resultFor(photoId, request, fresh)
    local masks = {}
    for index, entry in ipairs(fresh) do
        masks[index] = {
            mask_id = entry.CorrectionID ~= nil and tostring(entry.CorrectionID) or nil,
            [request.kind == "people" and "part" or "category"] = labelOf(request, index),
        }
    end
    local result = {
        photo_id = photoId,
        type = request.kind,
        mask_id = masks[1].mask_id,
        masks = masks,
    }
    return result
end

local function createAiMasks(context, args, request)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)
    AIMaskCompute.requireSupported(context.title, photo)

    local fresh = MaskCreate.nothingFoundOr(photoId, "an \"Update AI Settings Errors\"", function()
        return DevelopSession.run(context, catalog, false, function()
        local expectedCount = #request.specs

        local change = AIMaskCompute.write(catalog, photo, {
            description = "Create AI masks",
            keepsExisting = true,
            build = function(entries) return appendEntries(entries, request) end,
        })

        local computed, state = AIMaskCompute.waitForAdded(catalog, photo, change, COMPUTE_TIMEOUT_SECONDS)
        if state == "pending" and #computed == expectedCount then
            error(string.format("Lightroom has not finished computing the %s mask after %d seconds, so it"
                .. " was left on photo %s untouched. Do not write to this photo until the masks show in Develop:"
                .. " writing while Lightroom still computes can freeze Lightroom.",
                request.kind, COMPUTE_TIMEOUT_SECONDS, photoId), 0)
        end
        if #computed ~= expectedCount then
            AIMaskCompute.rollBack(catalog, photo, change, string.format(
                "Lightroom kept %d of the %d requested masks on photo %s", #computed, expectedCount, photoId))
        end
        if state == "failed" then
            AIMaskCompute.rollBack(catalog, photo, change, missingMessage(request, photoId, computed))
        end
        AIMaskCompute.warnIfRecomputedExisting(context, photo, change)
        return computed
        end)
    end)
    if Reply.isParts(fresh) then return fresh end

    local result = resultFor(photoId, request, fresh)
    Log.info(string.format("Created %d %s mask(s) on photo %s", #fresh, request.kind, photoId))
    return result
end

function AiMaskHandler.createMask(args, context)
    local request
    if args.type == "people" then
        request = AiMaskParts.parsePeople(args)
    else
        request = AiMaskParts.parseLandscape(args)
    end
    return createAiMasks(context, args, request)
end

return AiMaskHandler
