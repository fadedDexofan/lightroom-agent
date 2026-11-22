local helper = require "spec_helper"
local Store = require "fake_mask_store"

local SWATCH = "1.000000, 0.900000, 0.400000, 0.100000, -0.200000, 0.300000, 0.600000, 0.000000, 0.200000,"
    .. " 0.800000, 1.000000, 0.050000, 0.250000, 0.750000, 0.950000, 0.005357, 0.555357, 0.915357, 1.000000"

local function setup(entries)
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local other = helper.fakePhoto({ id = "2", path = "/2.jpg" })
    local store = Store.attach(photo, {
        entries = entries or {
            Store.correction("A", { Store.linearComponent({ MaskID = "C1T1" }) }, {
                CorrectionID = "mask-a",
                LocalExposure2012 = 0.125,
                LocalContrast2012 = 0.1,
                LocalColorGradeMidtoneHue = 62,
                BlueCurve = { "0,10", "255,240" },
                LocalPointColors = { SWATCH },
                LocalColorVariance = { "0.250000" },
            }),
            Store.correction("B", { Store.linearComponent({ MaskID = "C2T1" }) }, {
                CorrectionID = "mask-b",
                MainCurve = { "0,20", "128,140", "255,255" },
            }),
        },
    })
    local catalog = helper.fakeCatalog({ photos = { photo, other } })
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
    for _, name in ipairs({
        "HandlerMaskRead",
        "MaskValues",
        "GuardedMaskWrite",
        "LocalSliders",
        "MaskCurves",
        "MaskPointColors",
        "DevelopSession",
    }) do
        package.loaded[name] = nil
    end
    return require "HandlerMaskRead", { store = store, modules = modules, catalog = catalog }
end

describe("HandlerMaskRead.getMask", function()
    it("decodes every kind from the stored fields of the mask without opening Develop", function()
        local Handler, ctx = setup()

        local r = Handler.getMask({ photo_id = 1, mask_id = "mask-a" })

        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.equal(0.5, r.adjustments.local_Exposure)
        assert.are.equal(10, r.adjustments.local_Contrast)
        assert.are.equal(62, r.adjustments.local_colorgradeMidtoneHue)
        assert.are.equal(0, r.adjustments.local_Shadows)
        assert.are.equal(50, r.adjustments.local_colorgradeBlending)
        assert.are.same({ 0, 0, 255, 255 }, r.curves.main)
        assert.are.same({ 0, 10, 255, 240 }, r.curves.blue)
        assert.are.same({
            {
                index = 1,
                SrcHue = 1,
                SrcSat = 0.9,
                SrcLum = 0.4,
                HueShift = 0.1,
                SatScale = -0.2,
                LumScale = 0.3,
                RangeAmount = 0.6,
                Variance = 0.25,
                HueRange = { LowerNone = 0, LowerFull = 0.2, UpperFull = 0.8, UpperNone = 1 },
                SatRange = { LowerNone = 0.05, LowerFull = 0.25, UpperFull = 0.75, UpperNone = 0.95 },
                LumRange = { LowerNone = 0.005357, LowerFull = 0.555357, UpperFull = 0.915357, UpperNone = 1 },
            },
        }, r.swatches)
        assert.are.same({}, ctx.modules)
        assert.are.equal(0, ctx.catalog.getWriteAccessCount())
    end)

    for _, case in ipairs({
        { kind = "adjustments", field = "adjustments" },
        { kind = "curves", field = "curves" },
        { kind = "point_colors", field = "swatches" },
    }) do
        it("returns only " .. case.kind .. " when only it is requested", function()
            local Handler = setup()
            local r = Handler.getMask({ photo_id = "/1.jpg", mask_id = "mask-a", kinds = { case.kind } })
            for _, field in ipairs({ "adjustments", "curves", "swatches" }) do
                assert.are.equal(field == case.field, r[field] ~= nil)
            end
        end)
    end

    it("reads a channel the mask does not store as linear and a mask without swatches as an empty list", function()
        local Handler = setup()
        local r = Handler.getMask({ photo_id = "1", mask_id = "mask-b", kinds = { "curves", "point_colors" } })
        assert.are.same({ 0, 0, 255, 255 }, r.curves.red)
        assert.are.same({ 0, 20, 128, 140, 255, 255 }, r.curves.main)
        assert.are.same({}, r.swatches)
    end)

    it("refuses point_colors naming a swatch Lightroom stored unreadably, and still reads the other kinds", function()
        local Handler = setup({
            Store.correction("A", { Store.linearComponent({ MaskID = "C1T1" }) }, {
                CorrectionID = "mask-a",
                LocalExposure2012 = 0.125,
                LocalPointColors = { "1.0, 0.5" },
            }),
        })
        local err = helper.failedOf(
            function() Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "point_colors" } }) end
        )
        assert.truthy(err:find("Lightroom stored an unreadable Point Color swatch at index 1", 1, true), err)

        local r = Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "adjustments", "curves" } })

        assert.are.equal(0.5, r.adjustments.local_Exposure)
        assert.are.same({ 0, 0, 255, 255 }, r.curves.main)
    end)

    it("answers an unknown photo with not_found", function()
        local Handler = setup()
        assert.are.equal(
            "404",
            helper.notFoundOf(function() Handler.getMask({ photo_id = "404", mask_id = "mask-a" }) end)
        )
    end)

    it("refuses a mask that is not in the saved settings, naming the saved ones", function()
        local Handler = setup()
        local err = helper.failedOf(function() Handler.getMask({ photo_id = "1", mask_id = "missing" }) end)
        assert.truthy(
            err:find("Mask missing is not in the saved settings of photo 1 (saved masks: mask-a, mask-b)", 1, true),
            err
        )
    end)
end)

describe("a local slider added to the table", function()
    it("is read by get_mask", function()
        helper.withFixtureSlider(function()
            local Handler = setup({
                Store.correction(
                    "A",
                    { Store.linearComponent({ MaskID = "C1T1" }) },
                    { CorrectionID = "mask-a", LocalFixture = 0.07 }
                ),
            })

            local r = Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "adjustments" } })

            assert.are.equal(7, r.adjustments.local_Fixture)
        end)
    end)
end)
