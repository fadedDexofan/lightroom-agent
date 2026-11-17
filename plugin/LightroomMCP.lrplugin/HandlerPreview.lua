local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import 'LrTasks'

local Contract = require 'Contract'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'
local Reply = require 'Reply'

local PreviewHandler = {}

local DUPLICATE_SIZE = 64
local REPLY_RESERVE_SECONDS = Contract.PREVIEW_REPLY_RESERVE_SECONDS
local POLL_SECONDS = 0.05
local REBUILDING_ERROR = "error loading thumb"
local REBUILD_RETRY_SECONDS = 1

local function deadlineOf(context)
    if context and context.deadline then return context.deadline - REPLY_RESERVE_SECONDS end
    return math.huge
end

local function requestThumbnail(photo, size, deadline)
    -- requestJpegThumbnail is asynchronous and may call back before it
    -- returns. The request object must stay referenced until the callback
    -- fires, or Lightroom can cancel it.
    local done, data, failure = false, nil, nil
    local request = photo:requestJpegThumbnail(size, size, function(jpegData, errorMessage)
        if done then return end
        done, data, failure = true, jpegData, errorMessage
    end)

    -- Reading `request` each pass is what keeps it alive while we wait.
    while request and not done and LrDate.currentTime() < deadline do
        LrTasks.sleep(POLL_SECONDS)
    end
    return done, data, failure
end

local function isRebuilding(failure)
    return type(failure) == "string" and failure:find(REBUILDING_ERROR, 1, true) ~= nil
end

local function stillRebuilding(photo)
    return string.format("Lightroom is still rebuilding the preview of photo %s after a change (it answered \"%s\""
        .. " until the time ran out); ask again in a few seconds", tostring(photo.localIdentifier), REBUILDING_ERROR)
end

local function renderPhoto(photo, size, deadline)
    local rebuilding = false
    local done, data, failure
    while true do
        done, data, failure = requestThumbnail(photo, size, deadline)
        if data then break end
        if not done and rebuilding then error(stillRebuilding(photo), 0) end
        if not done then error("Preview not ready before the request's time ran out", 0) end
        if not isRebuilding(failure) then error("Preview failed: " .. tostring(failure or "no image data"), 0) end
        rebuilding = true
        if LrDate.currentTime() + REBUILD_RETRY_SECONDS >= deadline then error(stillRebuilding(photo), 0) end
        LrTasks.sleep(REBUILD_RETRY_SECONDS)
    end

    local photoId = tostring(photo.localIdentifier)
    Log.info(string.format("Rendered preview for photo %s (%d bytes)", photoId, #data))
    return {
        photo_id = photoId,
        image = {
            mime_type = "image/jpeg",
            data = LrStringUtils.encodeBase64(data),
        },
    }
end

local function onePhoto(input, render)
    local photo = PhotoLookup.resolveOne(LrApplication.activeCatalog(), input)
    if not photo then return Reply.parts({ not_found = { input } }) end
    local ok, value = LrTasks.pcall(render, photo)
    if ok then return Reply.parts({ data = value }) end
    return Reply.parts({ failed = { { photo_id = tostring(photo.localIdentifier), reason = Reply.messageOf(value) } } })
end

function PreviewHandler.renderPreview(args, context)
    return onePhoto(args.photo_ids[1], function(photo)
        return renderPhoto(photo, args.size, deadlineOf(context))
    end)
end

function PreviewHandler.renderDuplicatePreview(args, context)
    local catalog = LrApplication.activeCatalog()
    return onePhoto(args.photo_ids[1], function(photo)
        local captureTime
        catalog:withReadAccessDo(function()
            captureTime = photo:getRawMetadata("dateTimeOriginal")
        end)
        if type(captureTime) ~= "number" then error("No raw capture time", 0) end
        local result = renderPhoto(photo, DUPLICATE_SIZE, deadlineOf(context))
        result.capture_time = captureTime
        return result
    end)
end

return PreviewHandler
