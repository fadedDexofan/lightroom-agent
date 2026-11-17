local helper = require 'spec_helper'

local function tool(id, type, inverted)
    return { ID = id, Name = type .. " " .. id, Type = type, Hidden = false, Inverted = inverted }
end

local function mask(id, name, tools)
    return { ID = id, Name = name, Hidden = false, Tools = tools }
end

local function setup(opts)
    local photos, masksOf = {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[#photos + 1] = p
        masksOf[p] = spec.masks or {}
    end
    local active = photos[1]
    local module = "library"
    local calls = { modules = {}, selections = {}, goToMasking = 0, invert = {}, duplicate = {} }
    local listBroken = false
    local selected

    local function currentMasks() return masksOf[active] end
    local function findCurrent(id)
        for _, m in ipairs(currentMasks()) do
            if m.ID == id then return m end
        end
        return nil
    end

    local controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            if listBroken then error("mask list unavailable") end
            return currentMasks()
        end,
        selectMask = function(id) selected = id end,
        getSelectedMask = function() return selected end,
        selectMaskTool = function() end,
        goToMasking = function() calls.goToMasking = calls.goToMasking + 1 end,
        invertMask = function(id)
            calls.invert[#calls.invert + 1] = id
            if opts.invertReturns ~= nil then return opts.invertReturns end
            if opts.invertThrows then error(opts.invertThrows) end
            if opts.invertIsIgnored then return true end
            if opts.listUnreadableAfterInvert then listBroken = true; return true end
            local target = findCurrent(id)
            for _, t in ipairs(target.Tools) do t.Inverted = not t.Inverted end
            return true
        end,
        duplicateAndInvertMask = function(id) calls.duplicate[#calls.duplicate + 1] = id end,
    }
    for _, name in ipairs(opts.withoutFunctions or {}) do controller[name] = nil end

    local view = {
        getCurrentModuleName = function() return module end,
        switchToModule = function(name)
            module = name
            calls.modules[#calls.modules + 1] = name
        end,
    }
    local catalog = helper.fakeCatalog({ photos = photos })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    helper.admitMaskWrites()
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = view,
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskInvert", "DevelopSession", "MaskSelection", "MaskValues", "GuardedMaskWrite" }) do
        package.loaded[name] = nil
    end
    local Handler = require 'HandlerMaskInvert'
    return Handler, calls, masksOf, catalog
end

local function subjectMasks()
    return {
        mask("m-1", "Subject", { tool("t-1", "aiSelection", false), tool("t-2", "brush", false) }),
        mask("m-2", "Sky", { tool("t-3", "aiSelection", false) }),
    }
end

local function args(overrides)
    local base = { photo_id = "1", mask_id = "m-1", mode = "in_place" }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

describe("HandlerMaskInvert.invertMask in place", function()
    it("inverts the chosen mask and reports the new tool states", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args())

        assert.are.equal("1", r.photo_id)
        assert.are.equal("in_place", r.mode)
        assert.are.equal("m-1", r.mask_id)
        assert.is_nil(r.source_mask_id)
        assert.are.same({
            id = "m-1",
            name = "Subject",
            tools = { { id = "t-1", inverted = true }, { id = "t-2", inverted = true } },
        }, r.mask)
        assert.are.same({ "m-1" }, calls.invert)
        assert.are.same({}, calls.duplicate)
    end)

    it("leaves the other masks of the photo unchanged", function()
        local Handler, _, masksOf = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        Handler.invertMask(args())

        local masks = masksOf[next(masksOf)]
        assert.is_false(masks[2].Tools[1].Inverted)
    end)

    it("opens the masking tool before inverting and puts back module and selection", function()
        local Handler, calls = setup({
            photos = { { id = "1" }, { id = "2", masks = subjectMasks() } },
        })

        Handler.invertMask(args({ photo_id = "2" }))

        assert.are.equal(1, calls.goToMasking)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("chooses the mask by id and not by position", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args({ mask_id = "m-2" }))

        assert.are.equal("m-2", r.mask_id)
        assert.are.same({ "m-2" }, calls.invert)
        assert.are.same({ { id = "t-3", inverted = true } }, r.mask.tools)
    end)

    it("errors for an unknown mask id without calling invertMask", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local err = helper.refusalOf(function() Handler.invertMask(args({ mask_id = "nope" })) end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.are.same({}, calls.invert)
        assert.are.same({}, calls.duplicate)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("errors when the photo has no masks at all", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        local err = helper.refusalOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("Mask not found on photo 1: m-1", 1, true))
        assert.are.same({}, calls.invert)
    end)

    it("errors when Lightroom says the inversion failed", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } }, invertReturns = false })

        local err = helper.unknownOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("Lightroom refused invertMask on mask m-1", 1, true))
    end)

    it("reports the reason when invertMask raises", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } }, invertThrows = "boom" })

        local err = helper.unknownOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("could not run invertMask on mask m-1", 1, true))
        assert.truthy(err:find("boom", 1, true))
    end)

    it("errors when Lightroom accepts the call but the mask never changes", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            invertIsIgnored = true,
        })

        local err = helper.unknownOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("whether it is inverted is unknown", 1, true))
        assert.truthy(err:find("list_masks", 1, true))
        assert.is_nil(err:find("may not have been saved", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("answers unknown when the mask list cannot be read after invertMask", function()
        local Handler = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            listUnreadableAfterInvert = true,
        })

        local err = helper.unknownOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("whether it is inverted is unknown", 1, true), err)
    end)
end)

local Store = require 'fake_mask_store'

local DIGEST = "ABCDEF0123456789ABCDEF0123456789"

local function sourceEntries()
    return {
        Store.correction("Subject", {
            { What = "Mask/Image", MaskActive = true, MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 1,
                MaskID = "C1T1", MaskSyncID = "SC1T1", MaskDigest = DIGEST, MaskName = "Subject 1" },
        }, {
            CorrectionID = "m-1", CorrectionSyncID = "CS1", CorrectionReferenceX = 0.3, CorrectionReferenceY = 0.7,
            CorrectionAmount = 0.8, LocalExposure2012 = 0.3125, LocalHue = 0.1, LocalCurveRefineSaturation = 100,
            MainCurve = { "0,0", "64,48", "255,255" },
            LocalPointColors = { "3.000000, 0.500000, 0.500000, 0.250000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333,"
                .. " 0.666667, 1.000000, 0.000000, 0.320000, 0.680000, 1.000000, 0.005357, 0.555357, 0.915357, 1.000000" },
            LocalColorVariance = { "0.300000" },
        }),
        Store.correction("Sky", { Store.linearComponent({ MaskID = "C2T1" }) }, { CorrectionID = "m-2", LocalExposure2012 = -0.25 }),
    }
end

local function nativeCopy(source, id)
    local copy = { What = "Correction", CorrectionID = id, CorrectionSyncID = "CS-" .. id, CorrectionName = source.CorrectionName .. " Inverted",
        CorrectionActive = true, CorrectionAmount = 1, CorrectionReferenceX = 0.5, CorrectionReferenceY = 0.5,
        LocalExposure2012 = 0, LocalHue = 0, LocalCurveRefineSaturation = 100, CorrectionMasks = Store.clone(source.CorrectionMasks) }
    for index, component in ipairs(copy.CorrectionMasks) do
        component.MaskID = id .. "T" .. index
        component.MaskSyncID = "S" .. id .. "T" .. index
        if index == 1 then component.MaskInverted = not component.MaskInverted end
    end
    return copy
end

local function copySetup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries or sourceEntries(), transformWrite = opts.transformWrite })
    local catalog = helper.fakeCatalog({ photos = { photo } })
    Store.trackGates(store, catalog)
    local module, tool, selected = "library", opts.tool or "loupe", "m-2"
    local calls = { duplicate = {}, deleted = {}, modules = {}, tools = {} }
    local unsaved, readsUntilSaved = nil, opts.copySavedAfterReads or 0
    local listedOnly, duplicated = {}, false
    local getDevelopSettings = photo.getDevelopSettings
    photo.getDevelopSettings = function(self)
        if unsaved then
            if readsUntilSaved <= 0 then
                store.entries[#store.entries + 1] = unsaved
                unsaved = nil
            end
            readsUntilSaved = readsUntilSaved - 1
        end
        return getDevelopSettings(self)
    end
    local controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            local listed = {}
            for _, entry in ipairs(store.entries) do
                if not (duplicated and opts.sourceUnlistedAfterCopy and entry.CorrectionID == "m-1") then
                    listed[#listed + 1] = entry
                end
            end
            if unsaved then listed[#listed + 1] = unsaved end
            for _, entry in ipairs(listedOnly) do listed[#listed + 1] = entry end
            return Store.maskListOf(listed)
        end,
        getSelectedMask = function() return selected end,
        selectMask = function(id) selected = id end,
        getSelectedTool = function() return tool end,
        selectTool = function(name)
            tool = name
            calls.tools[#calls.tools + 1] = name
        end,
        selectMaskTool = function() end,
        goToMasking = function() tool = "masking" end,
        invertMask = function() return true end,
        deleteMask = function(id)
            calls.deleted[#calls.deleted + 1] = id
            if opts.deleteIgnored then return end
            if unsaved and unsaved.CorrectionID == id then unsaved = nil end
            for index = #store.entries, 1, -1 do
                if store.entries[index].CorrectionID == id then table.remove(store.entries, index) end
            end
        end,
        duplicateAndInvertMask = function(id)
            calls.duplicate[#calls.duplicate + 1] = id
            if opts.duplicateReturns ~= nil then return opts.duplicateReturns end
            if opts.duplicateIgnored then return true end
            for _, entry in ipairs(store.entries) do
                if entry.CorrectionID == id then
                    unsaved = nativeCopy(entry, "copy-1")
                    if opts.twoCopies then listedOnly[1] = nativeCopy(entry, "copy-2") end
                    if opts.damageSource then entry.CorrectionMasks[1].MaskInverted = true end
                end
            end
            if opts.neverSaved then readsUntilSaved = math.huge end
            duplicated = true
            selected = "copy-1"
            return true
        end,
    }
    catalog.getTargetPhoto = function() return photo end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end
    helper.admitMaskWrites({ refuse = "Mask geometry writes are not certified." })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                calls.modules[#calls.modules + 1] = name
            end,
        },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskInvert", "DevelopSession", "MaskSelection", "MaskValues", "GuardedMaskWrite" }) do
        package.loaded[name] = nil
    end
    calls.selected = function() return selected end
    calls.tool = function() return tool end
    return require 'HandlerMaskInvert', store, calls
end

describe("HandlerMaskInvert.invertMask as a copy", function()
    it("writes every value of the source onto Lightroom's inverted copy by id and leaves the source as it was", function()
        local Handler, store, calls = copySetup()
        local source = Store.clone(store.entries[1])

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal("copy", r.mode)
        assert.are.equal("m-1", r.source_mask_id)
        assert.are.equal("copy-1", r.mask_id)
        assert.is_nil(r.not_copied)
        assert.are.same({ id = "copy-1", name = "Subject Inverted", tools = { { id = "copy-1T1", inverted = true } } }, r.mask)
        assert.are.same({ "m-1" }, calls.duplicate)
        local copy = store.entries[3]
        assert.are.equal("copy-1", copy.CorrectionID)
        assert.are.equal("CS-copy-1", copy.CorrectionSyncID)
        assert.are.equal("Subject Inverted", copy.CorrectionName)
        assert.is_true(copy.CorrectionMasks[1].MaskInverted)
        assert.are.equal("copy-1T1", copy.CorrectionMasks[1].MaskID)
        assert.are.same({ 0.5, 0.5 }, { copy.CorrectionReferenceX, copy.CorrectionReferenceY })
        for _, key in ipairs({ "CorrectionAmount", "LocalExposure2012", "LocalHue", "MainCurve", "LocalPointColors",
            "LocalColorVariance", "LocalCurveRefineSaturation" }) do
            assert.are.same(source[key], copy[key])
        end
        assert.are.same(source, store.entries[1])
        assert.are.equal(1, store.attempts)
    end)

    it("removes a value the copy holds that the source does not", function()
        local entries = sourceEntries()
        entries[1].LocalHue = nil
        local Handler, store = copySetup({ entries = entries })

        Handler.invertMask(args({ mode = "copy" }))

        assert.is_nil(store.entries[3].LocalHue)
    end)

    it("waits until the copy is in the saved settings before writing to it", function()
        local Handler, store = copySetup({ copySavedAfterReads = 3 })

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal("copy-1", r.mask_id)
        assert.are.equal(0.3125, store.entries[3].LocalExposure2012)
    end)

    it("removes the copy and refuses when the copy never reaches the saved settings", function()
        local Handler, store, calls = copySetup({ neverSaved = true })

        local refusal = helper.refusalOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.matches("Lightroom did not save the inverted copy copy-1", refusal, 1, true)
        assert.matches("the copy was removed", refusal, 1, true)
        assert.are.same({ "copy-1" }, calls.deleted)
        assert.are.equal(2, #store.entries)
    end)

    it("removes the copy and refuses when Lightroom does not keep the copied values", function()
        local Handler, store, calls = copySetup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[3].LocalExposure2012 = 0 end
                return stored
            end,
        })

        local refusal = helper.refusalOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.matches("the copy was removed", refusal, 1, true)
        assert.are.same({ "copy-1" }, calls.deleted)
        assert.are.equal(2, #store.entries)
    end)

    it("puts back the tool and the selected mask after a copy made from the loupe", function()
        local Handler, _, calls = copySetup({ tool = "loupe" })

        Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal("loupe", calls.tool())
        assert.are.equal("m-2", calls.selected())
    end)

    for _, case in ipairs({
        { what = "Lightroom refuses the duplication", opts = { duplicateReturns = false },
          text = "Lightroom refused duplicateAndInvertMask on mask m-1" },
        { what = "no new mask appears", opts = { duplicateIgnored = true }, text = "did not create an inverted copy of mask m-1" },
    }) do
        it("answers unknown when " .. case.what, function()
            local Handler, store = copySetup(case.opts)

            local message = helper.unknownOf(function() Handler.invertMask(args({ mode = "copy" })) end)

            assert.matches(case.text, message, 1, true)
            assert.are.equal(0, store.attempts)
        end)
    end

    it("returns the copy and warns when Lightroom changed the source while copying", function()
        local Handler = copySetup({ damageSource = true })
        local context = helper.requestContext()

        local r = Handler.invertMask(args({ mode = "copy" }), context)

        assert.are.equal("copy-1", r.mask_id)
        assert.are.equal(1, #context.warnings)
        assert.truthy(context.warnings[1]:find("changed the source mask m-1", 1, true))
    end)

    local function keptNothing(stored, writeNumber)
        stored[#stored].LocalTexture = 0.5 * writeNumber
        return stored
    end

    for _, case in ipairs({
        { what = "the restore after a failed copy is not confirmed", opts = { transformWrite = keptNothing },
          texts = { "could not be confirmed restored", "the copy was removed: read the masks with list_masks" },
          deleted = { "copy-1" } },
        { what = "Lightroom still lists the copy after deleting it", opts = { neverSaved = true, deleteIgnored = true },
          texts = { "Lightroom did not save the inverted copy copy-1", "copy-1" }, deleted = { "copy-1" } },
        { what = "the copy fails after Lightroom changed the source", opts = { neverSaved = true, damageSource = true },
          texts = { "the copy was removed, but Lightroom changed the source mask m-1" }, deleted = { "copy-1" } },
        { what = "Lightroom made two new masks", opts = { twoCopies = true },
          texts = { "Lightroom created 2 new masks on photo 1 while copying mask m-1; cannot tell which is the copy" },
          deleted = {} },
    }) do
        it("answers unknown when " .. case.what, function()
            local Handler, _, calls = copySetup(case.opts)

            local message = helper.unknownOf(function() Handler.invertMask(args({ mode = "copy" })) end)

            for _, text in ipairs(case.texts) do assert.matches(text, message, 1, true) end
            assert.are.same(case.deleted, calls.deleted)
        end)
    end

    it("returns the copy and warns when Lightroom no longer lists the source after copying", function()
        local Handler = copySetup({ sourceUnlistedAfterCopy = true })
        local context = helper.requestContext()

        local r = Handler.invertMask(args({ mode = "copy" }), context)

        assert.are.equal("copy-1", r.mask_id)
        assert.are.equal(1, #context.warnings)
        assert.truthy(context.warnings[1]:find("no longer lists the source mask m-1", 1, true))
    end)

    it("refuses a source that is not in the saved settings without duplicating anything", function()
        local Handler, _, calls = copySetup()

        local refusal = helper.refusalOf(function() Handler.invertMask(args({ mode = "copy", mask_id = "m-9" })) end)

        assert.matches("Mask m-9 is not in the saved settings of photo 1", refusal, 1, true)
        assert.are.same({}, calls.duplicate)
    end)
end)

describe("HandlerMaskInvert.invertMask arguments", function()
    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({ photos = { { id = "7", masks = subjectMasks() } } })

        assert.are.equal("7", Handler.invertMask(args({ photo_id = 7 })).photo_id)
        assert.are.equal("7", Handler.invertMask(args({ photo_id = "/7.jpg", mask_id = "m-2" })).photo_id)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        assert.are.equal("404", helper.notFoundOf(function() Handler.invertMask(args({ photo_id = "404" })) end))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when an invert function is missing", function()
        for _, missing in ipairs({ "invertMask", "duplicateAndInvertMask", "goToMasking" }) do
            local Handler, calls = setup({
                photos = { { id = "1", masks = subjectMasks() } },
                withoutFunctions = { missing },
            })

            local refusal = helper.refusalOf(function() Handler.invertMask(args()) end)

            assert.are.equal("invert_mask needs LrDevelopController." .. missing
                .. ", which this Lightroom does not offer (Lightroom Classic 11.4 or later has it)", refusal)
            assert.are.equal(0, #calls.modules)
        end
    end)

    it("names the older mask API requirement when mask reading is missing", function()
        local Handler = setup({
            photos = { { id = "1" } },
            withoutFunctions = { "getAllMasks" },
        })

        local err = helper.refusalOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("^invert_mask needs LrDevelopController%.%a+, which this Lightroom does not offer %(Lightroom Classic 11 or later has it%)$"))
    end)

    it("never opens a catalog gate", function()
        local Handler, _, _, catalog = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        Handler.invertMask(args())

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
