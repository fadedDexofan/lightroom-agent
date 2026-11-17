local helper = require 'spec_helper'

local function setup()
    local photos = {
        helper.fakePhoto({ id = "1", path = "/1.jpg" }),
        helper.fakePhoto({ id = "2", path = "/2.jpg" }),
        helper.fakePhoto({ id = "3", path = "/3.jpg" }),
        helper.fakePhoto({ id = "4", path = "/4.jpg" }),
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
    it("files a photo under failed when nothing was written for it and under unknown when something was", function()
        local DevelopBatch, catalog = setup()
        local Reply = require 'Reply'
        local context = helper.requestContext()

        local reply = DevelopBatch.run(context, catalog, {
            inputs = { "1", "2", "3", "4" },
            reserveSeconds = 0,
            each = function(photo)
                if photo.localIdentifier == "1" then Reply.refuse("nothing to change") end
                if photo.localIdentifier == "2" then error("write rejected") end
                if photo.localIdentifier == "3" then
                    context.ledger:record("setValue", true)
                    Reply.refuse("the value did not read back")
                end
                return { status = "done" }
            end,
        })

        assert.are.same({ { photo_id = "1", reason = "nothing to change" }, { photo_id = "2", reason = "write rejected" } },
            reply.failed)
        assert.are.same({ { photo_id = "3", reason = "the value did not read back; written before this stopped: setValue" } },
            reply.unknown)
        assert.are.same({ { status = "done", photo_id = "4" } }, reply.data.results)
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
