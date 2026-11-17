local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local photos = {}
    for i = 1, 4 do photos[i] = helper.fakePhoto({ id = tostring(i), path = "/" .. i .. ".jpg" }) end
    local catalog = helper.fakeCatalog({ photos = photos })
    local selected = opts.selected or { photos[4], photos[1] }
    local active = selected[1]
    local module = "develop"
    local sources = { "original source" }
    local alive = {}
    for _, p in ipairs(photos) do alive[p] = true end
    local calls = { selections = {}, removes = 0, sources = {}, grids = 0 }
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, value)
        sources = value
        calls.sources[#calls.sources + 1] = value
    end
    catalog.kAllPhotos = "all"
    calls.folderLookups = {}
    catalog.getFolderByPath = function(_, path)
        calls.folderLookups[#calls.folderLookups + 1] = path
        if opts.unknownFolder then return nil end
        return { folder = path }
    end
    catalog.setSelectedPhotos = function(_, p, value)
        calls.selections[#calls.selections + 1] = value
        if opts.ignoreSelection then return end
        if opts.ignoreSelections and #calls.selections <= opts.ignoreSelections then return end
        active, selected = p, value
        if opts.extraSelection then selected = { p, photos[4] } end
    end
    local batch = catalog.batchGetRawMetadata
    catalog.batchGetRawMetadata = function(self, list, keys)
        local raw = batch(self, list, keys)
        for _, p in ipairs(list) do
            if not alive[p] then raw[p].uuid = nil end
            if opts.virtualCopies and p == photos[1] then raw[p].virtualCopies = { photos[2] } end
            if opts.stack and p.localIdentifier <= "3" then
                raw[p].isInStackInFolder = true
                raw[p].stackInFolderIsCollapsed = opts.stack == "collapsed"
                raw[p].stackInFolderMembers = { photos[1], photos[2], photos[3] }
                raw[p].stackPositionInFolder = tonumber(p.localIdentifier)
                raw[p].topOfStackInFolderContainingPhoto = photos[1]
            end
        end
        return raw
    end
    local selection = {
        selectNone = function() active, selected = nil, {} end,
        removeFromCatalog = function()
            assert.are.equal("library", module)
            assert.are.equal(1, calls.grids)
            calls.removes = calls.removes + 1
            calls.removed = selected
            if opts.failRemoval then error("removal failed") end
            if opts.ignoreRemoval then return end
            for _, p in ipairs(selected) do alive[p] = nil end
            active, selected = nil, {}
        end,
    }
    if opts.withoutApi then selection.removeFromCatalog = nil end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end,
            gridView = function() calls.grids = calls.grids + 1 end,
        },
        LrPathUtils = { parent = function(path) return (path:gsub("/[^/]*$", "")) end },
        LrSelection = selection,
        LrDevelopController = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.HandlerRemoveFromCatalog = nil
    local handler = require 'HandlerRemoveFromCatalog'
    calls.state = function() return selected, active, module, sources end
    return handler, calls, photos, alive, catalog
end

describe("remove_photos_from_catalog by path", function()
    it("refuses a path shared with a virtual copy and removes nothing", function()
        local handler, calls = setup({ virtualCopies = true })
        assert.matches("numeric id", helper.failedOf(function()
            handler.removePhotos({ photo_ids = { "/1.jpg" } })
        end), 1, true)
        assert.are.equal(0, calls.removes)
    end)
end)

describe("HandlerRemoveFromCatalog.removePhotos", function()
    it("selects only resolved unique photos and restores surviving selection and module", function()
        local handler, calls, photos, alive, catalog = setup()
        local result = handler.removePhotos({ photo_ids = { "1", "/1.jpg", 2, "999", "999" } })
        assert.are.same({ data = { removed = 2 }, not_found = { "999" } }, result)
        assert.are.same({ photos[1], photos[2] }, calls.removed)
        assert.are.same({ photos[1], photos[2] }, calls.selections[1])
        local selected, active, module, sources = calls.state()
        assert.are.same({ photos[4] }, selected)
        assert.are.equal(photos[4], active)
        assert.are.equal("develop", module)
        assert.are.same({ "original source" }, sources)
        assert.is_nil(alive[photos[1]])
        assert.is_true(alive[photos[3]])
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("selects in the photos' own folders instead of All Photographs", function()
        local handler, calls, photos = setup()
        handler.removePhotos({ photo_ids = { "1", "2" } })
        assert.are.same({ { folder = "" } }, calls.sources[1])
        assert.are.same({ "" }, calls.folderLookups)
        assert.are.same({ photos[1], photos[2] }, calls.removed)
    end)

    it("falls back to All Photographs when a folder is not found", function()
        local handler, calls, photos = setup({ unknownFolder = true })
        handler.removePhotos({ photo_ids = { "1" } })
        assert.are.same({ "all" }, calls.sources[1])
        assert.are.same({ photos[1] }, calls.removed)
    end)

    it("repeats the selection until Lightroom keeps it", function()
        local handler, calls, photos = setup({ ignoreSelections = 4 })
        local result = handler.removePhotos({ photo_ids = { "1", "2" } })
        assert.are.equal(2, result.data.removed)
        assert.is_true(#calls.selections >= 5)
        assert.are.same({ photos[1], photos[2] }, calls.removed)
    end)

    it("gives up after 30 seconds without removing anything", function()
        local handler, calls = setup({ ignoreSelection = true })
        assert.matches("did not select exactly", helper.failedOf(function() handler.removePhotos({ photo_ids = { "1" } }) end), 1, true)
        assert.are.equal(16, #calls.selections)
        assert.are.equal(0, calls.removes)
    end)

    it("accepts a selection that sticks on the last attempt", function()
        local handler, calls, photos = setup({ ignoreSelections = 15 })
        local result = handler.removePhotos({ photo_ids = { "1" } })
        assert.are.equal(1, result.data.removed)
        assert.is_true(#calls.selections >= 16)
        assert.are.same({ photos[1] }, calls.removed)
    end)

    it("makes a surviving photo active when the original active photo was removed", function()
        local handler, calls, photos = setup()
        handler.removePhotos({ photo_ids = { "4" } })
        local selected, active = calls.state()
        assert.are.same({ photos[1] }, selected)
        assert.are.equal(photos[1], active)
    end)

    it("restores an empty selection", function()
        local handler, calls = setup({ selected = {} })
        handler.removePhotos({ photo_ids = { "1" } })
        local selected, active = calls.state()
        assert.are.same({}, selected)
        assert.is_nil(active)
    end)

    it("answers not_found without touching selection when no IDs resolve", function()
        local handler, calls = setup()
        local reply = handler.removePhotos({ photo_ids = { "999" } })
        assert.is_nil(reply.data)
        assert.are.same({ "999" }, reply.not_found)
        assert.are.same({}, calls.selections)
        assert.are.equal(0, calls.removes)
    end)

    it("fails on both a rejected selection and one containing extra photos", function()
        for _, opts in ipairs({ { ignoreSelection = true }, { extraSelection = true } }) do
            local handler, calls = setup(opts)
            local class, message = helper.outcomeOf(function(context)
                handler.removePhotos({ photo_ids = { "1", "2" } }, context)
            end)
            assert.are.equal("failed", class)
            assert.matches("did not select exactly", message, 1, true)
            assert.are.equal(0, calls.removes)
            local _, _, module, sources = calls.state()
            assert.are.equal("develop", module)
            assert.are.same({ "original source" }, sources)
        end
    end)

    it("restores the view after an SDK error and never reports ignored removal as success", function()
        for _, opts in ipairs({ { failRemoval = true }, { ignoreRemoval = true } }) do
            local handler, calls, photos = setup(opts)
            assert.are.same({ "unknown", (opts.failRemoval and "removal failed"
                or "Lightroom did not remove every requested photo; check the catalog before retrying")
                .. "; written before this stopped: Remove from Catalog" }, { helper.outcomeOf(function(context)
                handler.removePhotos({ photo_ids = { "2" } }, context)
            end) })
            local selected, active, module = calls.state()
            assert.are.same({ photos[4], photos[1] }, selected)
            assert.are.equal(photos[4], active)
            assert.are.equal("develop", module)
        end
    end)

    it("refuses a master whose virtual copies were not explicitly requested", function()
        local handler, calls = setup({ virtualCopies = true })
        assert.matches("Include every virtual copy", helper.failedOf(function() handler.removePhotos({ photo_ids = { "1" } }) end), 1, true)
        assert.are.same({}, calls.selections)
        assert.are.equal(0, calls.removes)
    end)

    it("refuses any photo of a collapsed stack at once, naming the top photo, before changing the selection", function()
        for _, ids in ipairs({ { "1" }, { "2", "3" }, { "1", "2", "3" } }) do
            local handler, calls = setup({ stack = "collapsed" })
            assert.matches("collapsed stack whose top photo is 1; expand the stack in Lightroom first", helper.failedOf(function() handler.removePhotos({ photo_ids = ids }) end), 1, true)
            assert.are.same({}, calls.selections)
            assert.are.same({}, calls.sources)
            assert.are.equal(0, calls.removes)
        end
    end)

    it("removes one photo of an expanded stack", function()
        local handler, calls = setup({ stack = "expanded" })
        handler.removePhotos({ photo_ids = { "2" } })
        assert.are.equal(1, calls.removes)
    end)
end)
