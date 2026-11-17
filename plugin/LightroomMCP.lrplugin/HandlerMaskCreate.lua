local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local Reply = require 'Reply'
local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local LocalSliders = require 'LocalSliders'
local Log = require 'Log'
local MaskCreationAdjustments = require 'MaskCreationAdjustments'
local MaskSelection = require 'MaskSelection'
local MaskTypes = require 'MaskTypes'

local MaskCreateHandler = {}


local REQUIRED_API_FUNCTIONS = { "createNewMask", "deleteMask", "selectMask", "selectTool", "setValue" }
local MASK_API_MINIMUM_VERSION = "Lightroom Classic 11"

local AI_DETECTION_TIMEOUT_SECONDS = 30
local MASK_STABLE_POLLS = 10
local HISTORY_GROUPING_SECONDS = 10
local DEFAULT_TRACKING_DELAY_SECONDS = 2
local DEFAULT_GROUPING_THRESHOLD_SECONDS = 0.5
local NOTHING_FOUND_PREFIX = "Lightroom found no "

local function requireCreateApi(toolName)
    MaskSelection.requireControllerFunctions(toolName or "create_mask", REQUIRED_API_FUNCTIONS, MASK_API_MINIMUM_VERSION)
end

local function awaitNewMask(knownIds)
    local fresh, stablePolls = {}, 0
    local settled = DevelopSession.waitFor(function()
        local masks = MaskSelection.readMasksOrNil()
        fresh = masks and MaskSelection.masksNotIn(masks, knownIds) or {}
        if #fresh == 1 and #MaskSelection.toolsOf(fresh[1]) > 0 then
            stablePolls = stablePolls + 1
        else
            stablePolls = 0
        end
        return stablePolls >= MASK_STABLE_POLLS
    end, AI_DETECTION_TIMEOUT_SECONDS)
    return settled and fresh[1] or nil
end

local function describeFailure(typeName, photoId, knownIds)
    local masks = MaskSelection.readMasksOrNil() or {}
    local fresh = MaskSelection.masksNotIn(masks, knownIds)
    if #fresh > 1 then
        return string.format("Lightroom added %d masks while creating the %s mask on photo %s",
            #fresh, typeName, photoId)
    end
    if #fresh == 1 then
        return string.format("Lightroom created an empty %s mask on photo %s", typeName, photoId)
    end
    return string.format(NOTHING_FOUND_PREFIX .. "%s to select on photo %s; Lightroom shows an alert such as"
        .. " \"No %s detected\" for this, so click OK in Lightroom before the next Develop call",
        typeName, photoId, typeName)
end

local function setHistoryGrouping(seconds, trackingSeconds)
    LrTasks.pcall(LrDevelopController.setTrackingDelay, trackingSeconds)
    LrTasks.pcall(LrDevelopController.setMultipleAdjustmentThreshold, seconds)
end

local function writeNeutralAdjustments(values, maskId, writing)
    setHistoryGrouping(HISTORY_GROUPING_SECONDS, HISTORY_GROUPING_SECONDS)
    local ok, err = LrTasks.pcall(function()
        for _, slider in ipairs(LocalSliders.list) do
            if not MaskSelection.isSelected(maskId) then
                writing.moved = true
                error(MaskSelection.SELECTION_MOVED .. " the new mask", 0)
            end
            LrDevelopController.setValue(slider.name, values[slider.name] or LocalSliders.neutralOf(slider))
            writing.written[#writing.written + 1] = slider.name
        end
    end)
    LrTasks.pcall(LrDevelopController.stopTracking, true)
    setHistoryGrouping(DEFAULT_GROUPING_THRESHOLD_SECONDS, DEFAULT_TRACKING_DELAY_SECONDS)
    if not ok then error(err, 0) end
end

local function createInDevelop(context, catalog, photo, photoId, typeName, spec, values)
    local knownIds = MaskSelection.idSet(MaskSelection.readMasks(catalog, photo))
    local previousTool = MaskSelection.openMaskingTool()

    local created
    local writing = { written = {} }
    local ok, err = LrTasks.pcall(function()
        LrDevelopController.createNewMask(spec.toolType, spec.subtype)
        created = awaitNewMask(knownIds)
        if not created then error(describeFailure(typeName, photoId, knownIds), 0) end
        MaskSelection.withMaskSelected(catalog, photo, created.ID, function()
            writeNeutralAdjustments(values, created.ID, writing)
            MaskCreationAdjustments.confirmSelected(values)
        end)
    end)

    if not ok then
        local failure = Reply.messageOf(err)
        local problem = MaskSelection.problemUnlessAddedRemoved(catalog, photo, knownIds, "the new mask")
        MaskSelection.restoreTool(previousTool)
        if problem then error(failure .. "; " .. problem, 0) end
        if writing.moved and #writing.written > 0 then
            error(failure .. "; the new mask was removed, but written before the move: "
                .. table.concat(writing.written, ", ") .. "; read the masks with list_masks before retrying", 0)
        end
        Reply.refuse(failure)
    end
    MaskSelection.restoreTool(previousTool)

    local after = MaskSelection.readMasksOrNil()
    for id in pairs(knownIds) do
        if after and not MaskSelection.findMask(after, id) then
            context:warn(string.format("Lightroom no longer lists mask %s on photo %s after creating %s; read the"
                .. " masks with list_masks before editing it", id, photoId, tostring(created.ID)))
        end
    end
    return MaskSelection.findMask(after, created.ID) or created
end

MaskCreateHandler.requireCreateApi = requireCreateApi
MaskCreateHandler.createInDevelop = createInDevelop

function MaskCreateHandler.isNothingFoundFailure(message)
    return type(message) == "string" and message:find(NOTHING_FOUND_PREFIX, 1, true) ~= nil
end

function MaskCreateHandler.nothingFoundOr(photoId, alert, body)
    local ok, result = LrTasks.pcall(body)
    if ok then return result end
    local message = Reply.messageOf(result)
    if MaskCreateHandler.isNothingFoundFailure(message) then
        local item = { { photo_id = photoId, reason = message } }
        local refused = Reply.refusalOf(result) ~= nil
        return Reply.parts({
            failed = refused and item or nil,
            unknown = not refused and item or nil,
            warnings = { "Lightroom may be showing " .. alert .. " alert; click OK in Lightroom before the next Develop call" },
        })
    end
    error(result, 0)
end

function MaskCreateHandler.createMask(args, context)
    if args.type == "people" or args.type == "landscape" then
        return (require 'HandlerAiMasks').createMask(args, context)
    end
    local typeName, spec = args.type, MaskTypes.SPECS[args.type]
    local values = args.adjustments or {}
    requireCreateApi()

    local catalog = LrApplication.activeCatalog()

    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    local photoId = tostring(photo.localIdentifier)

    local created = MaskCreateHandler.nothingFoundOr(photoId, string.format("a \"No %s detected\"", typeName),
        function()
            return DevelopSession.withPhoto(context, catalog, photo, function()
                return createInDevelop(context, catalog, photo, photoId, typeName, spec, values)
            end)
        end)
    if Reply.isParts(created) then return created end

    local mask = MaskSelection.normalizeMask(created, photoId)
    Log.info(string.format("Created %s mask %s on photo %s", typeName, tostring(mask.id), photoId))

    local result = {
        photo_id = photoId,
        type = typeName,
        mask_id = mask.id,
        mask = mask,
    }
    if next(values) then
        result.adjustments = values
    end
    return result
end

return MaskCreateHandler
