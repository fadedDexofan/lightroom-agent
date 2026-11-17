local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local Contract = require 'Contract'
local Reply = require 'Reply'
local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskCurves = require 'MaskCurves'
local MaskSettle = require 'MaskSettle'
local MaskSelection = require 'MaskSelection'

local MaskCurvesHandler = {}

local WRITE_CONFIRM_TIMEOUT_SECONDS = 2
local WRITE_ATTEMPTS = 2
local WRITE_PERSIST_SETTLE_SECONDS = 0.5

local CONTROLLER_FUNCTIONS = { "setValue", "getValue" }

local function requireCurveSupport(toolName)
    MaskSelection.requireControllerFunctions(toolName, CONTROLLER_FUNCTIONS, MaskCurves.MINIMUM_VERSION_LABEL)
end

local function readCurve(channel)
    local ok, raw = LrTasks.pcall(LrDevelopController.getValue, channel.parameter)
    if not ok then return nil end
    return MaskCurves.normalize(raw)
end

local function unavailableMessage(channelNames, maskId, photoId)
    return string.format("Local tone curve %s of mask %s on photo %s cannot be read; local curves need %s or later",
        table.concat(channelNames, ", "), maskId, photoId, MaskCurves.MINIMUM_VERSION_LABEL)
end

local function notKept(channel)
    return string.format("Lightroom did not keep the %s curve", channel.name)
end

local function writtenNames(written)
    local names = {}
    for _, entry in ipairs(written) do
        names[#names + 1] = entry.channel.name
    end
    return table.concat(names, ", ")
end

local function writeAndConfirm(entry, wanted, maskId, written)
    local channel = entry.channel
    for attempt = 1, WRITE_ATTEMPTS do
        if not MaskSelection.isSelected(maskId) then return false, MaskSelection.SELECTION_MOVED end
        if attempt == 1 then written[#written + 1] = entry end
        local ok, err = LrTasks.pcall(LrDevelopController.setValue, channel.parameter, MaskCurves.copy(wanted))
        if not ok then
            return false, string.format("Lightroom rejected the %s curve: %s", channel.name, tostring(err))
        end
        local confirmed = DevelopSession.waitFor(function()
            return MaskCurves.same(readCurve(channel), wanted)
        end, WRITE_CONFIRM_TIMEOUT_SECONDS)
        if confirmed then return true end
    end
    return false, notKept(channel)
end

local function namesOrNothing(names)
    return #names > 0 and table.concat(names, ", ") or "nothing"
end

local function stopAfterRestore(problem, written, maskId)
    if #written == 0 then Reply.refuse(problem .. "; no curve had been written yet") end
    local restored, unconfirmed = {}, {}
    for index = #written, 1, -1 do
        local entry = written[index]
        if not MaskSelection.isSelected(maskId) then
            local notRestored = {}
            for pending = 1, index do notRestored[pending] = written[pending].channel.name end
            for _, name in ipairs(unconfirmed) do notRestored[#notRestored + 1] = name end
            error(string.format("%s; mask %s is no longer selected; restored: %s; not restored: %s; read the mask"
                .. " before retrying", problem, maskId, namesOrNothing(restored), namesOrNothing(notRestored)), 0)
        end
        LrTasks.pcall(LrDevelopController.setValue, entry.channel.parameter, MaskCurves.copy(entry.before))
        local back = DevelopSession.waitFor(function()
            return MaskCurves.same(readCurve(entry.channel), entry.before)
        end, WRITE_CONFIRM_TIMEOUT_SECONDS)
        table.insert(back and restored or unconfirmed, 1, entry.channel.name)
    end
    if #unconfirmed > 0 then
        error(string.format("%s; could not confirm restoring %s; read the mask before retrying",
            problem, table.concat(unconfirmed, ", ")), 0)
    end
    Reply.refuse(problem .. "; restored: " .. writtenNames(written))
end

local function failedCommit(written)
    error(string.format("Lightroom changed the curves but had not saved them to the photo's settings after %d s,"
        .. " so a mask change made now could be undone by the late save; written: %s",
        Contract.MASK_SAVE_WAIT_SECONDS, writtenNames(written)), 0)
end

local function applyToSelectedMask(catalog, photo, photoId, maskId, requested)
    local storedBefore = MaskSettle.storedAdjustmentFields(catalog, photo, maskId)
    local before, unreadable = {}, {}
    for _, entry in ipairs(requested) do
        local current = readCurve(entry.channel)
        if current == nil then
            unreadable[#unreadable + 1] = entry.channel.name
        end
        before[entry.channel.name] = current
    end
    if #unreadable > 0 then
        Reply.refuse(unavailableMessage(unreadable, maskId, photoId) .. "; nothing was written")
    end

    local changed, unchanged, written = {}, {}, {}
    for _, entry in ipairs(requested) do
        local channel, wanted = entry.channel, entry.points
        if MaskCurves.same(before[channel.name], wanted) then
            unchanged[#unchanged + 1] = channel.name
        else
            local kept, problem = writeAndConfirm({ channel = channel, before = before[channel.name] }, wanted, maskId,
                written)
            if not kept then stopAfterRestore(problem, written, maskId) end
            changed[#changed + 1] = { channel = channel.name, from = before[channel.name], to = wanted }
        end
    end

    if #changed > 0 then
        DevelopSession.flushPendingEdits()
        LrTasks.sleep(WRITE_PERSIST_SETTLE_SECONDS)
        if not MaskSelection.isSelected(maskId) then stopAfterRestore(MaskSelection.SELECTION_MOVED, written, maskId) end
        for _, entry in ipairs(requested) do
            if not MaskCurves.same(readCurve(entry.channel), entry.points) then
                stopAfterRestore(notKept(entry.channel), written, maskId)
            end
        end
        if not MaskSettle.waitForCommit(catalog, photo, maskId, storedBefore) then
            failedCommit(written)
        end
    end

    local curves = {}
    for _, entry in ipairs(requested) do
        curves[entry.channel.name] = readCurve(entry.channel)
    end
    for _, change in ipairs(changed) do
        change.to = curves[change.channel]
    end
    return { curves = curves, changed = changed, unchanged = unchanged }
end

local function readAllCurves(photoId, maskId)
    local curves, unavailable = {}, {}
    for _, channel in ipairs(MaskCurves.channels) do
        local points = readCurve(channel)
        if points == nil then
            unavailable[#unavailable + 1] = channel.name
        else
            curves[channel.name] = points
        end
    end
    if #unavailable == #MaskCurves.channels then
        error(unavailableMessage(unavailable, maskId, photoId), 0)
    end
    return { curves = curves, unavailable = unavailable }
end

function MaskCurvesHandler.setMaskCurves(args, context)
    local maskId = args.mask_id
    local requested = MaskCurves.requested(args.curves)
    requireCurveSupport("set_mask_curves")
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local outcome = DevelopSession.withPhoto(context, catalog, photo, function()
        return MaskSelection.withMaskSelected(catalog, photo, maskId, function()
            return applyToSelectedMask(catalog, photo, photoId, maskId, requested)
        end)
    end)

    Log.info(string.format("Mask %s on photo %s: %d curves changed, %d already at the value",
        maskId, photoId, #outcome.changed, #outcome.unchanged))

    return {
        photo_id = photoId,
        mask_id = maskId,
        curves = outcome.curves,
        changed = outcome.changed,
        unchanged = outcome.unchanged,
    }
end

function MaskCurvesHandler.readSelected(photoId, maskId)
    return readAllCurves(photoId, maskId)
end

return MaskCurvesHandler
