local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = Store.DIGEST

local function existingGradient()
    return Store.correction("Gradient", { Store.linearComponent({ MaskID = "A1", MaskSyncID = "SA1" }) },
        { CorrectionID = "mask-a", LocalExposure2012 = 0.25 })
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries or { existingGradient() }, transformWrite = opts.transformWrite,
        settings = opts.settings, writtenEmptyKept = opts.writtenEmptyKept })
    local calls = { updateAI = 0, modules = {} }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            for key, value in pairs(opts.computeChanges or {}) do opts.settings[key] = value end
            Store.computeAI(store, function(_, component)
                if opts.nothingFound and component.MaskDigest == nil then
                    return opts.errorReason and { ErrorReason = opts.errorReason } or "absent"
                end
                if opts.neverCompute then return "pending" end
                return "computed"
            end)
            if opts.keepsTwo then
                local copy = Store.clone(store.entries[#store.entries])
                copy.CorrectionID, copy.CorrectionSyncID = "C-extra", "CS-extra"
                store.entries[#store.entries + 1] = copy
            end
        end
    end
    local catalog = helper.fakeCatalog({ photos = { photo } })
    Store.trackGates(store, catalog)
    catalog.getTargetPhoto = function() return photo end
    helper.admitMaskWrites(opts.maskWrites)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) calls.modules[#calls.modules + 1] = name end,
        },
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskCreate", "HandlerAiMasks", "AIMaskCompute", "GuardedMaskWrite", "MaskTypes", "MaskValues",
        "DevelopSession" }) do
        package.loaded[name] = nil
    end
    calls.catalog, calls.photo = catalog, photo
    return require 'HandlerMaskCreate', store, calls
end

local SEEDS = {
    subject = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 1, MaskName = "Subject 1", MaskActive = true,
        MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    sky = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 2, MaskName = "Sky 1", MaskActive = true,
        MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    background = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 0, MaskSubCategoryID = 22, MaskName = "Background 1",
        MaskActive = true, MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
}

describe("HandlerMaskCreate.createMask Subject, Sky and Background in the saved settings", function()
    for _, typeName in ipairs({ "subject", "sky", "background" }) do
        it("writes a " .. typeName .. " entry from the kind's seed, lets Lightroom compute it and returns its id", function()
            local Handler, store, calls = setup()
            local other = Store.clone(store.entries[1])
            local context = helper.requestContext(nil, { title = "create_mask" })

            local r = Handler.createMask({ photo_id = "1", type = typeName }, context)

            local entry = Store.clone(store.writes[1][2])
            assert.are.same({ SEEDS[typeName] }, entry.CorrectionMasks)
            assert.are.equal("Correction", entry.What)
            assert.is_nil(entry.CorrectionID)
            assert.are.equal("C1", r.mask_id)
            assert.are.equal(typeName, r.type)
            assert.are.equal(DIGEST, store.entries[2].CorrectionMasks[1].MaskDigest)
            assert.are.same(other, store.entries[1])
            assert.are.equal(1, calls.updateAI)
            assert.are.same({}, calls.modules)
            assert.are.same({}, context.warnings)
            assert.is_nil(r.adjustments)
        end)
    end

    it("writes the requested adjustments into the new entry and reports them as Lightroom stored them", function()
        local Handler, store = setup()

        local r = Handler.createMask({ photo_id = "1", type = "sky",
            adjustments = { local_Exposure = 0.5, local_colorgradeMidtoneHue = 62.4, local_Texture = 23.66666666 } })

        local entry = store.entries[2]
        assert.are.equal(0.125, entry.LocalExposure2012)
        assert.are.equal(62, entry.LocalColorGradeMidtoneHue)
        assert.is_nil(entry.LocalShadows2012)
        assert.are.same({ local_Exposure = 0.5, local_colorgradeMidtoneHue = 62, local_Texture = 23.6667 }, r.adjustments)
    end)

    it("removes the new mask and refuses, with no alert to dismiss, when Lightroom finds nothing", function()
        local Handler, store = setup({ nothingFound = true })
        local before = Store.clone(store.entries)

        local err = helper.failedOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.are.equal("Lightroom found nothing for the subject mask on photo 1 (Subject 1); the new masks were removed",
            err)
        assert.is_nil(err:find("alert", 1, true))
        assert.are.same(before, store.entries)
    end)

    for _, case in ipairs({
        { what = "fails when Update AI Settings changed nothing else on the photo", changes = {}, class = "failed",
          message = "Lightroom found nothing for the subject mask on photo 1 (Subject 1); the new masks were removed" },
        { what = "answers unknown, naming the other settings Update AI Settings changed", class = "unknown",
          changes = { DepthMapInfo = { Digest = "fresh" }, FilterList = { Filters = { { CompressedSettings = "new" } } } },
          message = "Lightroom found nothing for the subject mask on photo 1 (Subject 1); the new masks were removed,"
              .. " but Update AI Settings also changed DepthMapInfo, FilterList on the photo; written before this"
              .. " stopped: updateAISettings, Update AI Settings" },
    }) do
        it("removes the new mask when Lightroom finds nothing and " .. case.what, function()
            local Handler, store = setup({ nothingFound = true, computeChanges = case.changes, entries = {},
                writtenEmptyKept = true,
                settings = { DepthMapInfo = { Digest = "stale" }, FilterList = { Filters = { { CompressedSettings = "old" } } },
                    Exposure2012 = 0.5 } })
            local before = Store.clone(store.entries)

            local class, message = helper.outcomeOf(function(context)
                Handler.createMask({ photo_id = "1", type = "subject" }, context)
            end)

            assert.are.equal(case.class, class, message)
            assert.are.equal(case.message, message)
            assert.are.same(before, store.entries)
        end)
    end

    it("puts the photo back and fails when Lightroom keeps two masks for the one it was asked to make", function()
        local Handler, store = setup({ keepsTwo = true })
        local before = Store.clone(store.entries)

        local err = helper.failedOf(function() Handler.createMask({ photo_id = "1", type = "sky" }) end)

        assert.are.equal("Lightroom kept 2 of the 1 requested masks on photo 1; the new masks were removed", err)
        assert.are.same(before, store.entries)
    end)

    it("names the ErrorReason, and does not say nothing was found, when Lightroom fails the mask for another reason", function()
        local Handler, store = setup({ nothingFound = true, errorReason = 3 })
        local before = Store.clone(store.entries)

        local err = helper.failedOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.are.equal("Lightroom could not compute the subject mask on photo 1 (Subject 1: ErrorReason 3, another failure); the new"
            .. " masks were removed", err)
        assert.are.same(before, store.entries)
    end)

    it("answers unknown and writes nothing more while Lightroom is still computing at the limit", function()
        local Handler, store = setup({ neverCompute = true })

        local message = helper.unknownOf(function() Handler.createMask({ photo_id = "1", type = "sky" }) end)

        assert.truthy(message:find("has not finished computing the AI masks of photo 1", 1, true), message)
        assert.are.equal(1, #store.writes)
        assert.are.equal(2, #store.entries)
    end)

    it("is a certified operation", function()
        local Handler, store = setup({ maskWrites = { refuse = "Mask geometry writes are not certified." } })

        local err = helper.failedOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.truthy(err:find("not certified", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)

    it("accepts a file path and answers with the photo's own id", function()
        local Handler = setup()

        local r = Handler.createMask({ photo_id = "/1.jpg", type = "sky" })

        assert.are.equal("1", r.photo_id)
    end)

    it("answers not_found for an unknown photo", function()
        local Handler = setup()
        assert.are.equal("404", helper.notFoundOf(function() Handler.createMask({ photo_id = "404", type = "sky" }) end))
    end)
end)

describe("HandlerMaskCreate.createMask replying with the stored adjustments", function()
    it("reads a requested slider Lightroom stored as absent at its neutral value as that value", function()
        local Handler = setup({ transformWrite = function(stored)
            stored[#stored].LocalExposure2012 = nil
            return stored
        end })

        local r = Handler.createMask({ photo_id = "1", type = "sky", adjustments = { local_Exposure = 0, local_Contrast = 20 } },
            helper.requestContext(nil, { title = "create_mask" }))

        assert.are.same({ local_Exposure = 0, local_Contrast = 20 }, r.adjustments)
    end)
end)

describe("AIMaskCompute.run putting a full copy's target back when Lightroom finds nothing", function()
    local samples = { "0.1 0.4 0.5 0.2 0.3 0", "0.6 0.5 0.4 0.7 0.8 0" }
    for _, case in ipairs({
        { held = "an Extended mask curve", entry = Store.correction("Own", { Store.linearComponent({ MaskID = "O1",
            MaskSyncID = "SO1" }) }, { CorrectionID = "own", ExtendedMainCurve = { "0,0", "40,30", "255,255" } }) },
        { held = "a colour range with two samples", entry = Store.correction("Own", { { What = "Mask/RangeMask",
            MaskActive = true, MaskID = "O1", MaskSyncID = "SO1",
            CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = samples } } }, { CorrectionID = "own" }) },
        { held = "an empty group", entry = Store.correction("Own", {}, { CorrectionID = "own" }) },
    }) do
        it("restores the target's own masks holding " .. case.held .. " exactly", function()
            local _, store, calls = setup({ entries = { case.entry }, nothingFound = true })
            local own = Store.clone(store.entries)
            local AIMaskCompute = require 'AIMaskCompute'
            local copied = Store.correction("Subject 1", { Store.clone(SEEDS.subject) })

            local class, message = helper.outcomeOf(function(context)
                AIMaskCompute.run(context, calls.catalog, calls.photo, {
                    description = "Copy Develop Settings", subject = "the copied AI masks", replaces = true,
                    build = function() return { Store.clone(copied) } end,
                })
            end)

            assert.are.same(own, store.entries, message)
            assert.are.equal(2, #store.writes)
            assert.matches("the new masks were removed", message, 1, true)
            assert.are.equal("failed", class, message)
        end)
    end
end)
