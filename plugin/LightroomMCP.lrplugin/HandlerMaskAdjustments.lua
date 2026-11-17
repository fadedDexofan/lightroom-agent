local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local Contract = require 'Contract'
local Reply = require 'Reply'
local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local LocalSliders = require 'LocalSliders'
local Log = require 'Log'
local MaskSelection = require 'MaskSelection'
local MaskSettle = require 'MaskSettle'

local MaskAdjustmentsHandler = {}

local WRITE_PERSIST_SETTLE_SECONDS = 0.5

local EXTRA_CONTROLLER_FUNCTIONS = { "setValue", "getValue", "getSelectedMask" }

local function requestedOf(value)
    local requested = {}
    for _, slider in ipairs(LocalSliders.list) do
        if value[slider.name] ~= nil then
            requested[#requested + 1] = { slider = slider, value = value[slider.name] }
        end
    end
    return requested
end

local COMMIT_LATE = "Lightroom changed the sliders but had not saved them to the photo's settings after %d s,"
    .. " so a mask change made now could be undone by the late save; read the mask before retrying"

local function outcomeOf(requested, changed, unchanged)
    local adjustments = {}
    for _, entry in ipairs(requested) do
        adjustments[entry.slider.name] = MaskSelection.readSlider(entry.slider.name)
    end
    for _, change in ipairs(changed) do
        change.to = adjustments[change.slider]
    end
    return { adjustments = adjustments, changed = changed, unchanged = unchanged }
end

local function movedOutcome(maskId, changed, unchanged, written)
    return {
        changed = changed,
        unchanged = unchanged,
        uncertain = MaskSelection.movedAfterWriting(maskId, written),
    }
end

local function namesOf(changed)
    local names = {}
    for _, change in ipairs(changed) do names[#names + 1] = change.slider end
    return names
end

local function applyToSelectedMask(catalog, photo, photoId, maskId, requested)
    local storedBefore = MaskSettle.storedAdjustmentFields(catalog, photo, maskId)

    local before = {}
    for _, entry in ipairs(requested) do
        local current = MaskSelection.readSlider(entry.slider.name)
        if current == nil then
            Reply.refuse(entry.slider.name .. " is not available on mask " .. maskId .. " of photo " .. photoId
                .. "; nothing was written")
        end
        before[entry.slider.name] = current
    end

    local changed, unchanged = {}, {}
    for _, entry in ipairs(requested) do
        local slider, wanted = entry.slider, entry.value
        if MaskSelection.sliderNear(slider, before[slider.name], wanted) then
            unchanged[#unchanged + 1] = slider.name
        else
            local kept, problem, sent = MaskSelection.writeSlider(slider, wanted, maskId)
            if not kept then
                if not MaskSelection.isSelected(maskId) then
                    local written = namesOf(changed)
                    if sent then written[#written + 1] = slider.name end
                    if #written == 0 then Reply.refuse(MaskSelection.movedBeforeWriting(maskId)) end
                    return movedOutcome(maskId, changed, unchanged, written)
                end
                if #changed == 0 and MaskSelection.sliderNear(slider, MaskSelection.readSlider(slider.name), before[slider.name]) then
                    Reply.refuse(problem .. "; nothing was written")
                end
                local outcome = outcomeOf(requested, changed, unchanged)
                outcome.problem = problem
                return outcome
            end
            changed[#changed + 1] = { slider = slider.name, from = before[slider.name], to = wanted }
        end
    end

    if #changed > 0 then
        DevelopSession.flushPendingEdits()
        LrTasks.sleep(WRITE_PERSIST_SETTLE_SECONDS)
        if not MaskSelection.isSelected(maskId) then
            return movedOutcome(maskId, changed, unchanged, namesOf(changed))
        end
        for _, entry in ipairs(requested) do
            if not MaskSelection.sliderNear(entry.slider, MaskSelection.readSlider(entry.slider.name), entry.value) then
                local outcome = outcomeOf(requested, changed, unchanged)
                outcome.problem = MaskSelection.sliderNotKept(entry.slider, entry.value)
                return outcome
            end
        end
        if not MaskSettle.waitForCommit(catalog, photo, maskId, storedBefore) then
            local outcome = outcomeOf(requested, changed, unchanged)
            outcome.uncertain = string.format(COMMIT_LATE, Contract.MASK_SAVE_WAIT_SECONDS)
            return outcome
        end
    end

    return outcomeOf(requested, changed, unchanged)
end

local function readAllSliders()
    local adjustments, unavailable = {}, {}
    for _, slider in ipairs(LocalSliders.list) do
        local value = MaskSelection.readSlider(slider.name)
        if value == nil then
            unavailable[#unavailable + 1] = slider.name
        else
            adjustments[slider.name] = value
        end
    end
    return { adjustments = adjustments, unavailable = unavailable }
end

function MaskAdjustmentsHandler.setMaskAdjustments(args, context)
    local maskId = args.mask_id
    local requested = requestedOf(args.adjustments)
    MaskSelection.requireControllerFunctions("set_mask_adjustments", EXTRA_CONTROLLER_FUNCTIONS, "Lightroom Classic 11")
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local outcome = DevelopSession.withPhoto(context, catalog, photo, function()
        return MaskSelection.withMaskSelected(catalog, photo, maskId, function()
            return applyToSelectedMask(catalog, photo, photoId, maskId, requested)
        end)
    end)

    Log.info(string.format("Mask %s on photo %s: %d sliders changed, %d already at the value",
        maskId, photoId, #outcome.changed, #outcome.unchanged))

    return Reply.parts({
        data = {
            photo_id = photoId,
            mask_id = maskId,
            adjustments = outcome.adjustments,
            changed = outcome.changed,
            unchanged = outcome.unchanged,
        },
        problem = outcome.problem,
        unknown = outcome.uncertain and { { photo_id = photoId, reason = outcome.uncertain } } or nil,
    })
end

function MaskAdjustmentsHandler.readSelected()
    local result = readAllSliders()
    if next(result.adjustments) == nil then
        error("Local adjustments cannot be read; they need Lightroom Classic 11 or later", 0)
    end
    return result
end

return MaskAdjustmentsHandler
