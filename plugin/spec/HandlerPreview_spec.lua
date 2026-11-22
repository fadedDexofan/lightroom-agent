local helper = require 'spec_helper'

-- thumbnail(photo, w, h, callback) stands in for Lightroom's renderer: it may
-- call back at once, keep the callback for later, or never call it.
local function previewPhoto(meta, thumbnail)
    local photo = helper.fakePhoto(meta)
    photo.requestJpegThumbnail = function(self, w, h, callback)
        meta.__requested = { w, h }
        thumbnail(self, w, h, callback)
        return { request = true }
    end
    return photo
end

local function setup(photos, onSleep, view)
    view = view or {}
    local catalog = helper.fakeCatalog({ photos = photos or {} })
    catalog.getTargetPhoto = function() return view.target end
    -- now is a fake clock: each sleep advances it, and tests can jump it.
    local sleeps = { count = 0, now = 0 }
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = { getCurrentModuleName = function() return view.module or "library" end },
        LrExportSession = function() error("a thumbnail preview must not export", 0) end,
        LrDate = { currentTime = function() return sleeps.now end },
        LrLogger = helper.defaultLrLogger(),
        LrStringUtils = { encodeBase64 = function(s) return "b64(" .. s .. ")" end },
        LrTasks = {
            pcall = pcall,
            sleep = function(seconds)
                sleeps.count = sleeps.count + 1
                sleeps.now = sleeps.now + seconds
                if onSleep then onSleep(sleeps.count) end
            end,
        },
    })
    package.loaded.HandlerPreview = nil
    return catalog, require 'HandlerPreview', sleeps
end

describe("HandlerPreview.renderPreview", function()
    it("reads duplicate capture seconds raw and opens no write gate", function()
        local meta = { id = "1", path = "/a.nef", dateTimeOriginal = 12345 }
        local photo = previewPhoto(meta, function(_, _, _, cb) cb("JPEGDATA") end)
        photo.getFormattedMetadata = function() error("formatted capture time must not be read") end
        local catalog, Handler = setup({ photo })
        catalog.withWriteAccessDo = function() error("duplicate grouping must not write") end
        local first = Handler.renderDuplicatePreview({ photo_ids = { "1" } }).data
        photo.getRawMetadata = function(_, key)
            if key == "dateTimeOriginal" then return 12346 end
            if key == "uuid" then return "uuid-1" end
        end
        local second = Handler.renderDuplicatePreview({ photo_ids = { "1" } }).data
        assert.are.equal(1, second.capture_time - first.capture_time)
        assert.are.same({ 64, 64 }, meta.__requested)
    end)

    it("answers a duplicate-group preview of an unknown photo with not_found and one without capture time as failed", function()
        local photo = previewPhoto({ localIdentifier = 7, path = "/a.nef" }, function(_, _, _, cb) cb("JPEGDATA") end)
        local _, Handler = setup({ photo })

        assert.are.same({ "9" }, Handler.renderDuplicatePreview({ photo_ids = { "9" } }).not_found)
        assert.are.same({ { photo_id = "7", reason = "No raw capture time" } },
            Handler.renderDuplicatePreview({ photo_ids = { 7 } }).failed)
    end)

    it("returns the rendered JPEG base64-encoded with its mime type at the requested edge", function()
        local meta = { id = "1", path = "/a.nef" }
        local photo = previewPhoto(meta, function(_, _, _, cb) cb("JPEGDATA") end)
        local _, Handler, sleeps = setup({ photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 700 })

        assert.are.same({ photo_id = "1", image = { mime_type = "image/jpeg", data = "b64(JPEGDATA)" } }, reply.data)
        assert.are.same({ 700, 700 }, meta.__requested)
        assert.are.equal(0, sleeps.count)
    end)

    it("hands an image of any size to the server from one request", function()
        local big = string.rep("x", 9047577)
        local edges = {}
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, w, _, cb)
            edges[#edges + 1] = w
            cb(big)
        end)
        local _, Handler = setup({ photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 64 })

        assert.are.equal("b64(" .. big .. ")", reply.data.image.data)
        assert.are.same({ 64 }, edges)
    end)

    it("waits for a callback that arrives after the request returns", function()
        local pending
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb) pending = cb end)
        local _, Handler, sleeps = setup({ photo }, function(n)
            if n == 3 then pending("LATE") end
        end)

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 })

        assert.are.equal("b64(LATE)", reply.data.image.data)
        assert.are.equal(3, sleeps.count)
    end)

    it("keeps the first image when Lightroom calls back twice", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb)
            cb("FIRST")
            cb("SECOND")
        end)
        local _, Handler = setup({ photo })

        assert.are.equal("b64(FIRST)", Handler.renderPreview({ photo_ids = { "1" }, size = 512 }).data.image.data)
    end)

    it("reports any other renderer error as failed at once, instead of an empty image", function()
        local requests = 0
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb)
            requests = requests + 1
            cb(nil, "file is offline")
        end)
        local _, Handler = setup({ photo })

        assert.are.same({ { photo_id = "1", reason = "Preview failed: file is offline" } },
            Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30)).failed)
        assert.are.equal(1, requests)
    end)

    it("asks again while Lightroom answers that it has no preview pixels, and returns the first good render", function()
        local requests = 0
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            if requests < 3 then cb(nil, "error loading thumb") else cb("JPEGDATA") end
        end)
        local _, Handler = setup({ photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.are.equal("b64(JPEGDATA)", reply.data.image.data)
        assert.are.equal(3, requests)
    end)

    for _, case in ipairs({
        { "preview", function(Handler) return Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30)) end },
        { "duplicate preview", function(Handler)
            return Handler.renderDuplicatePreview({ photo_ids = { "1" } }, helper.requestContext(30))
        end },
    }) do
        it("asks Lightroom for no " .. case[1] .. " of the photo open in Develop, even one it could hand over", function()
            local requests = 0
            local photo = previewPhoto({ id = "1", path = "/a.arw", dateTimeOriginal = 5 }, function(_, _, _, cb)
                requests = requests + 1
                cb("CACHED")
            end)
            local _, Handler, sleeps = setup({ photo }, nil, { module = "develop", target = photo })

            local reply = case[2](Handler)

            assert.are.same({ {
                photo_id = "1",
                reason = "This tool takes no thumbnail of photo 1 while it is the photo open in Develop: Lightroom's thumbnail there"
                    .. " can be stale or an enlarged low-resolution copy",
                cause = "active_in_develop",
            } }, reply.failed)
            assert.are.equal(0, requests)
            assert.are.equal(0, sleeps.count)
        end)
    end

    it("stops asking once the photo becomes the one open in Develop between retries", function()
        local requests = 0
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            cb(nil, "error loading thumb")
        end)
        local view = { module = "library", target = photo }
        local _, Handler = setup({ photo }, function() view.module = "develop" end, view)

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.are.equal("active_in_develop", reply.failed[1].cause)
        assert.are.equal(1, requests)
    end)

    it("asks again for a photo that is not the one open in Develop, even while Develop is showing", function()
        local requests = 0
        local other = helper.fakePhoto({ id = "2", path = "/b.arw" })
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            if requests < 3 then cb(nil, "error loading thumb") else cb("JPEGDATA") end
        end)
        local _, Handler = setup({ photo, other }, nil, { module = "develop", target = other })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.are.equal("b64(JPEGDATA)", reply.data.image.data)
        assert.are.equal(3, requests)
    end)

    it("asks again for the Develop target while Lightroom shows Library", function()
        local requests = 0
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            if requests < 3 then cb(nil, "error loading thumb") else cb("JPEGDATA") end
        end)
        local _, Handler = setup({ photo }, nil, { module = "library", target = photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.are.equal("b64(JPEGDATA)", reply.data.image.data)
        assert.are.equal(3, requests)
    end)

    it("answers failed, saying Lightroom still had no preview pixels, when no render succeeds within the time", function()
        local requests, context = 0, nil
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            if context:timeLeft() < 10 then error("asked again inside the reply reserve", 0) end
            cb(nil, "error loading thumb")
        end)
        local _, Handler = setup({ photo })
        context = helper.requestContext(30)

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, context)

        assert.are.equal("Lightroom still had no preview pixels for photo 1 (it answered \"error loading thumb\" until"
            .. " the time ran out); ask again later",
            reply.failed[1].reason)
        assert.is_true(requests > 1)
        assert.is_true(context:timeLeft() >= 10)
    end)

    it("says Lightroom still had no preview pixels when a retry after that answer never calls back", function()
        local requests = 0
        local photo = previewPhoto({ id = "1", path = "/a.arw" }, function(_, _, _, cb)
            requests = requests + 1
            if requests == 1 then cb(nil, "error loading thumb") end
        end)
        local _, Handler = setup({ photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.matches("Lightroom still had no preview pixels for photo 1", reply.failed[1].reason, 1, true)
        assert.are.equal(2, requests)
    end)

    it("gives up when Lightroom never calls back, leaving the reply reserve", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function() end)
        local _, Handler, sleeps = setup({ photo })
        local context = helper.requestContext(30)

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, context)

        assert.are.equal("Preview not ready before the request's time ran out", reply.failed[1].reason)
        assert.is_true(sleeps.count >= 400)
        assert.is_true(context:timeLeft() >= 10 - 0.05)
    end)

    it("counts time outside the sleeps against the deadline", function()
        local sleeps
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function()
            sleeps.now = sleeps.now + 19.99
        end)
        local _, Handler
        _, Handler, sleeps = setup({ photo })

        local reply = Handler.renderPreview({ photo_ids = { "1" }, size = 512 }, helper.requestContext(30))

        assert.are.equal("Preview not ready before the request's time ran out", reply.failed[1].reason)
        assert.is_true(sleeps.count <= 1)
    end)

    it("answers an unknown photo with not_found", function()
        local _, Handler = setup({})

        local reply = Handler.renderPreview({ photo_ids = { "missing" }, size = 512 })

        assert.is_nil(reply.data)
        assert.are.same({ "missing" }, reply.not_found)
    end)

    it("names the photo by its string id", function()
        local photo = previewPhoto({ localIdentifier = 7, path = "/a.nef" }, function(_, _, _, cb) cb("JPEGDATA") end)
        local _, Handler = setup({ photo })

        assert.are.equal("7", Handler.renderPreview({ photo_ids = { "/a.nef" }, size = 512 }).data.photo_id)
    end)
end)
