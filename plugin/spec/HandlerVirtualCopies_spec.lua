local helper = require "spec_helper"

describe("HandlerVirtualCopies", function()
    local Handler, catalog, photos, calls, state

    local function setup(opts)
        opts = opts or {}
        photos = {}
        for i = 1, 5 do
            photos[i] = helper.fakePhoto({ id = tostring(i), path = "/" .. i .. ".jpg", fileName = i .. ".jpg" })
        end
        if opts.virtualInput then
            photos[3] = helper.fakePhoto({ id = "3", path = "/1.jpg", isVirtualCopy = true, masterPhoto = photos[1] })
        end
        local source = {}
        state = { active = photos[1], selected = { photos[1], photos[2] }, sources = { source } }
        if opts.empty then
            state.active, state.selected = nil, {}
        end
        calls = { create = {}, selection = {}, sources = {} }
        catalog = helper.fakeCatalog({ photos = photos })
        catalog.kAllPhotos = "all"
        local getTargets = catalog.getTargetPhotos
        local setSelected = catalog.setSelectedPhotos
        catalog.getTargetPhoto = function() return state.active end
        catalog.getTargetPhotos = function(self)
            getTargets(self)
            return state.selected
        end
        catalog.getActiveSources = function() return state.sources end
        catalog.setActiveSources = function(_, sources)
            calls.sources[#calls.sources + 1] = sources
            state.sources = sources
        end
        catalog.setSelectedPhotos = function(self, active, selected)
            setSelected(self, active, selected)
            calls.selection[#calls.selection + 1] = { active = active, photos = selected }
            if opts.failRestore and #calls.create > 0 and active == photos[1] then return end
            if opts.restricted and active == photos[3] and state.sources[1] ~= "all" then return end
            state.active, state.selected = active, selected
        end
        catalog.createVirtualCopies = function(_, name)
            assert.is_false(catalog.isInsideReadAccess())
            assert.are.equal(1, #state.selected)
            calls.create[#calls.create + 1] = { photo = state.active, name = name }
            if opts.failCreate or opts.failCreateAt == #calls.create then error("SDK failure") end
            local master = opts.wrongMaster and photos[5] or state.active:getRawMetadata("masterPhoto") or state.active
            local copy = helper.fakePhoto({
                id = tostring(100 + #calls.create),
                isVirtualCopy = true,
                masterPhoto = master,
            })
            if opts.copyUnreadable then copy.getRawMetadata = function() error("photo gone") end end
            state.active, state.selected = copy, { copy }
            if opts.twoCopies then
                return { copy, helper.fakePhoto({ id = "200", isVirtualCopy = true, masterPhoto = master }) }
            end
            return { copy }
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrApplicationView = {
                getCurrentModuleName = function() return "library" end,
                switchToModule = function() end,
            },
            LrDate = { currentTime = function() return 0 end },
            LrProgressScope = function()
                return {
                    setCancelable = function() end,
                    setPortionComplete = function() end,
                    setCaption = function() end,
                    done = function() end,
                    isCanceled = function() return false end,
                }
            end,
            LrLogger = helper.defaultLrLogger(),
            LrSelection = {
                selectNone = function()
                    state.active, state.selected = nil, {}
                end,
            },
            LrTasks = { pcall = pcall, sleep = function() end },
        })
        package.loaded.DevelopSession = nil
        package.loaded.DevelopBatch = nil
        package.loaded.HandlerVirtualCopies = nil
        Handler = require "HandlerVirtualCopies"
    end

    local function assertRestored()
        assert.are.equal(photos[1], state.active)
        assert.are.same({ photos[1], photos[2] }, state.selected)
        local last = calls.selection[#calls.selection]
        assert.are.equal(photos[1], last.active)
        assert.are.same({ photos[1], photos[2] }, last.photos)
    end

    it("creates named copies and returns resolved photo, master and copy ids as strings", function()
        setup()
        local result = Handler.create({ photo_ids = { "3", 2 }, copy_name = "Experiment" })
        assert.are.same({
            copies = {
                { photo_id = "3", master_photo_id = "3", copy_photo_id = "101" },
                { photo_id = "2", master_photo_id = "2", copy_photo_id = "102" },
            },
        }, result.data)
        assert.is_nil(result.not_found)
        assert.are.equal("Experiment", calls.create[1].name)
        assert.are.equal("Experiment", calls.create[2].name)
        assertRestored()
        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, catalog.getReadAccessCount())
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("deduplicates ids and paths to the same photo and lists unknown inputs as not_found", function()
        setup()
        local result = Handler.create({ photo_ids = { "3", "3", "/3.jpg", "999" } })
        assert.are.equal(1, #result.data.copies)
        assert.are.same({ "999" }, result.not_found)
        assert.is_nil(calls.create[1].name)
        assertRestored()
    end)

    it("selects only the requested photo even when it is already active", function()
        setup()
        Handler.create({ photo_ids = { "1" } })
        assert.are.equal(1, #calls.create)
        assert.are.equal(photos[1], calls.create[1].photo)
        assertRestored()
    end)

    it("returns the original master when the input is itself a virtual copy", function()
        setup({ virtualInput = true })
        local result = Handler.create({ photo_ids = { "3", "1" } })
        assert.are.same({ photo_id = "3", master_photo_id = "1", copy_photo_id = "101" }, result.data.copies[1])
        assert.are.same({ photo_id = "1", master_photo_id = "1", copy_photo_id = "102" }, result.data.copies[2])
        assertRestored()
    end)

    for _, case in ipairs({
        { opts = { wrongMaster = true }, reason = "Lightroom made virtual copy 101 of photo 5, not of photo 3" },
        { opts = { copyUnreadable = true }, reason = "photo gone" },
        { opts = { twoCopies = true }, reason = "Lightroom returned 2 virtual copies instead of one" },
    }) do
        it(
            "keeps the created copy ids in the unknown reason when a check after creation fails: " .. case.reason,
            function()
                setup(case.opts)
                local result = Handler.create({ photo_ids = { "3" } })
                assert.is_nil(result.data)
                local created = case.opts.twoCopies and "101, 200" or "101"
                assert.are.same({
                    {
                        photo_id = "3",
                        reason = case.reason
                            .. "; virtual copies created: "
                            .. created
                            .. "; written before this stopped: createVirtualCopies",
                    },
                }, result.unknown)
                assertRestored()
            end
        )
    end

    it("restores the view source after falling back to All Photographs", function()
        setup({ restricted = true })
        local originalSources = state.sources
        Handler.create({ photo_ids = { "3" } })
        assert.are.equal("all", calls.sources[1][1])
        assert.are.same(originalSources, state.sources)
        assertRestored()
    end)

    it("restores an empty selection", function()
        setup({ empty = true })
        Handler.create({ photo_ids = { "3" } })
        assert.is_nil(state.active)
        assert.are.same({}, state.selected)
    end)

    it("keeps the copies created before a failure on the third of five photos as data", function()
        setup({ failCreateAt = 3 })
        local result = Handler.create({ photo_ids = { "1", "2", "3", "4", "5" } })
        assert.are.same({ photo_id = "1", master_photo_id = "1", copy_photo_id = "101" }, result.data.copies[1])
        assert.are.same({ photo_id = "2", master_photo_id = "2", copy_photo_id = "102" }, result.data.copies[2])
        assert.are.equal("3", result.unknown[1].photo_id)
        assert.matches("SDK failure", result.unknown[1].reason, 1, true)
        assertRestored()
    end)

    it("reports an SDK failure as an unknown outcome and releases the session lock", function()
        setup({ failCreate = true })
        local result = Handler.create({ photo_ids = { "3" } })
        assert.is_nil(result.data)
        assert.are.same(
            { photo_id = "3", reason = "SDK failure; written before this stopped: createVirtualCopies" },
            result.unknown[1]
        )
        assertRestored()
        result = Handler.create({ photo_ids = { "3" } })
        assert.are.equal("3", result.unknown[1].photo_id)
    end)

    it("warns with the created copies when the selection cannot be restored", function()
        setup({ failRestore = true })
        local context = helper.requestContext(nil, { title = "create_virtual_copies" })
        local result = Handler.create({ photo_ids = { "3" } }, context)
        assert.are.equal("3", result.data.copies[1].photo_id)
        assert.matches("the previous selection was not restored", context.warnings[1], 1, true)
    end)

    it("answers not_found without touching the selection when no photo resolves", function()
        setup()
        local result = Handler.create({ photo_ids = { "999" } })
        assert.is_nil(result.data)
        assert.are.same({ "999" }, result.not_found)
        assert.are.same({}, calls.selection)
        assert.are.same({}, calls.create)
    end)
end)
