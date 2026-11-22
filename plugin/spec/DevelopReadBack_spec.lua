local helper = require 'spec_helper'

local function load()
    helper.installImport({ LrTasks = { pcall = pcall, sleep = function() end } })
    package.loaded.DevelopReadBack = nil
    return require 'DevelopReadBack'
end

local function photoReading(id, settings)
    local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".arw" })
    photo.getDevelopSettings = function() return settings end
    return photo
end

describe("DevelopReadBack.saved", function()
    it("is the only reader of a photo's saved develop settings in the plug-in", function()
        local directory = "plugin/LightroomAgent.lrplugin/"
        local found = {}
        for file in io.popen('ls "' .. directory .. '"'):lines() do
            if file:match("%.lua$") and file ~= "DevelopReadBack.lua" then
                local source = assert(io.open(directory .. file)):read("*a"):gsub("%-%-[^\n]*", "")
                local count = 0
                for _ in source:gmatch("getDevelopSettings") do count = count + 1 end
                if count > 0 then found[file] = count end
            end
        end
        assert.are.same({}, found)
    end)

    it("raises, naming the photo, when Lightroom returns no saved settings", function()
        local DevelopReadBack = load()
        assert.has_error(function() DevelopReadBack.saved(photoReading("7", nil)) end,
            "Lightroom returned no saved settings for photo 7")
        assert.are.same({ Exposure2012 = 1 }, DevelopReadBack.saved(photoReading("7", { Exposure2012 = 1 })))
    end)
end)

describe("DevelopReadBack.check", function()
    it("answers a written photo whose read-back returns nothing unknown, not as a key Lightroom does not store", function()
        local DevelopReadBack = load()
        local catalog = helper.fakeCatalog({ photos = {} })
        local context = helper.requestContext()

        local checked = DevelopReadBack.check(context, catalog, {
            { photo = photoReading("7", nil), settings = { Exposure2012 = 1 }, before = {} },
        })
        local parts = DevelopReadBack.parts(checked, {})

        assert.are.same({}, checked[1].notStored)
        assert.are.equal("7", parts.unknown[1].photo_id)
        assert.truthy(parts.unknown[1].reason:find("Lightroom returned no saved settings for photo 7", 1, true))
    end)
end)

describe("DevelopReadBack.check within the time budget", function()
    local function written(DevelopReadBack, context, count, marked)
        local entries, reads = {}, { count = 0 }
        for index = 1, count do
            local photo = helper.fakePhoto({ id = tostring(index), path = "/" .. index .. ".arw" })
            photo.getDevelopSettings = function()
                reads.count = reads.count + 1
                return { Exposure2012 = 1 }
            end
            local entry = { photo = photo, settings = { Exposure2012 = 1 }, before = { Exposure2012 = 0 } }
            if marked then
                entry.from = context.ledger:mark()
                context.ledger:record("Set Develop Settings", true)
                entry.to = context.ledger:mark()
            end
            entries[index] = entry
        end
        return entries, reads
    end

    it("stops reading back when the reply reserve is reached and answers the photos it did not read unknown", function()
        local DevelopReadBack = load()
        local context = helper.requestContext()
        local entries, reads = written(DevelopReadBack, context, 2, true)
        context.timeLeft = function() return reads.count >= 1 and DevelopReadBack.REPLY_SECONDS - 0.1 or 60 end

        local parts = DevelopReadBack.parts(DevelopReadBack.check(context, helper.fakeCatalog({ photos = {} }), entries), {})

        assert.are.equal(1, reads.count)
        assert.are.same({ { photo_id = "2", reason = "written; not read back within the time budget; written before this stopped: Set Develop Settings" } },
            parts.unknown)
    end)

    it("answers a written photo it did not reach unknown even when its entry carries no ledger marks", function()
        local DevelopReadBack = load()
        local context = helper.requestContext(nil, { timeLeft = function() return 1 end })
        local entries = written(DevelopReadBack, context, 1, false)

        local parts = DevelopReadBack.parts(DevelopReadBack.check(context, helper.fakeCatalog({ photos = {} }), entries), {})

        assert.is_nil(parts.failed)
        assert.are.equal("1", parts.unknown[1].photo_id)
        assert.matches("not read back within the time budget", parts.unknown[1].reason)
    end)

    it("still reads back every written photo after a cancel when time is left", function()
        local DevelopReadBack = load()
        local context = helper.requestContext(nil, { isCanceled = function() return true end })
        local entries, reads = written(DevelopReadBack, context, 2, true)

        local parts = DevelopReadBack.parts(DevelopReadBack.check(context, helper.fakeCatalog({ photos = {} }), entries), {})

        assert.are.equal(2, reads.count)
        assert.is_nil(parts.unknown)
    end)
end)

describe("DevelopReadBack.check of a calibration key", function()
    it("reads a written RedHue back as stored, through the generic key path", function()
        local DevelopReadBack = load()
        local photo = photoReading("7", { RedHue = 20 })

        local checked = DevelopReadBack.check(helper.requestContext(), helper.fakeCatalog({ photos = {} }),
            { { photo = photo, settings = { RedHue = 20 }, before = {} } })

        assert.are.same({ RedHue = 20 }, checked[1].stored)
        assert.are.same({}, checked[1].adjusted)
    end)
end)
