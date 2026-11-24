local helper = require "spec_helper"

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
            if settings == false then return nil end
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
    return require "HandlerRawDevelopSettings", inside
end

describe("HandlerRawDevelopSettings.get", function()
    it("fails a photo whose saved settings Lightroom does not return and keeps the others' rows", function()
        local Handler = setup({ ["1"] = { Exposure2012 = 1 }, ["2"] = false, ["3"] = { Exposure2012 = 3 } })

        local reply = Handler.get({ photo_ids = { "1", "2", "3" }, keys = { "Exposure2012" } }, helper.requestContext())

        assert.are.same({ "1", "3" }, { reply.data.photos[1].photo_id, reply.data.photos[2].photo_id })
        assert.are.same(
            { { photo_id = "2", reason = "Lightroom returned no saved settings for photo 2" } },
            reply.failed
        )
    end)

    it("returns a point curve from its Extended field first, and the Extended field itself when named", function()
        local long = {
            0,
            0,
            13,
            15,
            27,
            31,
            40,
            46,
            54,
            61,
            67,
            76,
            81,
            91,
            94,
            105,
            107,
            119,
            121,
            133,
            134,
            146,
            148,
            160,
            161,
            172,
            174,
            186,
            188,
            199,
            201,
            212,
            214,
            226,
            228,
            238,
            241,
            249,
            255,
            255,
        }
        local Handler = setup({
            ["7"] = {
                ToneCurvePV2012 = { 0, 0, 128, 120, 255, 255 },
                ExtendedToneCurvePV2012 = long,
                ToneCurvePV2012Red = { 0, 0, 255, 250 },
            },
        })

        local reply = Handler.get(
            { photo_ids = { "7" }, keys = { "ToneCurvePV2012", "ToneCurvePV2012Red", "ExtendedToneCurvePV2012" } },
            helper.requestContext()
        )

        local settings = reply.data.photos[1].settings
        assert.are.same(long, settings.ToneCurvePV2012)
        assert.are.same({ 0, 0, 255, 250 }, settings.ToneCurvePV2012Red)
        assert.are.same(long, settings.ExtendedToneCurvePV2012)
    end)

    it(
        "lists one photo's top-level keys with their type and table size, without values, inside the read gate",
        function()
            local Handler, inside = setup({
                ["7"] = {
                    ProcessVersion = "15.4",
                    Exposure2012 = 0.5,
                    AutoGrayscaleMix = true,
                    MaskGroupBasedCorrections = MASKS,
                },
            })

            local reply = Handler.get({ photo_ids = { "7" } }, helper.requestContext())

            assert.are.same({
                {
                    photo_id = "7",
                    keys = {
                        { name = "AutoGrayscaleMix", type = "boolean" },
                        { name = "Exposure2012", type = "number" },
                        { name = "MaskGroupBasedCorrections", type = "table", count = 1 },
                        { name = "ProcessVersion", type = "string" },
                    },
                },
            }, reply.data.photos)
            assert.are.same({ true }, inside)
        end
    )

    it("returns each photo's requested keys unrenamed and lists per photo the names it does not carry", function()
        local Handler = setup({
            ["7"] = { ProcessVersion = "15.4", MaskGroupBasedCorrections = MASKS },
            ["8"] = { ProcessVersion = "15.4", DepthMapInfo = { 1 } },
        })

        local reply = Handler.get({
            photo_ids = { "7", "/8.cr2", "404" },
            keys = { "ProcessVersion", "MaskGroupBasedCorrections", "DepthMapInfo" },
        }, helper.requestContext())

        local first, second = reply.data.photos[1], reply.data.photos[2]
        assert.are.equal("7", first.photo_id)
        assert.are.same(MASKS, first.settings.MaskGroupBasedCorrections)
        assert.are.same({ "DepthMapInfo" }, first.absent)
        assert.are.equal("8", second.photo_id)
        assert.are.same({ 1 }, second.settings.DepthMapInfo)
        assert.are.same({ "MaskGroupBasedCorrections" }, second.absent)
        assert.are.same({ "404" }, reply.not_found)
        local JSON = require "JSON"
        assert.are.same(MASKS, JSON:decode(JSON:encode(reply.data)).photos[1].settings.MaskGroupBasedCorrections)
    end)

    it("marks values JSON cannot carry instead of failing or dropping them", function()
        local fn = function() end
        local Handler = setup({
            ["7"] = {
                Gapped = { 1, nil, 3 },
                Mixed = { 10, label = "x" },
                NotANumber = 0 / 0,
                Infinite = { level = math.huge },
                Callable = fn,
            },
        })

        local settings = Handler.get(
            { photo_ids = { "7" }, keys = { "Gapped", "Mixed", "NotANumber", "Infinite", "Callable" } },
            helper.requestContext()
        ).data.photos[1].settings

        assert.are.same({ ["$lua"] = "table", entries = { { 1, 1 }, { 3, 3 } } }, settings.Gapped)
        assert.are.same({ ["$lua"] = "table", entries = { { 1, 10 }, { "label", "x" } } }, settings.Mixed)
        assert.are.equal("number", settings.NotANumber["$lua"])
        assert.are.same({ level = { ["$lua"] = "number", value = tostring(math.huge) } }, settings.Infinite)
        assert.are.same({ ["$lua"] = "function", value = tostring(fn) }, settings.Callable)
        assert.is_true(pcall(function() return require("JSON"):encode(settings) end))
    end)

    it("leaves the photos that no longer fit the reply size remaining, and fails a photo too big alone", function()
        local half = string.rep("x", 600000)
        local Handler = setup({
            ["7"] = { Big = half },
            ["8"] = { Big = half },
            ["9"] = { Big = "small" },
            ["10"] = { Big = string.rep("x", 1000001) },
        })

        local reply = Handler.get({ photo_ids = { "7", "8", "9" }, keys = { "Big" } }, helper.requestContext())
        assert.are.same({ "7" }, { reply.data.photos[1].photo_id })
        assert.are.equal(1, #reply.data.photos)
        assert.are.same({ "8", "9" }, reply.remaining)

        local alone = Handler.get({ photo_ids = { "10" }, keys = { "Big" } }, helper.requestContext())
        assert.is_nil(alone.data)
        assert.are.equal("10", alone.failed[1].photo_id)
        assert.truthy(alone.failed[1].reason:find("request fewer keys", 1, true))
    end)

    describe("budget on 1 MB of settings data", function()
        local LIMIT = 1000000
        local function dataSize(reply) return #require("JSON"):encode(reply.data) end
        local function get(settingsById, ids)
            local Handler = setup(settingsById)
            return Handler.get({ photo_ids = ids, keys = { "Big" } }, helper.requestContext())
        end
        local function pairAt(extra)
            local pair = dataSize(get({ ["7"] = { Big = "x" }, ["8"] = { Big = "x" } }, { "7", "8" }))
            local first = 600000
            return get({
                ["7"] = { Big = string.rep("x", first) },
                ["8"] = { Big = string.rep("x", LIMIT - pair - first + 2 + extra) },
            }, { "7", "8" })
        end

        it("fits_counts_settings_data: returns two photos whose encoded data is exactly 1 MB", function()
            local reply = pairAt(0)
            assert.are.equal(LIMIT, dataSize(reply))
            assert.are.same({ "7", "8" }, { reply.data.photos[1].photo_id, reply.data.photos[2].photo_id })
            assert.is_nil(reply.remaining)
        end)

        it("fits_counts_settings_data: lists the photo one byte past 1 MB of data as remaining", function()
            local reply = pairAt(1)
            assert.are.same({ "7" }, { reply.data.photos[1].photo_id })
            assert.are.equal(1, #reply.data.photos)
            assert.are.same({ "8" }, reply.remaining)
        end)

        it("fits_counts_settings_data: fails a photo whose own data passes 1 MB and returns the next", function()
            local single = dataSize(get({ ["7"] = { Big = "x" } }, { "7" }))
            local reply = get({ ["7"] = { Big = string.rep("x", LIMIT - single + 2) }, ["8"] = { Big = "small" } }, {
                "7",
                "8",
            })
            assert.are.equal("7", reply.failed[1].photo_id)
            assert.truthy(reply.failed[1].reason:find("request fewer keys", 1, true))
            assert.are.same({ { photo_id = "8", settings = { Big = "small" }, absent = {} } }, reply.data.photos)
        end)
    end)

    it("leaves the photos past the request's time remaining", function()
        local Handler = setup({ ["7"] = { A = 1 }, ["8"] = { A = 2 } })
        local reply = Handler.get(
            { photo_ids = { "7", "8" }, keys = { "A" } },
            helper.requestContext(nil, { isCanceled = function() return true end })
        )
        assert.is_nil(reply.data)
        assert.are.same({ "7", "8" }, reply.remaining)
    end)

    it("read_shows_no_progress: reports no progress and decides the budget with no read gate open", function()
        local Handler = setup({ ["7"] = { A = 1 }, ["8"] = { A = 2 } })
        local catalog = import("LrApplication").activeCatalog()
        local reports, gateAtStopping = 0, {}
        local context = helper.requestContext(nil, {
            report = function() reports = reports + 1 end,
            stopping = function()
                gateAtStopping[#gateAtStopping + 1] = catalog.isInsideReadAccess()
                return false
            end,
        })

        local reply = Handler.get({ photo_ids = { "7", "8" }, keys = { "A" } }, context)

        assert.are.same({ "7", "8" }, { reply.data.photos[1].photo_id, reply.data.photos[2].photo_id })
        assert.are.equal(0, reports)
        assert.are.same({ false, false }, gateAtStopping)
    end)
end)

describe("HandlerRawDevelopSettings.byInput", function()
    it("answers one row per input in order: aliases share their photo's values, then not found", function()
        local Handler = setup({ ["7"] = { Exposure2012 = 0.5, Contrast2012 = 10 } })

        local reply = Handler.byInput(
            { photo_ids = { "7", "/7.cr2", "404" }, keys = { "Exposure2012" } },
            helper.requestContext()
        )

        assert.are.same({
            rows = {
                { photo_id = "7", settings = { Exposure2012 = 0.5 } },
                { photo_id = "7", settings = { Exposure2012 = 0.5 } },
                { not_found = true },
            },
        }, reply)
    end)

    it("fails a row whose read returns nothing and lists the photos past the budget as remaining", function()
        local Handler, inside = setup({ ["1"] = false, ["2"] = { Exposure2012 = 2 }, ["3"] = { Exposure2012 = 3 } })
        local context = helper.requestContext(nil, { stopping = function() return #inside >= 2 end })

        local reply = Handler.byInput({ photo_ids = { "1", "2", "3", "/3.cr2" }, keys = { "Exposure2012" } }, context)

        assert.are.same({
            rows = {
                { photo_id = "1", failed = "Lightroom returned no saved settings for photo 1" },
                { photo_id = "2", settings = { Exposure2012 = 2 } },
                { remaining = true },
                { remaining = true },
            },
        }, reply)
    end)
end)
