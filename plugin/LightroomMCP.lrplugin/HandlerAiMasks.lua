local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local AIMaskCompute = require 'AIMaskCompute'
local AIMaskData = require 'AIMaskData'
local AiMaskParts = require 'AiMaskParts'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'

local AiMaskHandler = {}

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

    local fresh = DevelopSession.run(context, catalog, false, function()
        return AIMaskCompute.run(context, catalog, photo, {
            description = "Create AI masks",
            subject = "the " .. request.kind .. " masks",
            expected = #request.specs,
            build = function(entries) return appendEntries(entries, request) end,
            failure = function(own) return missingMessage(request, photoId, own) end,
        }).own
    end)

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
