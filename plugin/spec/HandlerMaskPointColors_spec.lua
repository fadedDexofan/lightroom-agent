local helper = require "spec_helper"
local Store = require "fake_mask_store"

local LIGHTROOM_SWATCH = "3.000000, 0.500000, 0.500000, 0.000000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333,"
    .. " 0.666667, 1.000000, 0.000000, 0.320000, 0.680000, 1.000000, 0.005357, 0.555357, 0.915357, 1.000000"
local SECOND_SWATCH = "1.000000, 0.900000, 0.400000, 0.100000, 0.000000, 0.000000, 0.500000, 0.000000, 0.200000,"
    .. " 0.800000, 1.000000, 0.000000, 0.200000, 0.800000, 1.000000, 0.000000, 0.200000, 0.800000, 1.000000"

local function savedSetup()
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, {
        entries = {
            Store.correction("A", { Store.linearComponent({ MaskID = "C1T1" }) }, {
                CorrectionID = "mask-a",
                LocalPointColors = { LIGHTROOM_SWATCH, SECOND_SWATCH },
                LocalColorVariance = { "0.000000", "0.250000" },
            }),
            Store.correction("B", { Store.linearComponent({ MaskID = "C2T1" }) }, { CorrectionID = "mask-b" }),
        },
    })
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
    for _, name in ipairs({
        "HandlerMaskPointColors",
        "MaskPointColors",
        "MaskValues",
        "GuardedMaskWrite",
        "MaskSelection",
        "DevelopSession",
    }) do
        package.loaded[name] = nil
    end
    return require "HandlerMaskPointColors", store, modules
end

describe("HandlerMaskPointColors.editMaskPointColors add in the saved settings", function()
    local DEFAULT_AT_HUE_4 = "4.000000, 0.500000, 0.500000, 0.000000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333,"
        .. " 0.666667, 1.000000, 0.000000, 0.320000, 0.680000, 1.000000, 0.005357, 0.555357, 0.915357, 1.000000"

    it("appends a swatch with the ranges Lightroom gives its source colour, without Develop", function()
        local Handler, store, modules = savedSetup()
        local otherMask = Store.clone(store.entries[2])

        local r = Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-a",
            action = "add",
            swatch = { SrcHue = 4, SrcSat = 0.5, SrcLum = 0.5 },
        })

        assert.is_true(r.changed)
        assert.are.equal(3, r.index)
        assert.are.same({ LIGHTROOM_SWATCH, SECOND_SWATCH, DEFAULT_AT_HUE_4 }, store.entries[1].LocalPointColors)
        assert.are.same({ "0.000000", "0.250000", "0.000000" }, store.entries[1].LocalColorVariance)
        assert.are.equal(3, #r.swatches)
        assert.are.same(
            { LowerNone = 0.005357, LowerFull = 0.555357, UpperFull = 0.915357, UpperNone = 1 },
            r.swatches[3].LumRange
        )
        assert.are.same(otherMask, store.entries[2])
        assert.are.same({}, modules)
        assert.are.equal(1, store.attempts)
    end)

    it(
        "stores the source as Lightroom's own add does, rounded to two decimals, with the ranges of the rounded values",
        function()
            local Handler, store = savedSetup()

            Handler.editMaskPointColors({
                photo_ids = { "1" },
                mask_id = "mask-b",
                action = "add",
                swatch = { SrcHue = 3.021347, SrcSat = 0.537218, SrcLum = 0.512694, LumScale = -0.8 },
            })

            assert.are.same({
                "3.020000, 0.540000, 0.510000, 0.000000, 0.000000, -0.800000, 0.500000, 0.000000, 0.333333,"
                    .. " 0.666667, 1.000000, 0.000000, 0.360000, 0.720000, 1.000000, 0.011905, 0.561905, 0.921905, 1.000000",
            }, store.entries[2].LocalPointColors)
        end
    )

    it("keeps the fields the request gives, rounds its source and fills only the ranges it omits", function()
        local Handler, store = savedSetup()

        Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-b",
            action = "add",
            swatch = {
                SrcHue = 1.5,
                SrcSat = 0.1,
                SrcLum = 0.002,
                HueShift = -0.2,
                RangeAmount = 0.8,
                Variance = 0.3,
                HueRange = { LowerNone = 0.1, LowerFull = 0.2, UpperFull = 0.6, UpperNone = 0.9 },
            },
        })

        assert.are.same({
            "1.500000, 0.100000, 0.000000, -0.200000, 0.000000, 0.000000, 0.800000, 0.100000, 0.200000,"
                .. " 0.600000, 0.900000, 0.000000, 0.000000, 0.280000, 0.830000, 0.000000, 0.000000, 0.180000, 0.730000",
        }, store.entries[2].LocalPointColors)
        assert.are.same({ "0.300000" }, store.entries[2].LocalColorVariance)
    end)

    for _, case in ipairs({
        {
            what = "a ninth swatch",
            count = 8,
            swatch = { SrcHue = 5, SrcSat = 0.5, SrcLum = 0.5 },
            message = "Mask mask-a already holds 8 Point Color swatches, the most Lightroom allows",
        },
        {
            what = "a source colour the mask already holds",
            count = 2,
            swatch = { SrcHue = 3, SrcSat = 0.5, SrcLum = 0.5 },
            message = "Mask mask-a already has a swatch with that source color at index 1; nothing was added",
        },
        {
            what = "a source colour equal to a held one at the six stored decimals",
            count = 2,
            swatch = { SrcHue = 3, SrcSat = 0.5000001, SrcLum = 0.5 },
            message = "Mask mask-a already has a swatch with that source color at index 1; nothing was added",
        },
        {
            what = "unordered range edges",
            count = 2,
            swatch = {
                SrcHue = 5,
                SrcSat = 0.5,
                SrcLum = 0.5,
                SatRange = { LowerNone = 0.3, LowerFull = 0.2, UpperFull = 0.6, UpperNone = 1 },
            },
            message = "Point Color swatch 3's SatRange edges are not ordered",
        },
    }) do
        it("refuses " .. case.what .. " before any gate", function()
            local Handler, store = savedSetup()
            local colors, variances = {}, {}
            for index = 1, case.count do
                colors[index] = index == 2 and SECOND_SWATCH
                    or LIGHTROOM_SWATCH:gsub("^3", tostring(index == 1 and 3 or index + 2))
                variances[index] = "0.000000"
            end
            store.entries[1].LocalPointColors, store.entries[1].LocalColorVariance = colors, variances

            local err = helper.failedOf(
                function()
                    Handler.editMaskPointColors({
                        photo_ids = { "1" },
                        mask_id = "mask-a",
                        action = "add",
                        swatch = case.swatch,
                    })
                end
            )

            assert.truthy(err:find(case.message, 1, true), err)
            assert.are.equal(0, store.attempts)
        end)
    end
end)

describe("HandlerMaskPointColors.editMaskPointColors add beside a held source colour", function()
    it("adds a swatch with the held swatch's hue at another saturation", function()
        local Handler, store = savedSetup()
        store.entries[1].LocalPointColors = { LIGHTROOM_SWATCH, SECOND_SWATCH }
        store.entries[1].LocalColorVariance = { "0.000000", "0.000000" }

        Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-a",
            action = "add",
            swatch = { SrcHue = 3, SrcSat = 0.6, SrcLum = 0.5 },
        })

        assert.are.equal(3, #store.entries[1].LocalPointColors)
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors update", function()
    it("changes only the given fields of the numbered swatch in the saved settings, without Develop", function()
        local Handler, store, modules = savedSetup()
        local otherMask = Store.clone(store.entries[2])

        local r = Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-a",
            action = "update",
            index = 1,
            swatch = {
                HueShift = 0.25,
                Variance = 0.3,
                SatRange = { LowerNone = 0.1, LowerFull = 0.3, UpperFull = 0.7, UpperNone = 0.9 },
            },
        })

        assert.is_true(r.changed)
        assert.are.equal(1, r.index)
        assert.are.same({
            "3.000000, 0.500000, 0.500000, 0.250000, 0.000000, 0.000000, 0.500000, 0.000000, 0.333333, 0.666667, 1.000000,"
                .. " 0.100000, 0.300000, 0.700000, 0.900000, 0.005357, 0.555357, 0.915357, 1.000000",
            SECOND_SWATCH,
        }, store.entries[1].LocalPointColors)
        assert.are.same({ "0.300000", "0.250000" }, store.entries[1].LocalColorVariance)
        assert.are.equal(0.25, r.swatches[1].HueShift)
        assert.are.equal(0.3, r.swatches[1].Variance)
        assert.are.equal(0.25, r.swatches[2].Variance)
        assert.are.equal(2, r.swatches[2].index)
        assert.are.same(otherMask, store.entries[2])
        assert.are.same({}, modules)
    end)

    it("writes a value as the six decimals Lightroom stores", function()
        local Handler, store = savedSetup()

        local r = Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-a",
            action = "update",
            index = 2,
            swatch = { LumScale = -0.1234567 },
        })

        assert.truthy(store.entries[1].LocalPointColors[2]:find("-0.123457", 1, true))
        assert.are.equal(-0.123457, r.swatches[2].LumScale)
    end)

    it("writes nothing when the swatch already holds the values", function()
        local Handler, store = savedSetup()

        local r = Handler.editMaskPointColors({
            photo_ids = { "1" },
            mask_id = "mask-a",
            action = "update",
            index = 2,
            swatch = { HueShift = 0.1, SrcSat = 0.9 },
        })

        assert.is_false(r.changed)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses an index past the last swatch naming the count", function()
        local Handler, store = savedSetup()

        local err = helper.failedOf(
            function()
                Handler.editMaskPointColors({
                    photo_ids = { "1" },
                    mask_id = "mask-b",
                    action = "update",
                    index = 1,
                    swatch = { HueShift = 0.1 },
                })
            end
        )

        assert.truthy(err:find("No swatch at index 1 on mask mask-b (the mask has 0)", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors delete and clear", function()
    it("deletes the numbered swatch from both stored arrays in the saved settings, without Develop", function()
        local Handler, store, modules = savedSetup()
        local otherMask = Store.clone(store.entries[2])

        local r = Handler.editMaskPointColors({ photo_ids = { "1" }, mask_id = "mask-a", action = "delete", index = 1 })

        assert.is_true(r.changed)
        assert.are.equal(1, r.index)
        assert.are.same({ SECOND_SWATCH }, store.entries[1].LocalPointColors)
        assert.are.same({ "0.250000" }, store.entries[1].LocalColorVariance)
        assert.are.equal(1, #r.swatches)
        assert.are.equal(1, r.swatches[1].SrcHue)
        assert.are.equal(0.25, r.swatches[1].Variance)
        assert.are.same(otherMask, store.entries[2])
        assert.are.same({}, modules)
        assert.are.equal(1, store.attempts)
    end)

    for _, case in ipairs({
        { what = "deleting the last swatch", args = { action = "delete", index = 1 }, swatches = { LIGHTROOM_SWATCH } },
        { what = "clearing", args = { action = "clear" }, swatches = { LIGHTROOM_SWATCH, SECOND_SWATCH } },
    }) do
        it("removes both stored fields when " .. case.what .. " leaves no swatch", function()
            local Handler, store, modules = savedSetup()
            store.entries[1].LocalPointColors = case.swatches
            store.entries[1].LocalColorVariance = {}
            for index in ipairs(case.swatches) do
                store.entries[1].LocalColorVariance[index] = "0.000000"
            end

            local args = { photo_ids = { "1" }, mask_id = "mask-a" }
            for key, value in pairs(case.args) do
                args[key] = value
            end
            local r = Handler.editMaskPointColors(args)

            assert.is_true(r.changed)
            assert.are.same({}, r.swatches)
            assert.is_nil(store.entries[1].LocalPointColors)
            assert.is_nil(store.entries[1].LocalColorVariance)
            assert.are.same({}, modules)
        end)
    end

    for _, case in ipairs({
        {
            what = "deleting the unreadable swatch",
            args = { action = "delete", index = 1 },
            stored = { SECOND_SWATCH },
            swatches = 1,
        },
        {
            what = "deleting a readable swatch beside it",
            args = { action = "delete", index = 2 },
            stored = { "1.0, 0.5" },
            count = 1,
        },
        { what = "clearing", args = { action = "clear" }, swatches = 0 },
    }) do
        it("answers done after " .. case.what .. " on a mask holding a swatch it cannot read", function()
            local Handler, store = savedSetup()
            store.entries[1].LocalPointColors = { "1.0, 0.5", SECOND_SWATCH }
            local context = helper.requestContext(nil, { title = "edit_mask_point_colors" })

            local args = { photo_ids = { "1" }, mask_id = "mask-a" }
            for key, value in pairs(case.args) do
                args[key] = value
            end
            local r = Handler.editMaskPointColors(args, context)

            assert.is_true(r.changed)
            assert.are.equal(1, store.attempts)
            assert.are.same(case.stored, store.entries[1].LocalPointColors)
            if case.count then
                assert.is_nil(r.swatches)
                assert.are.equal(case.count, r.swatch_count)
                assert.are.same({
                    "mask mask-a still holds a Point Color swatch Lightroom stored unreadably, so the"
                        .. " reply gives the swatch count instead of the swatches",
                }, context.warnings)
            else
                assert.are.equal(case.swatches, #r.swatches)
                assert.is_nil(r.swatch_count)
                assert.are.same({}, context.warnings)
            end
        end)
    end

    it("refuses an index past the last swatch naming the count, writing nothing", function()
        local Handler, store = savedSetup()

        local err = helper.failedOf(
            function()
                Handler.editMaskPointColors({ photo_ids = { "1" }, mask_id = "mask-a", action = "delete", index = 3 })
            end
        )

        assert.truthy(err:find("No swatch at index 3 on mask mask-a (the mask has 2)", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)

    it("clears a mask without swatches as a no-op with no write", function()
        local Handler, store = savedSetup()

        local r = Handler.editMaskPointColors({ photo_ids = { "1" }, mask_id = "mask-b", action = "clear" })

        assert.is_false(r.changed)
        assert.are.same({}, r.swatches)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses a mask that is not in the saved settings, writing nothing", function()
        local Handler, store = savedSetup()

        local err = helper.failedOf(
            function() Handler.editMaskPointColors({ photo_ids = { "1" }, mask_id = "nope", action = "clear" }) end
        )

        assert.truthy(err:find("Mask nope is not in the saved settings of photo 1", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors update on a hidden mask", function()
    it("warns that the write showed it again", function()
        local Handler, store = savedSetup()
        store.entries[1].CorrectionActive = false
        local context = helper.requestContext()

        Handler.editMaskPointColors(
            { photo_ids = { "1" }, mask_id = "mask-a", action = "update", index = 1, swatch = { HueShift = 0.4 } },
            context
        )

        assert.are.same({
            "mask mask-a was hidden (CorrectionActive false); this write showed it again, as Lightroom's own"
                .. " sliders do",
        }, context.warnings)
    end)
end)
