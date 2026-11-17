local helper = require 'spec_helper'
local fake = require 'fake_mask_develop'

local LINE = { 0, 0, 255, 255 }
local SWATCH = { SrcHue = 1, SrcSat = 0.5, SrcLum = 0.4, HueShift = 0.2 }

local function setup(overrides)
    local opts = {
        photos = {
            { id = "1", selectedMask = "mask-b", masks = {
                ["mask-a"] = { local_Exposure = 0.5, local_Contrast = 10,
                    local_Maincurve = LINE, local_Redcurve = LINE,
                    local_Greencurve = LINE, local_Bluecurve = { 0, 10, 255, 240 },
                    local_PointColors = { SWATCH } },
                ["mask-b"] = { local_Exposure = -1, local_Maincurve = LINE },
            } },
            { id = "2" },
        },
        modules = { "HandlerMaskRead", "HandlerMaskAdjustments", "HandlerMaskCurves", "HandlerMaskPointColors",
            "MaskSelection", "DevelopSession", "MaskSettle", "MaskCurves", "MaskPointColors" },
        handler = "HandlerMaskRead",
        extend = function(controller) controller.getSelectedPointColorSwatchIndex = function() return 0 end end,
    }
    for key, value in pairs(overrides or {}) do opts[key] = value end
    local ctx = fake.build(opts)
    ctx.reads, ctx.sessions = {}, 0
    local getValue = ctx.controller.getValue
    ctx.controller.getValue = function(name)
        ctx.reads[#ctx.reads + 1] = name
        return getValue(name)
    end
    local session = require 'DevelopSession'
    local withPhoto = session.withPhoto
    session.withPhoto = function(...)
        ctx.sessions = ctx.sessions + 1
        return withPhoto(...)
    end
    return ctx
end

describe("HandlerMaskRead.getMask", function()
    it("reads all three kinds once in one session and restores mask and view", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = 1, mask_id = "mask-a" })
        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ local_Exposure = 0.5, local_Contrast = 10 }, r.adjustments)
        assert.are.same(LINE, r.curves.main)
        assert.are.same({ 0, 10, 255, 240 }, r.curves.blue)
        assert.are.equal(1, r.swatches[1].index)
        assert.are.equal(SWATCH.HueShift, r.swatches[1].HueShift)
        assert.are.equal(1, #r.swatches)
        assert.are.same({}, r.unavailable.curves)
        assert.is_true(#r.unavailable.adjustments > 0)
        assert.is_nil(r.errors)
        assert.are.equal(1, ctx.sessions)
        assert.are.same({ "develop", "library" }, ctx.calls.modules)
        assert.are.equal("mask-b", ctx.selectedMaskOf[ctx.photos[1]])
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    for _, kind in ipairs({ "adjustments", "curves", "point_colors" }) do
        it("reads only " .. kind .. " when requested", function()
            local ctx = setup()
            local r = ctx.Handler.getMask({ photo_id = "/1.jpg", mask_id = "mask-a", kinds = { kind } })
            for _, name in ipairs(ctx.reads) do
                local actualKind = name == "local_PointColors" and "point_colors"
                    or name:find("curve", 1, true) and "curves" or "adjustments"
                assert.are.equal(kind, actualKind)
            end
            assert.are.equal(kind == "curves", r.curves ~= nil)
            assert.are.equal(kind == "adjustments", r.adjustments ~= nil)
            assert.are.equal(kind == "point_colors", r.swatches ~= nil)
            assert.are.equal(1, ctx.sessions)
        end)
    end

    it("reads every kind whose calls exist, whatever Lightroom's version number", function()
        local ctx = setup({ version = { major = 11, minor = 5 } })
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a" })
        assert.are.equal(0.5, r.adjustments.local_Exposure)
        assert.are.same(LINE, r.curves.main)
        assert.is_nil(r.errors)
    end)

    it("reports missing Point Color API while still reading curves", function()
        local ctx = setup({ extend = function() end })
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "curves", "point_colors" } })
        assert.are.same(LINE, r.curves.main)
        assert.truthy(r.errors.point_colors:find("13.2", 1, true))
        assert.is_nil(r.adjustments)
    end)

    it("keeps other results when curve parameters are unavailable", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b" })
        assert.are.equal(-1, r.adjustments.local_Exposure)
        assert.are.same({ "red", "green", "blue" }, r.unavailable.curves)
        ctx.valuesOf[ctx.photos[1]]["mask-b"].local_Maincurve = nil
        r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b" })
        assert.is_nil(r.curves)
        assert.truthy(r.errors.curves:find("12.3", 1, true))
        assert.are.equal(-1, r.adjustments.local_Exposure)
    end)

    it("fails when the only requested curve cannot be read", function()
        local ctx = setup()
        ctx.valuesOf[ctx.photos[1]]["mask-b"].local_Maincurve = { 0, 0, 255 }
        local err = helper.unknownOf(function()
            ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b", kinds = { "curves" } })
        end)
        assert.truthy(err:find("curves", 1, true))
        assert.truthy(err:find("12.3", 1, true))
        assert.are.equal("mask-b", ctx.selectedMaskOf[ctx.photos[1]])
    end)

    it("fails an adjustments-only request with no readable sliders and keeps other readable kinds", function()
        local ctx = setup()
        local values = ctx.valuesOf[ctx.photos[1]]["mask-a"]
        values.local_Exposure, values.local_Contrast = nil, nil
        local err = helper.unknownOf(function()
            ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "adjustments" } })
        end)
        assert.truthy(err:find("adjustments", 1, true))
        assert.truthy(err:find("Lightroom Classic 11", 1, true))
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "adjustments", "curves" } })
        assert.is_nil(r.adjustments)
        assert.is_nil(r.unavailable.adjustments)
        assert.truthy(r.errors.adjustments:find("Lightroom Classic 11", 1, true))
        assert.are.same(LINE, r.curves.main)
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    it("returns empty swatches and reports malformed or throwing Point Color reads", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b", kinds = { "point_colors" } })
        assert.are.same({}, r.swatches)
        ctx.valuesOf[ctx.photos[1]]["mask-a"].local_PointColors = { { SrcHue = "red" } }
        r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a" })
        assert.truthy(r.errors.point_colors:find("unreadable Point Color swatch", 1, true))
        local original = ctx.controller.getValue
        ctx.controller.getValue = function(name)
            if name == "local_PointColors" then error("unknown parameter") end
            return original(name)
        end
        local err = helper.unknownOf(function()
            ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "point_colors" } })
        end)
        assert.truthy(err:find("13.2", 1, true))
    end)

    it("answers an unknown photo with not_found before any session", function()
        local ctx = setup()
        assert.are.equal("404", helper.notFoundOf(function() ctx.Handler.getMask({ photo_id = "404", mask_id = "mask-a" }) end))
        assert.are.equal(0, ctx.sessions)
        assert.are.same({}, ctx.reads)
    end)

    it("reads no values when the requested mask does not exist", function()
        local ctx = setup()
        local err = helper.refusalOf(function() ctx.Handler.getMask({ photo_id = "1", mask_id = "missing" }) end)
        assert.truthy(err:find("Mask not found", 1, true))
        assert.are.same({}, ctx.reads)
        assert.are.equal(0, #ctx.calls.setValue)
    end)
end)

describe("a local slider added to the table", function()
    it("is read by get_mask", function()
        helper.withFixtureSlider(function()
            local ctx = setup()
            ctx.valuesOf[ctx.photos[1]]["mask-a"].local_Fixture = 7

            local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "adjustments" } })

            assert.are.equal(7, r.adjustments.local_Fixture)
        end)
    end)
end)
