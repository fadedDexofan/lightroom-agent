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

local function setup(settingsById)
    local inside = {}
    local photos = {}
    local catalog
    for id, settings in pairs(settingsById) do
        local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".cr2", developSettings = settings })
        local read = photo.getDevelopSettings
        photo.getDevelopSettings = function(self)
            inside[#inside + 1] = catalog.isInsideReadAccess()
            return read(self)
        end
        photos[#photos + 1] = photo
    end
    catalog = helper.fakeCatalog({ photos = photos })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerRawDevelopSettings = nil
    package.loaded.JSON = nil
    return require 'HandlerRawDevelopSettings', inside
end

describe("HandlerRawDevelopSettings.get", function()
    it("returns a point curve from its Extended field first, and the Extended field itself when named", function()
        local long = { 0, 0, 13, 15, 27, 31, 40, 46, 54, 61, 67, 76, 81, 91, 94, 105, 107, 119, 121, 133, 134, 146, 148, 160, 161, 172, 174, 186, 188, 199, 201, 212, 214, 226, 228, 238, 241, 249, 255, 255 }
        local Handler = setup({ ["7"] = { ToneCurvePV2012 = { 0, 0, 128, 120, 255, 255 }, ExtendedToneCurvePV2012 = long,
            ToneCurvePV2012Red = { 0, 0, 255, 250 } } })

        local reply = Handler.get({ photo_ids = { "7" }, keys = { "ToneCurvePV2012", "ToneCurvePV2012Red", "ExtendedToneCurvePV2012" } },
            helper.requestContext())

        local settings = reply.data.photos[1].settings
        assert.are.same(long, settings.ToneCurvePV2012)
        assert.are.same({ 0, 0, 255, 250 }, settings.ToneCurvePV2012Red)
        assert.are.same(long, settings.ExtendedToneCurvePV2012)
    end)

    it("lists one photo's top-level keys with their type and table size, without values, inside the read gate", function()
        local Handler, inside = setup({ ["7"] = {
            ProcessVersion = "15.4", Exposure2012 = 0.5, AutoGrayscaleMix = true, MaskGroupBasedCorrections = MASKS,
        } })

        local reply = Handler.get({ photo_ids = { "7" } }, helper.requestContext())

        assert.are.same({ { photo_id = "7", keys = {
            { name = "AutoGrayscaleMix", type = "boolean" },
            { name = "Exposure2012", type = "number" },
            { name = "MaskGroupBasedCorrections", type = "table", count = 1 },
            { name = "ProcessVersion", type = "string" },
        } } }, reply.data.photos)
        assert.are.same({ true }, inside)
    end)

    it("returns each photo's requested keys unrenamed and lists per photo the names it does not carry", function()
        local Handler = setup({
            ["7"] = { ProcessVersion = "15.4", MaskGroupBasedCorrections = MASKS },
            ["8"] = { ProcessVersion = "15.4", DepthMapInfo = { 1 } },
        })

        local reply = Handler.get({ photo_ids = { "7", "/8.cr2", "404" },
            keys = { "ProcessVersion", "MaskGroupBasedCorrections", "DepthMapInfo" } }, helper.requestContext())

        local first, second = reply.data.photos[1], reply.data.photos[2]
        assert.are.equal("7", first.photo_id)
        assert.are.same(MASKS, first.settings.MaskGroupBasedCorrections)
        assert.are.same({ "DepthMapInfo" }, first.absent)
        assert.are.equal("8", second.photo_id)
        assert.are.same({ 1 }, second.settings.DepthMapInfo)
        assert.are.same({ "MaskGroupBasedCorrections" }, second.absent)
        assert.are.same({ "404" }, reply.not_found)
        local JSON = require 'JSON'
        assert.are.same(MASKS, JSON:decode(JSON:encode(reply.data)).photos[1].settings.MaskGroupBasedCorrections)
    end)

    it("marks values JSON cannot carry instead of failing or dropping them", function()
        local fn = function() end
        local Handler = setup({ ["7"] = {
            Gapped = { 1, nil, 3 },
            Mixed = { 10, label = "x" },
            NotANumber = 0 / 0,
            Infinite = { level = math.huge },
            Callable = fn,
        } })

        local settings = Handler.get({ photo_ids = { "7" }, keys = { "Gapped", "Mixed", "NotANumber", "Infinite", "Callable" } },
            helper.requestContext()).data.photos[1].settings

        assert.are.same({ ["$lua"] = "table", entries = { { 1, 1 }, { 3, 3 } } }, settings.Gapped)
        assert.are.same({ ["$lua"] = "table", entries = { { 1, 10 }, { "label", "x" } } }, settings.Mixed)
        assert.are.equal("number", settings.NotANumber["$lua"])
        assert.are.same({ level = { ["$lua"] = "number", value = tostring(math.huge) } }, settings.Infinite)
        assert.are.same({ ["$lua"] = "function", value = tostring(fn) }, settings.Callable)
        assert.is_true(pcall(function() return require('JSON'):encode(settings) end))
    end)

    it("leaves the photos that no longer fit the reply size remaining, and fails a photo too big alone", function()
        local half = string.rep("x", 600000)
        local Handler = setup({ ["7"] = { Big = half }, ["8"] = { Big = half }, ["9"] = { Big = "small" },
            ["10"] = { Big = string.rep("x", 1000001) } })

        local reply = Handler.get({ photo_ids = { "7", "8", "9" }, keys = { "Big" } }, helper.requestContext())
        assert.are.same({ "7" }, { reply.data.photos[1].photo_id })
        assert.are.equal(1, #reply.data.photos)
        assert.are.same({ "8", "9" }, reply.remaining)

        local alone = Handler.get({ photo_ids = { "10" }, keys = { "Big" } }, helper.requestContext())
        assert.is_nil(alone.data)
        assert.are.equal("10", alone.failed[1].photo_id)
        assert.truthy(alone.failed[1].reason:find("request fewer keys", 1, true))
    end)

    it("leaves the photos past the request's time remaining", function()
        local Handler = setup({ ["7"] = { A = 1 }, ["8"] = { A = 2 } })
        local reply = Handler.get({ photo_ids = { "7", "8" }, keys = { "A" } },
            helper.requestContext(nil, { isCanceled = function() return true end }))
        assert.is_nil(reply.data)
        assert.are.same({ "7", "8" }, reply.remaining)
    end)
end)
