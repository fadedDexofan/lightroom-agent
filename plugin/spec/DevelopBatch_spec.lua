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

    it("refuses every input of a photo listed twice, by id and by path, refused on a rule or not, and writes the rest", function()
        local DevelopBatch, catalog = setup()
        local seen = {}
        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/1.jpg", "2", "/3.jpg", "3", "4" },
            duplicates = "refuse",
            held = function(entry) if entry.index == 4 or entry.index == 6 then return { reason = "Refused before writing: rule" } end end,
            reserveSeconds = 0,
            each = function(photo, _, entry)
                seen[#seen + 1] = tostring(photo.localIdentifier) .. "@" .. entry.index
                return {}
            end,
        })

        assert.are.same({ "2@3" }, seen)
        assert.are.same({
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is 1" },
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is /1.jpg" },
            { photo_id = "3", reason = "listed twice, as /3.jpg and 3; this is /3.jpg" },
            { photo_id = "3", reason = "listed twice, as /3.jpg and 3; this is 3" },
            { photo_id = "4", reason = "Refused before writing: rule" },
        }, reply.failed)
    end)

    it("refuses both inputs of a photo listed twice even when the caller holds one of them back", function()
        local DevelopBatch, catalog = setup()
        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/1.jpg", "2" },
            duplicates = "refuse",
            held = function(entry) if entry.index == 2 then return { remaining = true } end end,
            reserveSeconds = 0,
            each = function() return {} end,
        })

        assert.are.same({
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is 1" },
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is /1.jpg" },
        }, reply.failed)
        assert.is_nil(reply.remaining)
    end)

    it("lists an input the caller holds back as remaining, by the input as given, without attempting it", function()
        local DevelopBatch, catalog = setup()
        local seen = {}
        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/2.jpg", "3" },
            held = function(entry) if entry.index == 2 then return { remaining = true } end end,
            reserveSeconds = 0,
            each = function(photo) seen[#seen + 1] = tostring(photo.localIdentifier) return {} end,
        })

        assert.are.same({ "1", "3" }, seen)
        assert.are.same({ "/2.jpg" }, reply.remaining)
    end)

    it("keeps every photo's outcome when one photo's file name cannot be read for the progress caption", function()
        local DevelopBatch, catalog = setup()
        catalog:getPhotoByLocalId(3).getFormattedMetadata = function() error("photo vanished") end
        local seen = {}
        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2", "3" },
            held = function(entry) if entry.index == 1 then return { reason = "Refused before writing: rule" } end end,
            reserveSeconds = 0,
            each = function(photo) seen[#seen + 1] = tostring(photo.localIdentifier) return { status = "done" } end,
        })

        assert.are.same({ "2", "3" }, seen)
        assert.are.same({ { photo_id = "1", reason = "Refused before writing: rule" } }, reply.failed)
        assert.are.equal(2, #reply.data.results)
    end)

    it("lets a finishing step replace the results with what it verified", function()
        local DevelopBatch, catalog = setup()
        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2" },
            reserveSeconds = 0,
            each = function(photo) return { photo = photo } end,
            finish = function(results)
                return { data = { verified = #results }, unknown = { { photo_id = "2", reason = "read-back failed" } } }
            end,
        })

        assert.are.same({ verified = 2 }, reply.data)
        assert.are.same({ { photo_id = "2", reason = "read-back failed" } }, reply.unknown)
    end)

    it("asks for a reserve that grows with every photo started", function()
        local DevelopBatch, catalog = setup()
        local asked = {}
        local context = helper.requestContext(nil, { stopping = function(_, seconds) asked[#asked + 1] = seconds; return false end })
        DevelopBatch.run(context, catalog, {
            inputs = { "1", "2", "3" },
            reserveSeconds = function(started) return 1 + started end,
            each = function() return {} end,
        })

        assert.are.same({ 1, 2, 3 }, asked)
    end)
end)
