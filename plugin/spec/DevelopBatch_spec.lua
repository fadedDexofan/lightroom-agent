local helper = require 'spec_helper'

local function setup()
    local photos = {
        helper.fakePhoto({ id = "1", path = "/1.jpg" }),
        helper.fakePhoto({ id = "2", path = "/2.jpg" }),
        helper.fakePhoto({ id = "3", path = "/3.jpg" }),
    }
    local catalog = helper.fakeCatalog({ photos = photos })
    helper.installImport({
        LrApplicationView = { getCurrentModuleName = function() return "library" end, switchToModule = function() end },
        LrDevelopController = {},
        LrSelection = { selectNone = function() end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.DevelopBatch = nil
    return require 'DevelopBatch', catalog
end

local function idsOf(photosSeen)
    local ids = {}
    for _, photo in ipairs(photosSeen) do ids[#ids + 1] = tostring(photo.localIdentifier) end
    return ids
end

describe("DevelopBatch.run", function()
    it("stops the batch at a halt: that photo failed, the rest remaining, its reason a warning", function()
        local DevelopBatch, catalog = setup()
        local context = helper.requestContext()
        local seen = {}

        local reply = DevelopBatch.run(context, catalog, {
            inputs = { "1", "2", "3" },
            reserveSeconds = 0,
            each = function(photo)
                seen[#seen + 1] = photo
                if photo.localIdentifier == "2" then DevelopBatch.halt("No subject detected; click OK in Lightroom") end
                return { status = "created" }
            end,
        })

        assert.are.same({ "1", "2" }, idsOf(seen))
        assert.are.same({ { status = "created", photo_id = "1" } }, reply.data.results)
        assert.are.same({ { photo_id = "2", reason = "No subject detected; click OK in Lightroom" } }, reply.failed)
        assert.are.same({ "3" }, reply.remaining)
        assert.are.same({ "No subject detected; click OK in Lightroom" }, context.warnings)
    end)

    it("files a refusal under failed and any other error under unknown, without the source location", function()
        local DevelopBatch, catalog = setup()
        local Reply = require 'Reply'

        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2", "3" },
            reserveSeconds = 0,
            each = function(photo)
                if photo.localIdentifier == "1" then Reply.refuse("nothing to change") end
                if photo.localIdentifier == "2" then error("write rejected") end
                return { status = "done" }
            end,
        })

        assert.are.same({ { photo_id = "1", reason = "nothing to change" } }, reply.failed)
        assert.are.same({ { photo_id = "2", reason = "write rejected" } }, reply.unknown)
        assert.are.same({ { status = "done", photo_id = "3" } }, reply.data.results)
    end)

    it("prepares once, and only when a photo is attempted", function()
        local DevelopBatch, catalog = setup()
        local prepared = 0
        local operation = {
            inputs = { "1", "2" },
            reserveSeconds = 60,
            prepare = function() prepared = prepared + 1 end,
            each = function() return { status = "done" } end,
        }

        DevelopBatch.run(helper.requestContext(30), catalog, operation)
        assert.are.equal(0, prepared)

        DevelopBatch.run(helper.requestContext(), catalog, operation)
        assert.are.equal(1, prepared)
    end)
end)
