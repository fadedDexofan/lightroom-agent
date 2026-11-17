local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskPointColors = require 'MaskPointColors'
local MaskSelection = require 'MaskSelection'
local Reply = require 'Reply'

local MaskPointColorsHandler = {}

local LOCAL_POINT_COLORS = "local_PointColors"
local FOR_MASKING = true
local CHANGE_TIMEOUT_SECONDS = 3
local SELECT_TIMEOUT_SECONDS = 4
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local UPDATE_ATTEMPTS = 2
local PERSIST_SETTLE_SECONDS = 0.5

local EDIT_CONTROLLER_FUNCTIONS = {
    "getValue",
    "getSelectedPointColorSwatchIndex",
    "selectPointColorSwatch",
    "addPointColorSwatch",
    "updateSelectedPointColorSwatch",
    "deletePointColorSwatch",
}

local function requireSupport(toolName, functionNames)
    MaskSelection.requireControllerFunctions(toolName, functionNames, MaskPointColors.MINIMUM_VERSION_LABEL)
end

local function readSwatches()
    local ok, raw = LrTasks.pcall(LrDevelopController.getValue, LOCAL_POINT_COLORS)
    if not ok then
        error(string.format("Lightroom could not read local Point Color swatches (%s); they need %s or later",
            tostring(raw), MaskPointColors.MINIMUM_VERSION_LABEL), 0)
    end
    return MaskPointColors.normalizeList(raw)
end

local function readSelectedIndex()
    local ok, index = LrTasks.pcall(LrDevelopController.getSelectedPointColorSwatchIndex, FOR_MASKING)
    if ok and type(index) == "number" then return index end
    return nil
end

local function selectSwatchAndWait(index)
    local sinceSelect = RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if readSelectedIndex() == index then return true end
        if sinceSelect >= RESELECT_SECONDS then
            LrTasks.pcall(LrDevelopController.selectPointColorSwatch, index, FOR_MASKING)
            sinceSelect = 0
        end
        sinceSelect = sinceSelect + POLL_SECONDS
        return false
    end, SELECT_TIMEOUT_SECONDS)
end

local function restoreSelection(previousIndex, count)
    if previousIndex and previousIndex >= 1 and previousIndex <= count
        and readSelectedIndex() ~= previousIndex then
        LrTasks.pcall(LrDevelopController.selectPointColorSwatch, previousIndex, FOR_MASKING)
    end
end

local function callController(label, name, ...)
    local called, succeeded, message = LrTasks.pcall(LrDevelopController[name], ...)
    if not called then
        error(string.format("Lightroom rejected %s: %s", label, tostring(succeeded)), 0)
    end
    if succeeded ~= true then
        error(string.format("Lightroom refused %s: %s", label, tostring(message or "no reason given")), 0)
    end
end

local function waitForCount(expected)
    return DevelopSession.waitFor(function()
        return #readSwatches() == expected
    end, CHANGE_TIMEOUT_SECONDS)
end

local function listHolds(actual, expected)
    if #actual ~= #expected then return false end
    for index = 1, #expected do
        if not MaskPointColors.holds(actual[index], expected[index]) then return false end
    end
    return true
end

local function confirmPersisted(expected, maskId, what, stopAfterLost)
    LrTasks.sleep(PERSIST_SETTLE_SECONDS)
    local stillSelected = MaskSelection.isSelected(maskId)
    if not listHolds(readSwatches(), expected) then
        if stopAfterLost then stopAfterLost("Lightroom did not keep " .. what) end
        error("Lightroom did not keep " .. what, 0)
    end
    if not stillSelected then
        error("Another mask became selected while writing " .. what .. "; the swatch was not restored", 0)
    end
end

local function copyList(swatches)
    local copied = {}
    for index, swatch in ipairs(swatches) do copied[index] = MaskPointColors.copySwatch(swatch) end
    return copied
end

local function findNewIndex(after, swatch)
    for index = #after, 1, -1 do
        if MaskPointColors.sameSource(after[index], swatch) then return index end
    end
    return nil
end

local function addSwatch(request, maskId)
    local before = readSwatches()
    if #before >= MaskPointColors.MAX_SWATCHES then
        Reply.refuse(string.format("Mask %s already holds %d Point Color swatches, the most Lightroom allows",
            maskId, MaskPointColors.MAX_SWATCHES))
    end
    local previousIndex = readSelectedIndex()
    MaskSelection.refuseUnlessSelected(maskId)
    callController("the new Point Color swatch", "addPointColorSwatch", request.swatch, FOR_MASKING)
    if not waitForCount(#before + 1) then
        local existing = findNewIndex(before, request.swatch)
        if existing then
            local now = readSwatches()
            restoreSelection(previousIndex, #now)
            if listHolds(now, before) then
                Reply.refuse(string.format("Mask %s already has a swatch with that source color at index %d; nothing"
                    .. " was added", maskId, existing))
            end
            error(string.format("Mask %s already has a swatch with that source color at index %d, and Lightroom"
                .. " changed the swatches while adding it; read the mask before retrying", maskId, existing), 0)
        end
        error("Lightroom did not add the Point Color swatch to mask " .. maskId, 0)
    end

    local after = readSwatches()
    local index = findNewIndex(after, request.swatch)
    if index == nil or not MaskPointColors.holds(after[index], request.swatch) then
        if not MaskSelection.isSelected(maskId) then
            error("Lightroom did not keep the Point Color swatch values, and another mask became selected, so the new"
                .. " swatch was not removed; read the mask before retrying", 0)
        end
        local removed = index ~= nil
            and LrTasks.pcall(LrDevelopController.deletePointColorSwatch, false, index, FOR_MASKING)
            and waitForCount(#before)
            and listHolds(readSwatches(), before)
        if removed then
            restoreSelection(previousIndex, #before)
            Reply.refuse("Lightroom did not keep the Point Color swatch values; the new swatch was removed")
        end
        error("Lightroom did not keep the Point Color swatch values, and the new swatch could not be confirmed"
            .. " removed; read the mask before retrying", 0)
    end

    local expected = copyList(before)
    table.insert(expected, index, MaskPointColors.copySwatch(after[index]))
    confirmPersisted(expected, maskId, "the new Point Color swatch")
    restoreSelection(previousIndex, #before)
    return { index = index, changed = true }
end

local function restoreSwatch(index, original, count)
    if #readSwatches() ~= count or readSelectedIndex() ~= index then return false end
    local called, succeeded = LrTasks.pcall(LrDevelopController.updateSelectedPointColorSwatch,
        MaskPointColors.copySwatch(original), FOR_MASKING)
    if not called or succeeded ~= true then return false end
    return DevelopSession.waitFor(function()
        local now = readSwatches()
        return #now == count and MaskPointColors.holds(now[index], original)
    end, CHANGE_TIMEOUT_SECONDS)
end

local function stopAfterUpdateLost(problem, maskId, index, before, previousIndex)
    if not MaskSelection.isSelected(maskId) then
        error(problem .. "; another mask became selected, so the swatch was not restored; read the mask before"
            .. " retrying", 0)
    end
    if restoreSwatch(index, before[index], #before) and listHolds(readSwatches(), before) then
        restoreSelection(previousIndex, #before)
        Reply.refuse(problem .. "; the original values were restored")
    end
    error(problem .. "; the original values could not be restored; read the mask before retrying", 0)
end

local function updateSwatch(request, maskId)
    local before = readSwatches()
    local index = request.index
    if index > #before then
        Reply.refuse(string.format("No swatch at index %d on mask %s (the mask has %d)", index, maskId, #before))
    end
    local previousIndex = readSelectedIndex()
    if not selectSwatchAndWait(index) then
        error(string.format("Could not select Point Color swatch %d on mask %s", index, maskId), 0)
    end

    local original = before[index]
    local merged = MaskPointColors.merge(original, request.swatch)
    if MaskPointColors.holds(original, merged) then
        restoreSelection(previousIndex, #before)
        return { index = index, changed = false }
    end

    local kept = false
    for attempt = 1, UPDATE_ATTEMPTS do
        if not MaskSelection.isSelected(maskId) then
            if attempt == 1 then Reply.refuse(MaskSelection.movedBeforeWriting(maskId)) end
            break
        end
        callController("the Point Color swatch update", "updateSelectedPointColorSwatch",
            MaskPointColors.copySwatch(merged), FOR_MASKING)
        kept = DevelopSession.waitFor(function()
            local now = readSwatches()
            return #now == #before and MaskPointColors.holds(now[index], merged)
        end, CHANGE_TIMEOUT_SECONDS)
        if kept then break end
    end
    local what = string.format("the update of swatch %d", index)
    local function stopAfterLost(problem) stopAfterUpdateLost(problem, maskId, index, before, previousIndex) end
    if not kept then stopAfterLost("Lightroom did not keep " .. what) end

    local expected = copyList(before)
    expected[index] = merged
    confirmPersisted(expected, maskId, what, stopAfterLost)
    restoreSelection(previousIndex, #before)
    return { index = index, changed = true }
end

local function deleteSwatch(request, maskId)
    local before = readSwatches()
    local index = request.index
    if index > #before then
        Reply.refuse(string.format("No swatch at index %d on mask %s (the mask has %d)", index, maskId, #before))
    end
    local previousIndex = readSelectedIndex()
    MaskSelection.refuseUnlessSelected(maskId)
    callController("the Point Color swatch deletion", "deletePointColorSwatch", false, index, FOR_MASKING)
    if not waitForCount(#before - 1) then
        error(string.format("Lightroom did not delete swatch %d of mask %s", index, maskId), 0)
    end

    local expected = copyList(before)
    table.remove(expected, index)
    confirmPersisted(expected, maskId, string.format("the deletion of swatch %d", index))
    local newPrevious = previousIndex
    if previousIndex and previousIndex > index then newPrevious = previousIndex - 1 end
    restoreSelection(newPrevious, #expected)
    return { index = index, changed = true }
end

local function clearSwatches(_, maskId)
    local before = readSwatches()
    if #before == 0 then return { changed = false } end
    MaskSelection.refuseUnlessSelected(maskId)
    callController("clearing the Point Color swatches", "deletePointColorSwatch", true, 1, FOR_MASKING)
    if not waitForCount(0) then
        error("Lightroom did not clear the Point Color swatches of mask " .. maskId, 0)
    end
    confirmPersisted({}, maskId, "the cleared Point Color swatches")
    return { changed = true }
end

local EDIT = {
    add = addSwatch,
    update = updateSwatch,
    delete = deleteSwatch,
    clear = clearSwatches,
}

function MaskPointColorsHandler.editMaskPointColors(args, context)
    local maskId = args.mask_id
    local request = { action = args.action, swatch = args.swatch, index = args.index }
    requireSupport("edit_mask_point_colors", EDIT_CONTROLLER_FUNCTIONS)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)

    local outcome = DevelopSession.withPhoto(context, catalog, photo, function()
        return MaskSelection.withMaskSelected(catalog, photo, maskId, function()
            local result = EDIT[request.action](request, maskId)
            result.swatches = MaskPointColors.indexed(readSwatches())
            return result
        end)
    end)

    Log.info(string.format("Point Color %s on mask %s of photo %s: %d swatches now",
        request.action, maskId, photoId, #outcome.swatches))

    return {
        photo_id = photoId,
        mask_id = maskId,
        action = request.action,
        index = outcome.index,
        changed = outcome.changed,
        swatches = outcome.swatches,
    }
end

function MaskPointColorsHandler.readSelected()
    return { swatches = MaskPointColors.indexed(readSwatches()) }
end

return MaskPointColorsHandler
