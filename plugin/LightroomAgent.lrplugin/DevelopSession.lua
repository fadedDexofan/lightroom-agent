local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrSelection = import 'LrSelection'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local PhotoSources = require 'PhotoSources'
local Reply = require 'Reply'

local DevelopSession = {}

local SELECT_TIMEOUT_SECONDS = 10
local FIRST_TRY_SECONDS = 2
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local PHOTO_SETTLE_SECONDS = 0.5


local runningTool = nil

function DevelopSession.waitFor(predicate, timeoutSeconds)
    local waited = 0
    while waited < timeoutSeconds do
        if predicate() then return true end
        LrTasks.sleep(POLL_SECONDS)
        waited = waited + POLL_SECONDS
    end
    return predicate()
end

function DevelopSession.retryUntil(done, action, timeoutSeconds, intervalSeconds)
    intervalSeconds = intervalSeconds or RESELECT_SECONDS
    local sinceAction = intervalSeconds
    local reached = DevelopSession.waitFor(function()
        if done() then return true end
        if sinceAction >= intervalSeconds then
            action()
            sinceAction = 0
        end
        sinceAction = sinceAction + POLL_SECONDS
        return false
    end, timeoutSeconds or SELECT_TIMEOUT_SECONDS)
    -- the closing poll may fire one last action, so judge its result
    return reached or done()
end

local retryUntil = DevelopSession.retryUntil

function DevelopSession.selectionMatches(catalog, photo, selection)
    if catalog:getTargetPhoto() ~= photo then return false end
    local expected = {}
    for _, selected in ipairs(selection or { photo }) do expected[selected] = true end
    for _, selected in ipairs(catalog:getTargetPhotos() or {}) do
        if not expected[selected] then return false end
        expected[selected] = nil
    end
    return next(expected) == nil
end

function DevelopSession.selectExactly(catalog, photo, selection, timeoutSeconds, intervalSeconds)
    return retryUntil(
        function() return DevelopSession.selectionMatches(catalog, photo, selection) end,
        function() catalog:setSelectedPhotos(photo, selection) end,
        timeoutSeconds, intervalSeconds)
end

local function selectNoneAndWait(catalog)
    local quietChecks = 0
    return retryUntil(function()
        quietChecks = catalog:getTargetPhoto() == nil and quietChecks + 1 or 0
        return quietChecks >= RESELECT_SECONDS / POLL_SECONDS + 1
    end, function() LrSelection.selectNone() end)
end

local function switchTo(catalog, state, step, sources, photo)
    state.switchedSource = true
    Log.info(string.format("Showing photo %s through %s", tostring(photo.localIdentifier), step))
    return PhotoSources.show(catalog, sources)
end

local function withSourceFallback(catalog, photo, state, select)
    if state.allPhotos then return select(SELECT_TIMEOUT_SECONDS) end
    if select(FIRST_TRY_SECONDS) then return true end
    if not state.folder then
        local folders = PhotoSources.foldersOf(catalog, { photo })
        if folders then
            state.folder = true
            if switchTo(catalog, state, "its folder", folders, photo) and select(SELECT_TIMEOUT_SECONDS) then return true end
        end
    end
    if not switchTo(catalog, state, "All Photographs", { catalog.kAllPhotos }, photo) then return false end
    state.allPhotos = true
    return select(SELECT_TIMEOUT_SECONDS)
end

function DevelopSession.selectAlone(catalog, photo, state)
    return withSourceFallback(catalog, photo, state, function(timeoutSeconds)
        return DevelopSession.selectExactly(catalog, photo, { photo }, timeoutSeconds)
    end)
end

local function captureView(catalog)
    local active = catalog:getTargetPhoto()
    return {
        module = LrApplicationView.getCurrentModuleName(),
        sources = catalog:getActiveSources(),
        active = active,
        selection = active and catalog:getTargetPhotos() or nil,
    }
end

local function restoreView(catalog, view, state)
    local problems = {}
    if view.module ~= LrApplicationView.getCurrentModuleName() then
        LrTasks.pcall(function() LrApplicationView.switchToModule(view.module) end)
        if view.module ~= LrApplicationView.getCurrentModuleName() then
            problems[#problems + 1] = "the " .. tostring(view.module) .. " module was not reopened"
        end
    end
    if state.switchedSource and view.sources and not PhotoSources.show(catalog, view.sources) then
        problems[#problems + 1] = "the previous source was not reopened"
    end
    if view.active then
        local ok, restored = LrTasks.pcall(DevelopSession.selectExactly, catalog, view.active, view.selection)
        if not (ok and restored) then problems[#problems + 1] = "the previous selection was not restored" end
    else
        local ok, cleared = LrTasks.pcall(selectNoneAndWait, catalog)
        if not (ok and cleared) then problems[#problems + 1] = "the selection was not cleared" end
    end
    return problems
end

local function developModuleShowing()
    return LrApplicationView.getCurrentModuleName() == "develop"
end

function DevelopSession.openDevelop(isReady)
    if not developModuleShowing() then
        LrApplicationView.switchToModule("develop")
    end
    if not DevelopSession.waitFor(isReady or developModuleShowing, SELECT_TIMEOUT_SECONDS) then
        Reply.refuse("Develop module did not open")
    end
end

function DevelopSession.commitPendingEdits()
    if developModuleShowing() then LrTasks.pcall(LrDevelopController.stopTracking, true) end
end

function DevelopSession.releaseTracking()
    return LrDevelopController.stopTracking(false)
end

local function runBody(context, catalog, restore, body)
    local state = {}
    local view
    local mark = context.ledger:mark()
    local ok, result = LrTasks.pcall(function()
        if restore then view = captureView(catalog) end
        return body(state)
    end)
    if context.ledger:controllerWroteSince(mark) then DevelopSession.commitPendingEdits() end
    if view then
        local restored, problems = LrTasks.pcall(restoreView, catalog, view, state)
        if not restored then problems = { tostring(problems) } end
        if #problems > 0 then
            local warning = context.title .. " could not restore the view: " .. table.concat(problems, "; ")
            Log.warn(warning)
            context:warn(warning)
        end
    end
    if not ok then error(result, 0) end
    return result
end

function DevelopSession.run(context, catalog, restore, body)
    if runningTool then
        Reply.refuse(runningTool .. " is already running; wait for it to finish, then call again")
    end
    runningTool = context.title
    local ok, result = LrTasks.pcall(runBody, context, catalog, restore, body)
    runningTool = nil
    if not ok then error(result, 0) end
    return result
end

function DevelopSession.openPhoto(catalog, photo, state)
    DevelopSession.openDevelop()
    if not DevelopSession.selectAlone(catalog, photo, state) then
        Reply.refuse("Could not open photo " .. tostring(photo.localIdentifier) .. " in Develop")
    end
    LrTasks.sleep(PHOTO_SETTLE_SECONDS)
    if catalog:getTargetPhoto() ~= photo then
        Reply.refuse("Another photo became active in Develop while opening photo "
            .. tostring(photo.localIdentifier))
    end
end

function DevelopSession.withPhoto(context, catalog, photo, fn)
    return DevelopSession.run(context, catalog, true, function(state)
        DevelopSession.openPhoto(catalog, photo, state)
        return fn()
    end)
end

function DevelopSession.requireControllerFunctions(toolName, names)
    for _, name in ipairs(names) do
        if type(LrDevelopController[name]) ~= "function" then
            Reply.refuse(string.format("%s needs LrDevelopController.%s, a function outside the Lightroom SDK that"
                .. " this Lightroom does not offer", toolName, name))
        end
    end
end

return DevelopSession
