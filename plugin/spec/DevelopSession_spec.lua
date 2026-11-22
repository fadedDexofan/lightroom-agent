local helper = require "spec_helper"

local function setup()
    local first, second =
        helper.fakePhoto({ id = "1", path = "/1.jpg" }), helper.fakePhoto({ id = "2", path = "/2.jpg" })
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
    local ctx = { catalog = catalog, first = first, second = second, events = events, write = require "CatalogWrite" }
    function ctx.state() return active, selected end
    return require "DevelopSession", ctx
end

describe("DevelopSession.openPhoto", function()
    it("leaves the photo alone selected before Develop acts on it", function()
        local DevelopSession, ctx = setup()
        local selection
        DevelopSession.run(helper.requestContext(nil, { title = "tool" }), ctx.catalog, false, function(state)
            DevelopSession.openPhoto(ctx.catalog, ctx.first, state)
            local _, selected = ctx.state()
            selection = selected
        end)

        assert.are.same({ ctx.first }, selection)
    end)
end)

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

            assert.are.same(
                { "module develop", "select 2", "set Exposure 1", "flush true", "module library", "select 1" },
                ctx.events
            )
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
        assert.is_true(
            DevelopSession.run(
                helper.requestContext(nil, { title = "after" }),
                ctx.catalog,
                false,
                function() return true end
            )
        )
    end)
end)

describe("DevelopSession source steps", function()
    local function sourceSetup(opts)
        opts = opts or {}
        local now = { t = 0 }
        local events = {}
        local folders =
            { ["/A"] = { path = "/A" }, ["/B"] = { path = "/B" }, ["/C"] = { path = "/C" }, ["/D"] = { path = "/D" } }
        local onDisk = opts.onDisk or { ["/A"] = true, ["/B"] = true, ["/C"] = true, ["/D"] = true }
        local photos = {
            a = helper.fakePhoto({ id = "1", path = "/A/a.arw" }),
            b = helper.fakePhoto({ id = "2", path = "/B/b.arw" }),
            c = helper.fakePhoto({ id = "3", path = "/C/c.arw" }),
            d = helper.fakePhoto({ id = "4", path = "/D/d.arw" }),
        }
        local catalog = helper.fakeCatalog({ photos = { photos.a, photos.b, photos.c, photos.d } })
        if opts.rawRaises then catalog.batchGetRawMetadata = function() error("photo vanished", 0) end end
        local allShownAt
        catalog.kAllPhotos = { all = true }
        local sources = { folders["/A"] }
        local active, selected = photos.a, { photos.a }
        local pollsSinceSwitch = 0
        local function shows(photo)
            for _, source in ipairs(sources) do
                if source.all or photo:getRawMetadata("path"):sub(1, #source.path + 1) == source.path .. "/" then
                    return true
                end
            end
            return false
        end
        catalog.getActiveSources = function() return sources end
        catalog.setActiveSources = function(_, list)
            local name = list[1].all and "all" or list[1].path
            events[#events + 1] = "source " .. name
            if opts.folderFails and not list[1].all and list[1] ~= folders["/A"] then
                if opts.folderFails == "raise" then error("AgFolderSource assertion", 0) end
                return false
            end
            if opts.allFails and list[1].all then return false end
            if opts.restoreFails and list[1] == folders["/A"] then return false end
            if list[1].all then allShownAt = now.t end
            sources = list
            pollsSinceSwitch = 0
            return true
        end
        catalog.getFolderByPath = function(_, path) return folders[path] end
        catalog.getTargetPhoto = function()
            pollsSinceSwitch = pollsSinceSwitch + 1
            return active
        end
        catalog.getTargetPhotos = function() return selected end
        catalog.setSelectedPhotos = function(_, photo, selection)
            local after = (opts.selectableAfterAll or {})[photo.localIdentifier]
            if after and not (allShownAt and now.t - allShownAt >= after) then return end
            if shows(photo) and pollsSinceSwitch >= (opts.selectableAfterPolls or 0) then
                active, selected = photo, selection
            end
        end
        helper.installImport({
            LrApplicationView = {
                getCurrentModuleName = function() return "library" end,
                switchToModule = function() end,
            },
            LrDevelopController = {},
            LrFileUtils = { exists = function(path) return onDisk[path] and "directory" or false end },
            LrPathUtils = { parent = function(path) return path:match("^(.+)/[^/]+$") end },
            LrSelection = { selectNone = function() end },
            LrTasks = { pcall = pcall, sleep = function(seconds) now.t = now.t + seconds end },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.PhotoSources = nil
        package.loaded.DevelopSession = nil
        local DevelopSession = require "DevelopSession"
        local context = helper.requestContext(nil, { title = "tool" })
        local function open(list)
            local opened = {}
            DevelopSession.run(context, catalog, true, function(state)
                for _, photo in ipairs(list) do
                    local started = now.t
                    opened[#opened + 1] = { DevelopSession.selectAlone(catalog, photo, state), now.t - started }
                end
            end)
            return opened
        end
        return photos, open, events, function() return sources end, context, function() return active, selected end
    end

    it(
        "shows a photo outside the source through its own folder after a short first try, then puts the source back",
        function()
            local photos, open, events, current = sourceSetup()

            local opened = open({ photos.b })

            assert.is_true(opened[1][1])
            assert.is_true(opened[1][2] <= 2.5)
            assert.are.same({ "source /B", "source /A" }, events)
            assert.are.equal("/A", current()[1].path)
        end
    )

    it("goes to All Photographs, never to a folder missing on disk", function()
        local photos, open, events = sourceSetup({ onDisk = { ["/A"] = true } })

        assert.is_true(open({ photos.b })[1][1])
        assert.are.same({ "source all", "source /A" }, events)
    end)

    for _, failure in ipairs({ "raise", "false" }) do
        it(
            "goes to All Photographs when the folder step "
                .. (failure == "raise" and "raises" or "reports false")
                .. ", and puts the source back",
            function()
                local photos, open, events, current =
                    sourceSetup({ folderFails = failure == "raise" and "raise" or true })

                assert.is_true(open({ photos.b })[1][1])
                assert.are.same({ "source /B", "source all", "source /A" }, events)
                assert.are.equal("/A", current()[1].path)
            end
        )
    end

    it("keeps polling after a switch until the grid can select the photo, then restores the selection", function()
        local photos, open, _, _, _, state = sourceSetup({ selectableAfterPolls = 15 })

        assert.is_true(open({ photos.b })[1][1])
        local active, selected = state()
        assert.are.equal(photos.a, active)
        assert.are.same({ photos.a }, selected)
    end)

    it("does not poll a folder Lightroom refused to show", function()
        local photos, open = sourceSetup({ folderFails = true })

        local opened = open({ photos.b })

        assert.is_true(opened[1][1])
        assert.is_true(opened[1][2] <= 2.5)
    end)

    it("warns when Lightroom refuses to put the previous source back", function()
        local photos, open, _, _, context = sourceSetup({ restoreFails = true })

        open({ photos.b })

        assert.matches("the previous source was not reopened", context.warnings[1], 1, true)
    end)

    it("takes the folder step once per run, then All Photographs", function()
        local photos, open, events = sourceSetup()

        local opened = open({ photos.b, photos.c })

        assert.is_true(opened[1][1] and opened[2][1])
        assert.are.same({ "source /B", "source all", "source /A" }, events)
    end)

    it("polls All Photographs for the full deadline once it is the run's source, with no further switch", function()
        local photos, open, events = sourceSetup({ selectableAfterAll = { ["4"] = 3 } })

        local opened = open({ photos.b, photos.c, photos.d })

        assert.is_true(opened[1][1] and opened[2][1] and opened[3][1])
        assert.are.same({ "source /B", "source all", "source /A" }, events)
    end)

    it("switches back to no folder once All Photographs is the run's source", function()
        local photos, open, events =
            sourceSetup({ onDisk = { ["/A"] = true, ["/C"] = true }, selectableAfterAll = { ["3"] = 2.5 } })

        local opened = open({ photos.b, photos.c })

        assert.is_true(opened[1][1] and opened[2][1])
        assert.are.same({ "source all", "source /A" }, events)
    end)

    it("still takes a later photo's folder step when the switch to All Photographs was refused", function()
        local photos, open, events = sourceSetup({ onDisk = { ["/A"] = true, ["/C"] = true }, allFails = true })

        local opened = open({ photos.b, photos.c })

        assert.is_false(opened[1][1])
        assert.is_true(opened[2][1])
        assert.are.same({ "source all", "source /C", "source /A" }, events)
    end)

    it("goes to All Photographs when the photo's folder cannot be established", function()
        local photos, open, events = sourceSetup({ rawRaises = true })

        assert.is_true(open({ photos.b })[1][1])
        assert.are.same({ "source all", "source /A" }, events)
    end)

    it("changes no source for a photo already in it", function()
        local photos, open, events = sourceSetup()

        assert.is_true(open({ photos.a })[1][1])
        assert.are.same({}, events)
    end)
end)
