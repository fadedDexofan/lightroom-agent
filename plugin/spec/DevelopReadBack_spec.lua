local helper = require "spec_helper"

local function load()
    helper.installImport({ LrTasks = { pcall = pcall, sleep = function() end } })
    package.loaded.DevelopReadBack = nil
    return require "DevelopReadBack"
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
                for _ in source:gmatch("getDevelopSettings") do
                    count = count + 1
                end
                if count > 0 then found[file] = count end
            end
        end
        assert.are.same({}, found)
    end)

    it("raises, naming the photo, when Lightroom returns no saved settings", function()
        local DevelopReadBack = load()
        assert.has_error(
            function() DevelopReadBack.saved(photoReading("7", nil)) end,
            "Lightroom returned no saved settings for photo 7"
        )
        assert.are.same({ Exposure2012 = 1 }, DevelopReadBack.saved(photoReading("7", { Exposure2012 = 1 })))
    end)
end)

describe("DevelopReadBack.check", function()
    it("read_back_homes: checks, classes and reports only in DevelopReadBack and single-photo settings", function()
        local directory = "plugin/LightroomAgent.lrplugin/"
        local homes = { check = true, classify = true, report = true }
        local own = assert(io.open(directory .. "DevelopReadBack.lua")):read("*a")
        local defined, single, outside = {}, {}, {}
        for name in pairs(homes) do
            defined[name] = own:find("\nfunction DevelopReadBack%." .. name .. "%(") ~= nil
        end
        for file in io.popen('ls "' .. directory .. '"'):lines() do
            if file:match("%.lua$") and file ~= "DevelopReadBack.lua" then
                local source = assert(io.open(directory .. file)):read("*a")
                for start, name in source:gmatch("()%f[%w_]DevelopReadBack%.([%w_]+)") do
                    if homes[name] then
                        local where = file .. " " .. tostring(helper.functionAt(source, start))
                        if where == "HandlerDevelop.lua DevelopHandler.setDevelopSettings" then
                            single[name] = true
                        else
                            outside[#outside + 1] = where .. ": " .. name
                        end
                    end
                end
            end
        end
        table.sort(outside)

        assert.are.same(
            { defined = homes, single = homes, outside = {} },
            { defined = defined, single = single, outside = outside }
        )
    end)

    it(
        "answers a written photo whose read-back returns nothing unknown, not as a key Lightroom does not store",
        function()
            local DevelopReadBack = load()
            local catalog = helper.fakeCatalog({ photos = {} })
            local context = helper.requestContext()
            local from = context.ledger:mark()
            context.ledger:record("Set Develop Settings")

            local checked = DevelopReadBack.check(context, catalog, {
                {
                    photo = photoReading("7", nil),
                    settings = { Exposure2012 = 1 },
                    before = {},
                    from = from,
                    to = context.ledger:mark(),
                },
            })
            local _, unknown = DevelopReadBack.classify(checked)

            assert.are.same({}, checked[1].notStored)
            assert.are.equal("7", unknown[1].photo_id)
            assert.truthy(unknown[1].reason:find("Lightroom returned no saved settings for photo 7", 1, true))
        end
    )
end)

describe("DevelopReadBack.check within the time budget", function()
    local function written(context, count)
        local entries, reads = {}, { count = 0 }
        for index = 1, count do
            local photo = helper.fakePhoto({ id = tostring(index), path = "/" .. index .. ".arw" })
            photo.getDevelopSettings = function()
                reads.count = reads.count + 1
                return { Exposure2012 = 1 }
            end
            local entry = { photo = photo, settings = { Exposure2012 = 1 }, before = { Exposure2012 = 0 } }
            entry.from = context.ledger:mark()
            context.ledger:record("Set Develop Settings", true)
            entry.to = context.ledger:mark()
            entries[index] = entry
        end
        return entries, reads
    end

    it("stops reading back when the reply reserve is reached and answers the photos it did not read unknown", function()
        local DevelopReadBack = load()
        local context = helper.requestContext()
        local entries, reads = written(context, 2)
        context.timeLeft = function() return reads.count >= 1 and DevelopReadBack.REPLY_SECONDS - 0.1 or 60 end

        local _, unknown =
            DevelopReadBack.classify(DevelopReadBack.check(context, helper.fakeCatalog({ photos = {} }), entries))

        assert.are.equal(1, reads.count)
        assert.are.same({
            {
                photo_id = "2",
                reason = "written; not read back within the time budget; written before this stopped: Set Develop Settings",
            },
        }, unknown)
    end)

    it("still reads back every written photo after a cancel when time is left", function()
        local DevelopReadBack = load()
        local context = helper.requestContext(nil, { isCanceled = function() return true end })
        local entries, reads = written(context, 2)

        local _, unknown =
            DevelopReadBack.classify(DevelopReadBack.check(context, helper.fakeCatalog({ photos = {} }), entries))

        assert.are.equal(2, reads.count)
        assert.are.same({}, unknown)
    end)
end)

describe("DevelopReadBack.check of a calibration key", function()
    it("reads a written RedHue back as stored, through the generic key path", function()
        local DevelopReadBack = load()
        local photo = photoReading("7", { RedHue = 20 })
        local context = helper.requestContext()
        local from = context.ledger:mark()
        context.ledger:record("Set Develop Settings")

        local checked = DevelopReadBack.check(
            context,
            helper.fakeCatalog({ photos = {} }),
            { { photo = photo, settings = { RedHue = 20 }, before = {}, from = from, to = context.ledger:mark() } }
        )

        assert.are.same({ RedHue = 20 }, checked[1].stored)
        assert.are.same({}, checked[1].adjusted)
    end)
end)
