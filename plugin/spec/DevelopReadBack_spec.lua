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
