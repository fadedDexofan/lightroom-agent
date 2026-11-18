local helper = require 'spec_helper'

local function setup()
    local first, second = helper.fakePhoto({ id = "1", path = "/1.jpg" }), helper.fakePhoto({ id = "2", path = "/2.jpg" })
    local catalog = helper.fakeCatalog({ photos = { first, second } })
    local active, selected = first, { first, second }
    local module, events = "library", {}
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setSelectedPhotos = function(_, photo, selection)
        active, selected = photo, selection
        events[#events + 1] = "select " .. photo.localIdentifier
    end
    helper.installImport({
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                events[#events + 1] = "module " .. name
            end,
        },
        LrDevelopController = {
            stopTracking = function(committed) events[#events + 1] = "flush " .. tostring(committed) end,
            setValue = function(key, value) events[#events + 1] = "set " .. key .. " " .. tostring(value) end,
        },
        LrSelection = { selectNone = function() end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.CatalogWrite = nil
    local ctx = { catalog = catalog, first = first, second = second, events = events, write = require 'CatalogWrite' }
    function ctx.state() return active, selected end
    return require 'DevelopSession', ctx
end

describe("DevelopSession.run", function()
    it("restores a multi-photo selection when the last photo opened is the active one", function()
        local DevelopSession, ctx = setup()

        DevelopSession.run(helper.requestContext(nil, { title = "tool" }), ctx.catalog, true, function()
            ctx.catalog:setSelectedPhotos(ctx.second, { ctx.second })
            ctx.catalog:setSelectedPhotos(ctx.first, { ctx.first })
        end)

        local active, selected = ctx.state()
        assert.are.equal(ctx.first, active)
        assert.are.same({ ctx.first, ctx.second }, selected)
    end)

    for _, case in ipairs({
        { ending = "returns", body = function() end },
        { ending = "raises", body = function() error("controller failed", 0) end },
    }) do
        it("commits its controller writes before it restores the view when the body " .. case.ending, function()
            local DevelopSession, ctx = setup()
            local context = helper.requestContext(nil, { title = "tool" })

            pcall(DevelopSession.run, context, ctx.catalog, true, function()
                DevelopSession.openDevelop()
                ctx.catalog:setSelectedPhotos(ctx.second, { ctx.second })
                ctx.write.develop(context, "setValue", "Exposure", 1)
                case.body()
            end)

            assert.are.same({ "module develop", "select 2", "set Exposure 1", "flush true", "module library",
                "select 1" }, ctx.events)
        end)
    end

    it("commits nothing when the session made no controller write", function()
        local DevelopSession, ctx = setup()
        local context = helper.requestContext(nil, { title = "tool" })
        context.ledger:record("Apply Develop Snapshot")

        DevelopSession.run(context, ctx.catalog, true, function()
            DevelopSession.openDevelop()
            ctx.catalog:setSelectedPhotos(ctx.second, { ctx.second })
            context.ledger:record("Delete Develop Snapshot")
        end)

        assert.are.same({ "module develop", "select 2", "module library", "select 1" }, ctx.events)
    end)

    it("commits nothing when the session never opened Develop", function()
        local DevelopSession, ctx = setup()

        DevelopSession.run(helper.requestContext(nil, { title = "tool" }), ctx.catalog, true, function() end)

        assert.are.same({}, ctx.events)
    end)

    it("refuses a second session while one runs and releases the lock afterwards", function()
        local DevelopSession, ctx = setup()
        local blocked

        DevelopSession.run(helper.requestContext(nil, { title = "outer" }), ctx.catalog, false, function()
            blocked = helper.failedOf(function()
                DevelopSession.run(helper.requestContext(nil, { title = "inner" }), ctx.catalog, false, function() end)
            end)
        end)

        assert.matches("outer is already running", blocked, 1, true)
        assert.is_true(DevelopSession.run(helper.requestContext(nil, { title = "after" }), ctx.catalog, false,
            function() return true end))
    end)
end)
