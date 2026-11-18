local helper = require 'spec_helper'

local function tool(id)
    return { ID = id, Name = "Tool " .. id, Type = "brush", Hidden = false, Inverted = false }
end

local function mask(id, toolIds)
    local tools = {}
    for _, toolId in ipairs(toolIds) do tools[#tools + 1] = tool(toolId) end
    return { ID = id, Name = "Mask " .. id, Hidden = false, Tools = tools }
end

local function idsOf(masks)
    local ids = {}
    for _, m in ipairs(masks) do ids[#ids + 1] = m.ID end
    return ids
end

local function savedSettingsOf(masks)
    local groups = {}
    for _, m in ipairs(masks) do
        local correctionMasks = {}
        for _, t in ipairs(m.Tools) do correctionMasks[#correctionMasks + 1] = { MaskID = t.ID } end
        groups[#groups + 1] = { CorrectionID = m.ID, CorrectionMasks = correctionMasks }
    end
    return { MaskGroupBasedCorrections = groups }
end

local function setup(opts)
    local photos, masksOf = {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[#photos + 1] = p
        masksOf[p] = spec.masks or {}
        p.getDevelopSettings = function() return savedSettingsOf(masksOf[p]) end
    end
    local calls = { modules = {}, selections = {}, deleteAllEmpty = {} }
    local catalog = helper.fakeCatalog({ photos = photos, writeAccessAborts = opts.writeAccessAborts })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    local withWriteAccess = catalog.withWriteAccessDo
    local insideWrite = false
    catalog.withWriteAccessDo = function(self, title, fn, ...)
        return withWriteAccess(self, title, function()
            insideWrite = true
            local ok, err = pcall(fn)
            insideWrite = false
            if not ok then error(err, 0) end
        end, ...)
    end
    catalog.deleteAllEmptyMasks = function(_, targets)
        if not insideWrite then error("deleteAllEmptyMasks outside withWriteAccessDo") end
        calls.deleteAllEmpty[#calls.deleteAllEmpty + 1] = targets
        for _, p in ipairs(targets) do
            local kept = {}
            for _, m in ipairs(masksOf[p]) do
                if #m.Tools > 0 then kept[#kept + 1] = m end
            end
            masksOf[p] = kept
        end
    end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) calls.modules[#calls.modules + 1] = name end,
        },
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMaskDelete = nil
    package.loaded.GuardedMaskWrite = nil
    package.loaded.DevelopSession = nil
    return require 'HandlerMaskDelete', calls, catalog, masksOf, photos
end

local Store = require 'fake_mask_store'

local function savedSetup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, {
        entries = opts.entries or {
            Store.correction("A", { Store.linearComponent({ MaskID = "A1" }), Store.radialComponent({ MaskID = "A2" }) },
                { CorrectionID = "mask-a", LocalExposure2012 = 0.25, LocalGlow = 0 }),
            Store.correction("B", { Store.linearComponent({ MaskID = "B1" }) }, { CorrectionID = "mask-b" }),
            Store.correction("C", { Store.radialComponent({ MaskID = "C1" }) }, { CorrectionID = "mask-c" }),
        },
        transformWrite = opts.transformWrite,
    })
    local catalog = helper.fakeCatalog({ photos = { photo }, writeAccessAborts = opts.writeAccessAborts })
    Store.trackGates(store, catalog)
    local modules = {}
    helper.admitMaskWrites({ refuse = "Mask geometry writes are not certified." })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) modules[#modules + 1] = name end,
        },
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskDelete", "GuardedMaskWrite", "DevelopSession", "CatalogWrite" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskDelete', store, modules, catalog
end

local function entryIds(store)
    local ids = {}
    for _, entry in ipairs(store.entries) do ids[#ids + 1] = entry.CorrectionID end
    return ids
end

describe("HandlerMaskDelete.deleteMasks in the saved settings, with constructing writes not certified", function()
    it("removes the masks named by mask_ids and leaves the others byte-identical, without Develop", function()
        local Handler, store, modules = savedSetup()
        local kept = Store.clone(store.entries[2])

        local r = Handler.deleteMasks({ photo_id = "1", mask_ids = { "mask-a", "mask-c" } })

        assert.are.same({ "mask-a", "mask-c" }, r.deleted_mask_ids)
        assert.are.same({ "A1", "A2", "C1" }, r.deleted_tool_ids)
        assert.are.equal(1, r.remaining_mask_count)
        assert.are.same({ kept }, store.entries)
        assert.are.same({}, modules)
        assert.are.equal(1, store.attempts)
    end)

    it("removes one component and keeps its mask, every other field and component unchanged", function()
        local Handler, store = savedSetup()
        local expected = Store.clone(store.entries[1])
        table.remove(expected.CorrectionMasks, 1)

        local r = Handler.deleteMasks({ photo_id = "1", tool_ids = { "A1" } })

        assert.are.same({}, r.deleted_mask_ids)
        assert.are.same({ "A1" }, r.deleted_tool_ids)
        assert.are.same(expected, store.entries[1])
        assert.are.same({ "mask-a", "mask-b", "mask-c" }, entryIds(store))
    end)

    it("removes the mask with its last component instead of keeping an empty one", function()
        local Handler, store = savedSetup()

        local r = Handler.deleteMasks({ photo_id = "1", tool_ids = { "B1", "A2" } })

        assert.are.same({ "mask-b" }, r.deleted_mask_ids)
        assert.are.same({ "A2", "B1" }, r.deleted_tool_ids)
        assert.are.same({ "mask-a", "mask-c" }, entryIds(store))
    end)

    it("removes every mask with all=true and leaves no mask list", function()
        local Handler, store = savedSetup()

        local r = Handler.deleteMasks({ photo_id = "1", all = true })

        assert.are.same({ "mask-a", "mask-b", "mask-c" }, r.deleted_mask_ids)
        assert.are.equal(0, r.remaining_mask_count)
        assert.are.same({}, store.entries)
    end)

    it("writes nothing for all=true on a photo without masks", function()
        local Handler, store = savedSetup({ entries = {} })

        local r = Handler.deleteMasks({ photo_id = "1", all = true })

        assert.are.same({}, r.deleted_mask_ids)
        assert.are.equal(0, r.remaining_mask_count)
        assert.are.equal(0, store.attempts)
    end)

    it("removes a duplicated mask id once", function()
        local Handler, store = savedSetup()

        local r = Handler.deleteMasks({ photo_id = "1", mask_ids = { "mask-b", "mask-b" } })

        assert.are.same({ "mask-b" }, r.deleted_mask_ids)
        assert.are.same({ "mask-a", "mask-c" }, entryIds(store))
    end)

    for _, case in ipairs({
        { kind = "mask", args = { mask_ids = { "mask-a", "nope", "gone" } }, message = "Unknown mask id(s) on photo 1: nope, gone; nothing was deleted" },
        { kind = "tool", args = { tool_ids = { "A1", "nope" } }, message = "Unknown tool id(s) on photo 1: nope; nothing was deleted" },
    }) do
        it("deletes nothing and names every unknown " .. case.kind .. " id", function()
            local Handler, store = savedSetup()
            local args = { photo_id = "1" }
            for key, value in pairs(case.args) do args[key] = value end

            local err = helper.failedOf(function() Handler.deleteMasks(args) end)

            assert.are.equal(case.message, err)
            assert.are.equal(0, store.attempts)
        end)
    end

    for _, case in ipairs({
        { what = "a slider", change = function(survivor) survivor.LocalExposure2012 = 0.5 end },
        { what = "a number by less than the constructed tolerance", change = function(survivor)
            survivor.LocalExposure2012 = 0.2500001 end },
        { what = "a derived field", change = function(survivor) survivor.CorrectionMasks[1].MaskSyncID = "OTHER" end },
        { what = "a zero local adjustment dropped", change = function(survivor) survivor.LocalGlow = nil end },
    }) do
        it("restores the photo and refuses when Lightroom changes a surviving mask by " .. case.what, function()
            local Handler, store = savedSetup({ transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then case.change(stored[1]) end
                return stored
            end })
            local before = Store.clone(store.entries)

            local err = helper.failedOf(function() Handler.deleteMasks({ photo_id = "1", mask_ids = { "mask-b" } }) end)

            assert.truthy(err:find("previous masks were restored", 1, true), err)
            assert.are.same(before, store.entries)
        end)
    end

    it("refuses with nothing written when the catalog stays busy", function()
        local Handler, store = savedSetup({ writeAccessAborts = function() return true end })

        local ok = pcall(Handler.deleteMasks, { photo_id = "1", mask_ids = { "mask-b" } })

        assert.is_false(ok)
        assert.are.equal(0, store.attempts)
    end)

    it("answers not_found for an unknown photo", function()
        local Handler = savedSetup()
        assert.are.equal("404", helper.notFoundOf(function() Handler.deleteMasks({ photo_id = "404", all = true }) end))
    end)
end)

describe("HandlerMaskDelete.deleteMasks beside a mask Lightroom has not named yet", function()
    it("refuses with nothing written, since that mask could not be resent unchanged", function()
        local Handler, store = savedSetup()
        store.entries[2].CorrectionID, store.entries[2].CorrectionSyncID = nil, nil

        local refusal = helper.failedOf(function() Handler.deleteMasks({ photo_id = "1", mask_ids = { "mask-a" } }) end)

        assert.matches('mask 2 ("B") has no id yet', refusal, 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses all=true with nothing written while the only mask and its tools have no id yet", function()
        local Handler, store = savedSetup()
        store.entries = { store.entries[1] }
        store.entries[1].CorrectionID, store.entries[1].CorrectionSyncID = nil, nil
        for _, component in ipairs(store.entries[1].CorrectionMasks) do component.MaskID, component.MaskSyncID = nil, nil end

        local refusal = helper.failedOf(function() Handler.deleteMasks({ photo_id = "1", all = true }) end)

        assert.matches('mask 1 ("A") has no id yet', refusal, 1, true)
        assert.are.equal(0, store.attempts)
    end)
end)

describe("HandlerMaskDelete.deleteEmptyMasks", function()
    local function photosWithEmptyMasks()
        return {
            { id = "1", masks = { mask("a", { "t-1" }), mask("empty-a", {}) } },
            { id = "2", masks = { mask("b", { "t-2" }) } },
            { id = "3", masks = { mask("empty-b", {}), mask("empty-c", {}) } },
            { id = "4" },
        }
    end

    it("deletes empty masks and counts the photos that changed", function()
        local Handler, _, _, masksOf, photos = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteEmptyMasks({ photo_ids = { "1", "2", "3", "4" } })

        assert.are.same({ photos_checked = 4, changed = {
            { photo_id = "1", masks_removed = 1 }, { photo_id = "3", masks_removed = 2 },
        } }, r.data)
        assert.is_nil(r.not_found)
        assert.are.same({ "a" }, idsOf(masksOf[photos[1]]))
        assert.are.same({ "b" }, idsOf(masksOf[photos[2]]))
        assert.are.same({}, masksOf[photos[3]])
    end)

    it("fails without deleting when the catalog stays busy", function()
        local Handler, calls, _, masksOf, photos = setup({
            photos = photosWithEmptyMasks(), writeAccessAborts = function() return true end,
        })

        assert.are.same({ "failed", helper.catalogBusy("Delete Empty Masks") }, { helper.outcomeOf(function(context)
            Handler.deleteEmptyMasks({ photo_ids = { "1" } }, context)
        end) })
        assert.are.same({}, calls.deleteAllEmpty)
        assert.are.same({ "a", "empty-a" }, idsOf(masksOf[photos[1]]))
    end)

    it("counts zero when no photo has an empty mask", function()
        local Handler = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteEmptyMasks({ photo_ids = { "2", "4" } })

        assert.are.same({ photos_checked = 2, changed = {} }, r.data)
    end)

    it("only touches the photos it was given", function()
        local Handler, _, _, masksOf, photos = setup({ photos = photosWithEmptyMasks() })

        Handler.deleteEmptyMasks({ photo_ids = { "1" } })

        assert.are.same({ "empty-b", "empty-c" }, idsOf(masksOf[photos[3]]))
    end)

    it("accepts numeric ids and file paths and passes each photo once", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteEmptyMasks({ photo_ids = { 1, "/1.jpg", "3" } })

        assert.are.equal(2, #r.data.changed)
        assert.are.equal(1, #calls.deleteAllEmpty)
        assert.are.equal(2, #calls.deleteAllEmpty[1])
    end)

    it("reports unknown ids and still processes the known photos", function()
        local Handler = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteEmptyMasks({ photo_ids = { "1", "404" } })

        assert.are.same({ photos_checked = 1, changed = { { photo_id = "1", masks_removed = 1 } } }, r.data)
        assert.are.same({ "404" }, r.not_found)
    end)

    it("never calls Lightroom with an empty photo list because that targets the whole selection", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteEmptyMasks({ photo_ids = { "404", "405" } })

        assert.is_nil(r.data)
        assert.are.same({ "404", "405" }, r.not_found)
        assert.are.equal(0, #calls.deleteAllEmpty)
    end)

    it("does not open Develop or change the selection", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })

        Handler.deleteEmptyMasks({ photo_ids = { "1", "3" } })

        assert.are.equal(0, #calls.modules)
        assert.are.equal(0, #calls.selections)
    end)

    it("resolves photos before the write gate and reads inside read gates only", function()
        local Handler, _, catalog = setup({ photos = photosWithEmptyMasks() })

        Handler.deleteEmptyMasks({ photo_ids = { "1", "/3.jpg" } })

        assert.are.equal(1, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
