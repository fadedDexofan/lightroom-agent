local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local LINE = { 0, 0, 255, 255 }

local function masks()
    return {
        Store.correction("A", { Store.linearComponent({ MaskID = "C1T1" }) }, {
            CorrectionID = "mask-a", LocalExposure2012 = 0.125,
            ExtendedBlueCurve = { "0,0", "100,140", "255,255" }, BlueCurve = { "0,0", "100,140", "255,255" },
        }),
        Store.correction("B", { Store.linearComponent({ MaskID = "C2T1" }) }, {
            CorrectionID = "mask-b", MainCurve = { "0,0", "100,120", "255,255" },
        }),
    }
end

local function setup()
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = masks() })
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
    for _, name in ipairs({ "HandlerMaskCurves", "MaskValues", "MaskCurves", "GuardedMaskWrite", "LocalSliders" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskCurves', store, modules
end

describe("HandlerMaskCurves.setMaskCurves", function()
    it("writes the requested channels of the mask named by its id as plain point fields, without Develop", function()
        local Handler, store, modules = setup()
        local otherMask = Store.clone(store.entries[2])

        local r = Handler.setMaskCurves({
            photo_id = "1",
            mask_id = "mask-a",
            curves = { main = { 0, 0, 64, 48, 192, 210, 255, 255 }, blue = { 0, 10, 255, 240 } },
        })

        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ 0, 0, 64, 48, 192, 210, 255, 255 }, r.curves.main)
        assert.are.same({ 0, 10, 255, 240 }, r.curves.blue)
        assert.are.same({
            { channel = "main", from = LINE, to = { 0, 0, 64, 48, 192, 210, 255, 255 } },
            { channel = "blue", from = { 0, 0, 100, 140, 255, 255 }, to = { 0, 10, 255, 240 } },
        }, r.changed)
        assert.are.same({}, r.unchanged)
        local entry = store.entries[1]
        assert.are.same({ "0,0", "64,48", "192,210", "255,255" }, entry.MainCurve)
        assert.are.same({ "0,10", "255,240" }, entry.BlueCurve)
        assert.is_nil(entry.ExtendedBlueCurve)
        assert.are.equal(0.125, entry.LocalExposure2012)
        assert.are.same(otherMask, store.entries[2])
        assert.are.same({}, modules)
    end)

    it("removes a channel's field when it is set back to linear, which reads as linear", function()
        local Handler, store = setup()

        local r = Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-b", curves = { main = LINE } })

        assert.is_nil(store.entries[2].MainCurve)
        assert.are.same(LINE, r.curves.main)
        assert.are.same({ { channel = "main", from = { 0, 0, 100, 120, 255, 255 }, to = LINE } }, r.changed)
    end)

    it("lists a channel already at the value as unchanged and writes nothing when all are", function()
        local Handler, store = setup()

        local r = Handler.setMaskCurves({
            photo_id = "1", mask_id = "mask-a", curves = { main = LINE, blue = { 0, 0, 100, 140, 255, 255 } },
        })

        assert.are.same({}, r.changed)
        assert.are.same({ "main", "blue" }, r.unchanged)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses an unknown mask and writes nothing", function()
        local Handler, store = setup()

        local refusal = helper.failedOf(function()
            Handler.setMaskCurves({ photo_id = "1", mask_id = "nope", curves = { main = LINE } })
        end)

        assert.matches("Mask nope is not in the saved settings of photo 1 (saved masks: mask-a, mask-b)", refusal, 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("names an unknown photo", function()
        local Handler = setup()

        assert.are.equal("99", helper.notFoundOf(function()
            Handler.setMaskCurves({ photo_id = "99", mask_id = "mask-a", curves = { main = LINE } })
        end))
    end)
end)

describe("HandlerMaskCurves.setMaskCurves on a hidden mask", function()
    it("warns that the write showed it again", function()
        local Handler, store = setup()
        store.entries[2].CorrectionActive = false
        local context = helper.requestContext()

        Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-b", curves = { red = { 0, 10, 255, 245 } } }, context)

        assert.are.same({ "mask mask-b was hidden (CorrectionActive false); this write showed it again, as Lightroom's own"
            .. " sliders do" }, context.warnings)
    end)
end)
