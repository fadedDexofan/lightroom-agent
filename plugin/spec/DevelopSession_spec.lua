local helper = require 'spec_helper'

local function setup()
    local first, second = helper.fakePhoto({ id = "1", path = "/1.jpg" }), helper.fakePhoto({ id = "2", path = "/2.jpg" })
    local catalog = helper.fakeCatalog({ photos = { first, second } })
    local active, selected = first, { first, second }
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setSelectedPhotos = function(_, photo, selection) active, selected = photo, selection end
    helper.installImport({
        LrApplicationView = { getCurrentModuleName = function() return "library" end, switchToModule = function() end },
        LrDevelopController = {},
        LrSelection = { selectNone = function() end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    return require 'DevelopSession', catalog, first, second, function() return active, selected end
end

describe("DevelopSession.run", function()
    it("restores a multi-photo selection when the last photo opened is the active one", function()
        local DevelopSession, catalog, first, second, state = setup()

        DevelopSession.run(helper.requestContext(nil, { title = "tool" }), catalog, true, function()
            catalog:setSelectedPhotos(second, { second })
            catalog:setSelectedPhotos(first, { first })
        end)

        local active, selected = state()
        assert.are.equal(first, active)
        assert.are.same({ first, second }, selected)
    end)

    it("keeps the lock while restoringView runs and releases it afterwards", function()
        local DevelopSession, catalog = setup()
        local blocked

        local outer = helper.requestContext(nil, { title = "outer" })
        DevelopSession.run(outer, catalog, false, function()
            DevelopSession.restoringView(outer, catalog, function() end)
            blocked = helper.refusalOf(function()
                DevelopSession.run(helper.requestContext(nil, { title = "inner" }), catalog, false, function() end)
            end)
        end)

        assert.matches("outer is already running", blocked, 1, true)
        assert.is_true(DevelopSession.run(helper.requestContext(nil, { title = "after" }), catalog, false,
            function() return true end))
    end)
end)
