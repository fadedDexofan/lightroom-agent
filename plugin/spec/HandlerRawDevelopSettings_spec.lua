local helper = require 'spec_helper'

local MASKS = {
    {
        What = "Correction",
        CorrectionID = "C1",
        CorrectionActive = true,
        CorrectionAmount = 1,
        LocalExposure2012 = 0.25,
        LocalGlow = 0.25,
        CorrectionMasks = {
            {
                What = "Mask/Image",
                MaskID = "C1T1",
                MaskSubType = 1,
                MaskDigest = "0123456789abcdef",
                ErrorReason = 0,
            },
            {
                What = "Mask/RangeMask",
                MaskID = "C1T2",
                CorrectionRangeMask = { Type = -1, Amount = 0.5, ColorAmount = 0.5, DepthRange = "0 0.1 0.2 0.3" },
            },
        },
    },
}

local function setup(settings, photoId)
    local readInsideGate
    local photo = helper.fakePhoto({ id = photoId or "7", path = "/7.cr2", developSettings = settings })
    local catalog = helper.fakeCatalog({ photos = { photo } })
    local read = photo.getDevelopSettings
    photo.getDevelopSettings = function(self)
        readInsideGate = catalog.isInsideReadAccess()
        return read(self)
    end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerRawDevelopSettings = nil
    package.loaded.JSON = nil
    return require 'HandlerRawDevelopSettings', function() return readInsideGate end
end

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe("HandlerRawDevelopSettings.get", function()
    it("lists top-level keys with their type and table size, without values, inside the read gate", function()
        local Handler, readInsideGate = setup({
            ProcessVersion = "15.4", Exposure2012 = 0.5, AutoGrayscaleMix = true, MaskGroupBasedCorrections = MASKS,
        })

        local r = Handler.get({ photo_id = "7" })

        assert.are.equal("7", r.photo_id)
        assert.are.equal(4, r.count)
        assert.are.same({
            { name = "AutoGrayscaleMix", type = "boolean" },
            { name = "Exposure2012", type = "number" },
            { name = "MaskGroupBasedCorrections", type = "table", count = 1 },
            { name = "ProcessVersion", type = "string" },
        }, r.keys)
        assert.is_nil(r.settings)
        assert.is_true(readInsideGate())
    end)

    it("returns requested keys unrenamed, MaskGroupBasedCorrections whole, and lists missing keys", function()
        local Handler = setup({ ProcessVersion = "15.4", MaskGroupBasedCorrections = MASKS })

        local r = Handler.get({ photo_id = "7", keys = { "ProcessVersion", "MaskGroupBasedCorrections", "DepthMapInfo" } })

        assert.are.equal("15.4", r.settings.ProcessVersion)
        assert.are.same(MASKS, r.settings.MaskGroupBasedCorrections)
        assert.are.same({ "DepthMapInfo" }, r.missing)
        local JSON = require 'JSON'
        assert.are.same(MASKS, JSON:decode(JSON:encode(r)).settings.MaskGroupBasedCorrections)
    end)

    it("marks values JSON cannot carry instead of failing or dropping them", function()
        local fn = function() end
        local Handler = setup({
            Gapped = { 1, nil, 3 },
            Mixed = { 10, label = "x" },
            NotANumber = 0 / 0,
            Infinite = { level = math.huge },
            Callable = fn,
        })

        local r = Handler.get({ photo_id = "7", keys = { "Gapped", "Mixed", "NotANumber", "Infinite", "Callable" } })

        assert.are.same({ ["$lua"] = "table", entries = { { 1, 1 }, { 3, 3 } } }, r.settings.Gapped)
        assert.are.same({ ["$lua"] = "table", entries = { { 1, 10 }, { "label", "x" } } }, r.settings.Mixed)
        assert.are.equal("number", r.settings.NotANumber["$lua"])
        assert.are.same({ level = { ["$lua"] = "number", value = tostring(math.huge) } }, r.settings.Infinite)
        assert.are.same({ ["$lua"] = "function", value = tostring(fn) }, r.settings.Callable)
        assert.is_true(pcall(function() return require('JSON'):encode(r) end))
    end)

    it("refuses a reply over the size limit and names the way out", function()
        local Handler = setup({ Big = string.rep("x", 1000001) })

        local message = errorOf(function() Handler.get({ photo_id = "7", keys = { "Big" } }) end)

        assert.truthy(message:find("request fewer keys", 1, true))
    end)

    it("validates its arguments and names an unknown photo", function()
        local Handler = setup({})

        assert.truthy(errorOf(function() Handler.get({}) end):find("photo_id is required", 1, true))
        for _, keys in ipairs({ {}, { "" }, { 5 }, { "A", "A" }, "A" }) do
            assert.truthy(errorOf(function() Handler.get({ photo_id = "7", keys = keys }) end)
                :find("keys must be", 1, true))
        end
        assert.truthy(errorOf(function() Handler.get({ photo_id = "99" }) end):find("Photo not found: 99", 1, true))
    end)
end)
