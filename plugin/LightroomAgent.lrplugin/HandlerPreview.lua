local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
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
local NO_PIXELS_ANSWER = "error loading thumb"
local NO_PIXELS_RETRY_SECONDS = 1
local OPEN_IN_DEVELOP = "active_in_develop"

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

local function isNoPixels(failure)
    return type(failure) == "string" and failure:find(NO_PIXELS_ANSWER, 1, true) ~= nil
end

local function stillNoPixels(photo)
    return string.format("Lightroom still had no preview pixels for photo %s (it answered \"%s\" until the time ran"
        .. " out); ask again later", tostring(photo.localIdentifier), NO_PIXELS_ANSWER)
end

local function openInDevelop(photo)
    return LrApplicationView.getCurrentModuleName() == "develop"
        and LrApplication.activeCatalog():getTargetPhoto() == photo
end

local function declineOpenInDevelop(photo)
    if not openInDevelop(photo) then return end
    Reply.refuse(string.format("This tool takes no thumbnail of photo %s while it is the photo open in Develop:"
        .. " Lightroom's thumbnail there can be stale or an enlarged low-resolution copy", tostring(photo.localIdentifier)),
        OPEN_IN_DEVELOP)
end

local function thumbnailOf(photo, size, deadline)
    local answeredNoPixels = false
    local done, data, failure
    while true do
        declineOpenInDevelop(photo)
        done, data, failure = requestThumbnail(photo, size, deadline)
        if data then break end
        if not done and answeredNoPixels then error(stillNoPixels(photo), 0) end
        if not done then error("Preview not ready before the request's time ran out", 0) end
        if not isNoPixels(failure) then error("Preview failed: " .. tostring(failure or "no image data"), 0) end
        answeredNoPixels = true
        if LrDate.currentTime() + NO_PIXELS_RETRY_SECONDS >= deadline then error(stillNoPixels(photo), 0) end
        LrTasks.sleep(NO_PIXELS_RETRY_SECONDS)
    end
    return data
end

local function previewOf(photo, data)
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

local function preview(photo, args, deadline)
    return previewOf(photo, thumbnailOf(photo, args.size, deadline))
end

local function duplicatePreview(photo, _, deadline)
    local captureTime
    LrApplication.activeCatalog():withReadAccessDo(function()
        captureTime = photo:getRawMetadata("dateTimeOriginal")
    end)
    if type(captureTime) ~= "number" then error("No raw capture time", 0) end
    local result = previewOf(photo, thumbnailOf(photo, DUPLICATE_SIZE, deadline))
    result.capture_time = captureTime
    return result
end

local function onePhoto(render, args, context)
    local input = args.photo_ids[1]
    local photo = PhotoLookup.resolveOne(LrApplication.activeCatalog(), input)
    if not photo then return Reply.parts({ not_found = { input } }) end
    local ok, value = LrTasks.pcall(render, photo, args, deadlineOf(context))
    if ok then return Reply.parts({ data = value }) end
    return Reply.parts({ failed = { {
        photo_id = tostring(photo.localIdentifier), reason = Reply.messageOf(value), cause = Reply.causeOf(value),
    } } })
end

function PreviewHandler.renderPreview(args, context)
    return onePhoto(preview, args, context)
end

function PreviewHandler.renderDuplicatePreview(args, context)
    return onePhoto(duplicatePreview, args, context)
end

return PreviewHandler
