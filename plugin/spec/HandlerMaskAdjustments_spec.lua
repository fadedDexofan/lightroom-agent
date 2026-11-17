local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local function twoMasks()
    return {
        Store.correction("A", { Store.linearComponent({ MaskID = "C1T1" }) }, {
            CorrectionID = "mask-a", LocalExposure2012 = 0.125, LocalContrast2012 = 0.1, LocalShadows2012 = 0.2,
        }),
        Store.correction("B", { Store.linearComponent({ MaskID = "C2T1" }) }, {
            CorrectionID = "mask-b", LocalExposure2012 = -0.25, LocalContrast2012 = -0.3, LocalShadows2012 = 0.05,
        }),
    }
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries or twoMasks() })
    local catalog = helper.fakeCatalog({ photos = { photo } })
    Store.trackGates(store, catalog)
    catalog.getTargetPhoto = function() return photo end
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
    for _, name in ipairs({ "HandlerMaskAdjustments", "MaskValues", "GuardedMaskWrite", "LocalSliders", "DevelopSession",
        "MaskSelection" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskAdjustments', store, modules
end

describe("HandlerMaskAdjustments.setMaskAdjustments", function()
    it("changes only the requested sliders of the mask named by its id, without Develop", function()
        local Handler, store, modules = setup()
        local otherMask = Store.clone(store.entries[2])

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 1.25, local_Shadows = -15 },
        })

        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ local_Exposure = 1.25, local_Shadows = -15 }, r.adjustments)
        assert.are.same({
            { slider = "local_Exposure", from = 0.5, to = 1.25 },
            { slider = "local_Shadows", from = 20, to = -15 },
        }, r.changed)
        assert.are.same({}, r.unchanged)
        assert.are.equal(0.3125, store.entries[1].LocalExposure2012)
        assert.are.equal(-0.15, store.entries[1].LocalShadows2012)
        assert.are.equal(0.1, store.entries[1].LocalContrast2012)
        assert.are.same(otherMask, store.entries[2])
        assert.are.same({}, modules)
    end)

    it("lists a slider already at the value as unchanged and writes nothing when all are", function()
        local Handler, store = setup()

        local r = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 10, local_Whites = 0 },
        })

        assert.are.same({}, r.changed)
        assert.are.same({ "local_Contrast", "local_Whites" }, r.unchanged)
        assert.are.same({ local_Contrast = 10, local_Whites = 0 }, r.adjustments)
        assert.are.equal(0, store.attempts)
    end)

    it("accepts a numeric photo id and a file path", function()
        for _, photoId in ipairs({ 1, "/1.jpg" }) do
            local Handler = setup()
            local r = Handler.setMaskAdjustments({ photo_id = photoId, mask_id = "mask-b", adjustments = { local_Contrast = 5 } })
            assert.are.equal("1", r.photo_id)
        end
    end)

    it("refuses an unknown mask and writes nothing", function()
        local Handler, store = setup()

        local refusal = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-z", adjustments = { local_Contrast = 5 } })
        end)

        assert.matches("Mask mask-z is not in the saved settings of photo 1 (saved masks: mask-a, mask-b)", refusal, 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("names an unknown photo", function()
        local Handler = setup()

        local missing = helper.notFoundOf(function()
            Handler.setMaskAdjustments({ photo_id = "99", mask_id = "mask-a", adjustments = { local_Contrast = 5 } })
        end)

        assert.are.equal("99", missing)
    end)

    it("writes Color Grading and Glow sliders as Lightroom stores them and reports the stored value", function()
        local Handler, store = setup()

        local r = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-a", adjustments = { local_colorgradeMidtoneHue = 61.83, local_glow = 25 },
        })

        assert.are.same({ local_colorgradeMidtoneHue = 62, local_glow = 25 }, r.adjustments)
        assert.are.equal(62, store.entries[1].LocalColorGradeMidtoneHue)
        assert.are.equal(0.25, store.entries[1].LocalGlow)
    end)
end)

describe("HandlerMaskAdjustments.setMaskAdjustments on a hidden mask", function()
    for _, case in ipairs({
        { hidden = true, warnings = { "mask mask-a was hidden (CorrectionActive false); this write showed it again,"
            .. " as Lightroom's own sliders do" } },
        { hidden = false, warnings = {} },
    }) do
        it((case.hidden and "warns that the write showed it again" or "says nothing when it was shown"), function()
            local Handler, store = setup()
            store.entries[1].CorrectionActive = not case.hidden
            local context = helper.requestContext()

            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 1 } }, context)

            assert.is_true(store.entries[1].CorrectionActive)
            assert.are.same(case.warnings, context.warnings)
        end)
    end

    it("says nothing when every value is already stored and nothing is written", function()
        local Handler, store = setup()
        store.entries[1].CorrectionActive = false
        local context = helper.requestContext()

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 0.5 } }, context)

        assert.is_false(store.entries[1].CorrectionActive)
        assert.are.same({}, context.warnings)
    end)
end)

describe("LocalSliders", function()
    it("lists unique local_ names with the stored field Lightroom writes", function()
        local LocalSliders = require 'LocalSliders'
        local seen = {}

        for _, slider in ipairs(LocalSliders.list) do
            assert.truthy(slider.name:match("^local_%a+$"))
            assert.is_nil(seen[slider.name])
            seen[slider.name] = true
            assert.truthy(slider.stored:match("^Local%w+$"))
            assert.is_true(slider.scale > 0)
            assert.are.equal(slider, LocalSliders.byStored[slider.stored])
        end
    end)
end)

describe("a local slider added to the table", function()
    it("is settable and read back by set_mask_adjustments", function()
        helper.withFixtureSlider(function()
            local Handler, store = setup()

            local r = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Fixture = 5 } })

            assert.are.equal(5, r.adjustments.local_Fixture)
            assert.are.equal(0.05, store.entries[1].LocalFixture)
        end)
    end)
end)
