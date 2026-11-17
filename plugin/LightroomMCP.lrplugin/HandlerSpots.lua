local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local CatalogWrite = require 'CatalogWrite'
local DevelopSession = require 'DevelopSession'
local JsonValue = require 'JsonValue'
local MaskSelection = require 'MaskSelection'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local HandlerSpots = {}
local REQUIRED = { 'getAllSpots', 'getSelectedTool', 'selectTool', 'goToRemove',
    'setSelectedSpotIndex', 'getSelectedSpotIndex', 'getSelectedSpotParams',
    'setSelectedSpotParams', 'deleteSelectedSpot' }

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function requireApi(name)
    local version = LrApplication.versionTable()
    if version.major < 14 or (version.major == 14 and version.minor < 1) then
        Reply.refuse(name .. ' needs Lightroom Classic 14.1 or later')
    end
    DevelopSession.requireControllerFunctions(name, REQUIRED, 'Lightroom Classic 14.1')
end

local function readSpots()
    local spots = LrDevelopController.getAllSpots()
    if type(spots) ~= 'table' then error('Lightroom could not read the spots') end
    return copy(spots)
end

local function indexed(spots)
    local result = {}
    for index, params in ipairs(spots) do result[index] = { index = index, params = JsonValue.of(params) } end
    return result
end

local function requireIndex(index, count)
    if index > count then
        Reply.refuse(string.format('Spot index %s is invalid; valid range: %s', tostring(index),
            count == 0 and 'empty (no spots)' or '1..' .. tostring(count)))
    end
end

local function withPhoto(context, args, body)
    requireApi(context.title)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local result = DevelopSession.withPhoto(context, catalog, photo, body)
    result.photo_id = tostring(photo.localIdentifier)
    return result
end

local function withSelected(context, index, body)
    local previousTool = MaskSelection.selectableTool(LrDevelopController.getSelectedTool())
    local previousIndex
    if previousTool == 'dust' then previousIndex = LrDevelopController.getSelectedSpotIndex() end
    local ok, result = LrTasks.pcall(function()
        if previousTool ~= 'dust' then
            LrDevelopController.goToRemove()
            if not DevelopSession.waitFor(function()
                return LrDevelopController.getSelectedTool() == 'dust'
            end, 5) then Reply.refuse('Lightroom did not open Remove') end
        end
        local spots = readSpots()
        requireIndex(index, #spots)
        local selected, message = LrDevelopController.setSelectedSpotIndex(index)
        if selected ~= true or LrDevelopController.getSelectedSpotIndex() ~= index then
            Reply.refuse(string.format('Could not select spot %d; valid range: 1..%d (%s)',
                index, #spots, tostring(message)))
        end
        return body(spots)
    end)
    local restored, restoreError = LrTasks.pcall(function()
        if previousTool == 'dust' and previousIndex then
            local count = #readSpots()
            if previousIndex <= count then LrDevelopController.setSelectedSpotIndex(previousIndex) end
        elseif previousTool ~= 'dust' then
            LrDevelopController.selectTool(previousTool)
            if not DevelopSession.waitFor(function()
                return MaskSelection.selectableTool(LrDevelopController.getSelectedTool()) == previousTool
            end, 5) then error('Lightroom did not restore tool ' .. tostring(previousTool)) end
        end
    end)
    local restoreProblem = not restored and ('Could not restore Remove tool state: ' .. Reply.messageOf(restoreError))
    if not ok then
        if not restoreProblem then error(result, 0) end
        error(Reply.messageOf(result) .. '; ' .. restoreProblem, 0)
    end
    if restoreProblem then context:warn(restoreProblem) end
    return result
end

function HandlerSpots.list(args, context)
    return withPhoto(context, args, function()
        local spots = readSpots()
        return { count = #spots, spots = indexed(spots) }
    end)
end

local function problemWithOtherSpots(before, index)
    local after = readSpots()
    if #after ~= #before then return 'Lightroom changed the spot count' end
    for otherIndex, spot in ipairs(before) do
        if otherIndex ~= index and not JsonValue.equal(spot, after[otherIndex]) then
            return 'Lightroom changed another spot'
        end
    end
    return nil
end

function HandlerSpots.update(args, context)
    local params = args.params
    return withPhoto(context, args, function()
        return withSelected(context, args.index, function(before)
            local original = copy(LrDevelopController.getSelectedSpotParams())
            if type(original) ~= 'table' or original.SpotType ~= 'heal'
                or type(original.Opacity) ~= 'number' then
                Reply.refuse('Opacity editing is supported only for Heal spots with readable parameters')
            end
            if original.Opacity == params.Opacity then
                return { index = args.index, changed = false, params = original }
            end
            local desired = copy(original)
            desired.Opacity = params.Opacity
            local opacityKept = false
            local ok, err = LrTasks.pcall(function()
                CatalogWrite.develop(context, "setSelectedSpotParams", desired)
                if not DevelopSession.waitFor(function()
                    local current = LrDevelopController.getSelectedSpotParams()
                    return type(current) == 'table' and current.Opacity == params.Opacity
                end, 5) then error('Lightroom did not keep Opacity') end
                opacityKept = true
                local problem = problemWithOtherSpots(before, args.index)
                if problem then error(problem) end
            end)
            if not ok and opacityKept then
                error(Reply.messageOf(err) .. ' after the Opacity write landed, so nothing was written back;'
                    .. ' list_spots to inspect', 0)
            end
            if not ok then
                local rolledBack, confirmed = LrTasks.pcall(function()
                    if LrDevelopController.setSelectedSpotIndex(args.index) ~= true then
                        error('Original spot is no longer selectable')
                    end
                    CatalogWrite.develop(context, "setSelectedSpotParams", original)
                    return DevelopSession.waitFor(function()
                        return JsonValue.equal(LrDevelopController.getSelectedSpotParams(), original)
                    end, 5)
                end)
                if rolledBack and confirmed then
                    local problem = problemWithOtherSpots(before, args.index)
                    if problem then
                        error(Reply.messageOf(err) .. '; original parameters restored, but ' .. problem
                            .. '; list_spots to inspect', 0)
                    end
                    error(Reply.messageOf(err) .. '; original parameters restored', 0)
                end
                error(Reply.messageOf(err) .. '; rollback not confirmed; list_spots to inspect', 0)
            end
            return { index = args.index, changed = true,
                params = JsonValue.of(LrDevelopController.getSelectedSpotParams()) }
        end)
    end)
end

function HandlerSpots.delete(args, context)
    return withPhoto(context, args, function()
        return withSelected(context, args.index, function(before)
            CatalogWrite.develop(context, "deleteSelectedSpot")
            local after
            if not DevelopSession.waitFor(function()
                after = readSpots()
                return #after == #before - 1
            end, 5) then error('Lightroom did not delete the spot; list_spots to inspect') end
            local expected = copy(before)
            table.remove(expected, args.index)
            if not JsonValue.equal(expected, after) then error('Other spots changed during deletion; list_spots to inspect') end
            return { deleted_index = args.index, count = #after, spots = indexed(after) }
        end)
    end)
end

return HandlerSpots
