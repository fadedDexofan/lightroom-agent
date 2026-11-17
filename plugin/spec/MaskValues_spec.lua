local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = "ABCDEF0123456789ABCDEF0123456789"

local function subject(overrides)
    local entry = Store.correction("Subject", { {
        What = "Mask/Image", MaskActive = true, MaskInverted = false, MaskBlendMode = 0, MaskValue = 1,
        MaskSubType = 1, MaskID = "C1T1", MaskSyncID = "SC1T1", MaskDigest = DIGEST, InputDigest = DIGEST,
    } }, {
        CorrectionID = "C1", CorrectionSyncID = "CS1", CorrectionReferenceX = 0.5, CorrectionReferenceY = 0.4,
        LocalCurveRefineSaturation = 100, LocalExposure2012 = 0.25, LocalContrast2012 = 0.1, LocalHue = 0,
        LocalTexture = 0.2366, LocalColorGradeMidtoneHue = 62,
    })
    for key, value in pairs(overrides or {}) do entry[key] = value end
    return entry
end

local function brush()
    return Store.correction("Brush", { Store.brushComponent({ MaskID = "C2T1", MaskSyncID = "SC2T1" }) },
        { CorrectionID = "C2", CorrectionSyncID = "CS2" })
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local other = helper.fakePhoto({ id = "2", path = "/2.jpg" })
    local store = Store.attach(photo, {
        entries = opts.entries or { subject(opts.subject), brush() },
        transformWrite = opts.transformWrite,
    })
    local catalog = helper.fakeCatalog({ photos = { photo, other }, writeAccessAborts = opts.writeAccessAborts })
    Store.trackGates(store, catalog)
    local readInsideWrite = 0
    local getDevelopSettings = photo.getDevelopSettings
    photo.getDevelopSettings = function(self)
        if store.insideWrite then readInsideWrite = readInsideWrite + 1 end
        return getDevelopSettings(self)
    end
    if opts.beforeGate then
        local withWriteAccessDo = catalog.withWriteAccessDo
        catalog.withWriteAccessDo = function(self, ...)
            opts.beforeGate(store)
            return withWriteAccessDo(self, ...)
        end
    end
    catalog.getTargetPhoto = function() return opts.target == "other" and other or photo end
    local flushes = {}
    helper.admitMaskWrites({ refuse = "Mask geometry writes are not certified." })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = { getCurrentModuleName = function() return opts.module or "library" end },
        LrDevelopController = {
            stopTracking = function(committed)
                flushes[#flushes + 1] = { committed = committed, reads = store.reads, attempts = store.attempts }
            end,
        },
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "MaskValues", "GuardedMaskWrite", "LocalSliders", "JsonValue", "CatalogWrite", "DevelopSession" }) do
        package.loaded[name] = nil
    end
    local ctx = { store = store, catalog = catalog, photo = photo, flushes = flushes }
    function ctx.readsInsideWrite() return readInsideWrite end
    return require 'MaskValues', ctx
end

describe("MaskValues.read", function()
    it("reads every local slider of the mask named by its id from the saved settings", function()
        local MaskValues, ctx = setup()

        local values = MaskValues.read(ctx.catalog, ctx.photo, "C1")

        assert.are.equal(1, values.adjustments.local_Exposure)
        assert.are.equal(10, values.adjustments.local_Contrast)
        assert.are.equal(23.66, values.adjustments.local_Texture)
        assert.are.equal(62, values.adjustments.local_colorgradeMidtoneHue)
        assert.are.equal(0, values.adjustments.local_Shadows)
        assert.are.equal(50, values.adjustments.local_colorgradeBlending)
        local count = 0
        for _ in pairs(values.adjustments) do count = count + 1 end
        assert.are.equal(#require('LocalSliders').list, count)
        assert.are.equal(0, ctx.catalog.getWriteAccessCount())
    end)

    it("refuses an id that is not in the saved settings, naming the saved ones", function()
        local MaskValues, ctx = setup()

        local refusal = helper.failedOf(function() MaskValues.read(ctx.catalog, ctx.photo, "C9") end)

        assert.matches("Mask C9 is not in the saved settings of photo 1 (saved masks: C1, C2)", refusal, 1, true)
        assert.matches("a mask made in Develop in the last few seconds may not be saved yet", refusal, 1, true)
    end)
end)

describe("MaskValues.write", function()
    it("changes only the named slider field of the mask and turns the mask on", function()
        local MaskValues, ctx = setup({ subject = { CorrectionActive = false } })
        local expected = Store.clone(ctx.store.entries)
        expected[1].LocalExposure2012 = 0.125
        expected[1].CorrectionActive = true

        local result = MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

        assert.are.same(expected, ctx.store.entries)
        assert.are.equal(1, result.before.adjustments.local_Exposure)
        assert.are.equal(0.5, result.after.adjustments.local_Exposure)
        assert.are.same({ "LocalExposure2012" }, result.written)
        assert.are.equal(1, ctx.store.attempts)
    end)

    it("writes nothing and opens no gate when every value is already stored", function()
        local MaskValues, ctx = setup({ subject = { CorrectionActive = false } })

        local result = MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1",
            { adjustments = { local_Exposure = 1, local_Shadows = 0 } })

        assert.are.same({}, result.written)
        assert.are.equal(0, ctx.store.attempts)
        assert.are.equal(0, ctx.catalog.getWriteAccessCount())
        assert.is_false(ctx.store.entries[1].CorrectionActive)
    end)

    it("writes the stored whole number of a colour-grade slider and reports it", function()
        local MaskValues, ctx = setup()

        local result = MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_colorgradeShadowHue = 222.59 } })

        assert.are.equal(223, ctx.store.entries[1].LocalColorGradeShadowHue)
        assert.are.equal(223, result.after.adjustments.local_colorgradeShadowHue)
    end)

    it("builds the write on a read inside the write gate, keeping a change that landed just before it", function()
        local MaskValues, ctx = setup({
            beforeGate = function(store) store.entries[2].LocalExposure2012 = 0.5 end,
        })

        MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Contrast = 20 } })

        assert.are.equal(0.2, ctx.store.entries[1].LocalContrast2012)
        assert.are.equal(0.5, ctx.store.entries[2].LocalExposure2012)
        assert.is_true(ctx.readsInsideWrite() >= 1)
    end)

    for _, case in ipairs({
        { kept = "a sibling mask's brush dab", change = function(entries) entries[2].CorrectionMasks[1].Masks[1].Dabs[1] = "d 0.9 0.9" end },
        { kept = "the mask's sync id", change = function(entries) entries[1].CorrectionSyncID = "CS1-new" end },
        { kept = "a component digest", change = function(entries) entries[1].CorrectionMasks[1].MaskDigest = nil end },
        { kept = "another field of the mask", change = function(entries) entries[1].LocalContrast2012 = 0.11 end },
        { kept = "a field the write did not name", change = function(entries) entries[1].LocalTint = 0 end },
    }) do
        it("restores the photo and refuses when Lightroom does not keep " .. case.kept .. " exactly", function()
            local MaskValues, ctx = setup({
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then case.change(stored) end
                    return stored
                end,
            })
            local before = Store.clone(ctx.store.entries)

            local refusal = helper.failedOf(function()
                MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })
            end)

            assert.matches("previous masks were restored", refusal, 1, true)
            assert.are.same(before, ctx.store.entries)
        end)
    end

    it("writes nothing inside the gate when the requested value landed between its first read and the gate", function()
        local MaskValues, ctx = setup({
            subject = { CorrectionActive = false },
            beforeGate = function(store) store.entries[1].LocalExposure2012 = 0.125 end,
        })

        local context = helper.requestContext()

        local result = MaskValues.write(context, ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

        assert.are.same({}, result.written)
        assert.are.equal(0, ctx.store.attempts)
        assert.is_false(ctx.store.entries[1].CorrectionActive)
        assert.are.same({}, context.warnings)
    end)

    it("answers unknown when the restore reads back a difference only the exact comparison sees", function()
        local MaskValues, ctx = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].LocalContrast2012 = 0.11 end
                if writeNumber == 2 then stored[1].LocalTexture = 0.2366 + 1e-6 end
                return stored
            end,
        })

        local err = helper.unknownOf(function()
            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })
        end)

        assert.matches("could not be confirmed restored", err, 1, true)
    end)

    it("writes a slider as the six decimal places Lightroom stores and reports that value", function()
        local MaskValues, ctx = setup()

        local result = MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.33333333 } })

        assert.are.equal(0.083333, ctx.store.entries[1].LocalExposure2012)
        assert.are.equal(0.333332, result.after.adjustments.local_Exposure)
    end)

    it("names what was written and what Lightroom stored when it stores another value", function()
        local MaskValues, ctx = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].LocalExposure2012 = 0.083334 end
                return stored
            end,
        })

        local refusal = helper.failedOf(function()
            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.33333333 } })
        end)

        assert.matches("local_Exposure: wrote 0.333332, Lightroom stored 0.333336", refusal, 1, true)
        assert.matches("previous masks were restored", refusal, 1, true)
    end)

    it("names the curve Lightroom did not keep and restores the photo", function()
        local MaskValues, ctx = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].MainCurve = nil end
                return stored
            end,
        })

        local refusal = helper.failedOf(function()
            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { curves = { main = { 0, 0, 64, 48, 255, 255 } } })
        end)

        assert.matches("main curve: wrote 0,0 64,48 255,255, Lightroom stored nothing", refusal, 1, true)
        assert.is_nil(ctx.store.entries[1].MainCurve)
    end)

    it("reads a channel from its Extended field first, then the plain field, else linear", function()
        local MaskValues, ctx = setup({ subject = {
            ExtendedRedCurve = { "0,0", "128,160", "255,255" }, RedCurve = { "0,0", "64,48", "255,255" },
            GreenCurve = { "0,0", "64,48", "255,255" },
        } })

        local curves = MaskValues.read(ctx.catalog, ctx.photo, "C1").curves

        assert.are.same({ 0, 0, 128, 160, 255, 255 }, curves.red)
        assert.are.same({ 0, 0, 64, 48, 255, 255 }, curves.green)
        assert.are.same({ 0, 0, 255, 255 }, curves.main)
    end)

    it("fails with nothing written when the catalog stays busy", function()
        local MaskValues, ctx = setup({ writeAccessAborts = function() return true end })
        local before = Store.clone(ctx.store.entries)

        local class, message = helper.outcomeOf(function(context)
            MaskValues.write(context, ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })
        end)

        assert.are.same({ "failed", helper.catalogBusy("Set Mask Adjustments") }, { class, message })
        assert.are.same(before, ctx.store.entries)
    end)

    it("needs no certification, which a constructing write still needs", function()
        local unpinned = Store.correction("Odd", { { What = "Mask/Unknown", MaskID = "C3T1", Shape = "new" } },
            { CorrectionID = "C3" })
        local MaskValues, ctx = setup({ entries = { subject(), unpinned } })

        MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

        assert.are.equal(0.125, ctx.store.entries[1].LocalExposure2012)
        local refusal = helper.failedOf(function()
            require('GuardedMaskWrite').apply(helper.requestContext(), ctx.catalog, ctx.photo, {
                description = "Create gradient mask",
                build = function(entries) return entries end,
            })
        end)
        assert.matches("not certified", refusal, 1, true)
    end)

    local function colorRange(samples)
        return { What = "Mask/RangeMask", MaskID = "C3T1",
            CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = samples } }
    end

    for _, case in ipairs({
        { held = "two samples", component = colorRange({ "0.1 0.4 0.5", "0.6 0.5 0.4" }) },
        { held = "two samples inside a group of components", component = {
            What = "Mask/Aggregate", MaskID = "C3T1", Masks = { colorRange({ "0.1 0.4 0.5", "0.6 0.5 0.4" }) },
        } },
    }) do
        it("writes a value beside a color range Lightroom stored with " .. case.held .. ", resending it unchanged", function()
            local entry = Store.correction("Colors", { case.component }, { CorrectionID = "C3" })
            local MaskValues, ctx = setup({ entries = { subject(), brush(), Store.clone(entry) } })

            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

            assert.are.equal(1, ctx.store.attempts)
            assert.are.equal(0.125, ctx.store.entries[1].LocalExposure2012)
            assert.are.same(entry, ctx.store.entries[3])
        end)
    end
end)

describe("MaskValues.write on a mask with a Point Color swatch it cannot read", function()
    local UNREADABLE = { LocalPointColors = { "1.0, 0.5" }, LocalColorVariance = { "0.000000" } }

    for _, case in ipairs({
        { kind = "slider", change = { adjustments = { local_Exposure = 0.5 } },
            stored = function(entry) return entry.LocalExposure2012 end, expected = 0.125 },
        { kind = "curve", change = { curves = { red = { 0, 10, 255, 245 } } },
            stored = function(entry) return entry.RedCurve end, expected = { "0,10", "255,245" } },
    }) do
        it("writes and reports a " .. case.kind .. " change, decoding only what the change names", function()
            local MaskValues, ctx = setup({ subject = UNREADABLE })

            local result = MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", case.change)

            assert.are.same(case.expected, case.stored(ctx.store.entries[1]))
            assert.is_nil(result.after.swatches)
        end)
    end

    it("refuses a swatch update before any gate, naming the unreadable swatch", function()
        local MaskValues, ctx = setup({ subject = UNREADABLE })

        local refusal = helper.failedOf(function()
            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { swatch = { action = "update", index = 1, fields = { HueShift = 0.2 } } })
        end)

        assert.matches("Lightroom stored an unreadable Point Color swatch at index 1", refusal, 1, true)
        assert.are.equal(0, ctx.catalog.getWriteAccessCount())
    end)
end)

describe("MaskValues.write updating a Point Color swatch", function()
    local SWATCH = "3.000000, 0.500000, 0.500000, 0.000000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333,"
        .. " 0.666667, 1.000000, 0.000000, 0.320000, 0.680000, 1.000000, 0.005357, 0.555357, 0.915357, 1.000000"

    for _, case in ipairs({
        { range = "HueRange", edges = { LowerNone = 0.6, LowerFull = 0.2, UpperFull = 0.9, UpperNone = 0.4 } },
        { range = "LumRange", edges = { LowerNone = 0, LowerFull = 0.5, UpperFull = 0.9, UpperNone = 0.8 } },
        { range = "LumRange", edges = { LowerNone = 0, LowerFull = 0.7, UpperFull = 0.5, UpperNone = 1 } },
    }) do
        it("refuses unordered " .. case.range .. " edges before any gate, since Lightroom drops every swatch then", function()
            local MaskValues, ctx = setup({ subject = { LocalPointColors = { SWATCH }, LocalColorVariance = { "0.000000" } } })
            local before = Store.clone(ctx.store.entries)

            local refusal = helper.failedOf(function()
                MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1",
                    { swatch = { action = "update", index = 1, fields = { [case.range] = case.edges } } })
            end)

            assert.matches("Point Color swatch 1's " .. case.range .. " edges are not ordered", refusal, 1, true)
            assert.are.equal(0, ctx.catalog.getWriteAccessCount())
            assert.are.same(before, ctx.store.entries)
        end)
    end
end)

describe("MaskValues.write deleting a Point Color swatch", function()
    it("restores the photo and refuses, naming both counts, when Lightroom keeps the deleted swatch", function()
        local swatch = "3.000000, 0.500000, 0.500000, 0.000000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333,"
            .. " 0.666667, 1.000000, 0.000000, 0.320000, 0.680000, 1.000000, 0.005357, 0.555357, 0.915357, 1.000000"
        local MaskValues, ctx = setup({
            subject = { LocalPointColors = { swatch, (swatch:gsub("^3", "1")) }, LocalColorVariance = { "0.000000", "0.000000" } },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then
                    stored[1].LocalPointColors[2] = swatch
                    stored[1].LocalColorVariance[2] = "0.000000"
                end
                return stored
            end,
        })
        local before = Store.clone(ctx.store.entries)

        local refusal = helper.failedOf(function()
            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { swatch = { action = "delete", index = 1 } })
        end)

        assert.matches("Point Color LocalPointColors: wrote 1 entries, Lightroom stored 2 entries", refusal, 1, true)
        assert.matches("previous masks were restored", refusal, 1, true)
        assert.are.same(before, ctx.store.entries)
    end)
end)

describe("MaskValues.write on the photo open in Develop", function()
    it("flushes Develop's pending edits before it reads the snapshot it writes on", function()
        local MaskValues, ctx = setup({ module = "develop" })

        MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

        assert.are.same({ { committed = true, reads = 1, attempts = 0 } }, ctx.flushes)
        assert.are.equal(0.125, ctx.store.entries[1].LocalExposure2012)
    end)

    for _, case in ipairs({
        { where = "in Library", opts = { module = "library" } },
        { where = "in Develop on another photo", opts = { module = "develop", target = "other" } },
    }) do
        it("flushes nothing " .. case.where, function()
            local MaskValues, ctx = setup(case.opts)

            MaskValues.write(helper.requestContext(), ctx.catalog, ctx.photo, "C1", { adjustments = { local_Exposure = 0.5 } })

            assert.are.same({}, ctx.flushes)
        end)
    end
end)
