local helper = require "spec_helper"

describe("reference style matching", function()
    local handler, catalog, reference, targets, applied, events, snapshotState
    local previous = {}
    before_each(function()
        for _, name in ipairs({ "HandlerDevelop", "HandlerSnapshots", "DevelopSession", "DevelopReadBack" }) do
            previous[name] = package.loaded[name]
            package.loaded[name] = nil
        end
        applied, events, snapshotState = {}, {}, {}
        reference = helper.fakePhoto({
            id = "1",
            path = "/reference.raw",
            developSettings = {
                Exposure2012 = 0.5,
                Contrast2012 = 20,
                ToneCurvePV2012 = { 0, 0, 255, 255 },
                CropTop = 0.1,
                CropLeft = 0.2,
                CropBottom = 0.9,
                CropRight = 0.8,
                CropAngle = 10,
                PerspectiveVertical = 20,
                PerspectiveFuture = 99,
                WhiteBalance = "Custom",
                Temperature = 6000,
                Tint = 10,
                LensProfileEnable = 1,
                LensManualDistortionAmount = 10,
                MaskGroupBasedCorrections = { { unsafe = true } },
                UnknownSetting = 1,
            },
        })
        targets = {}
        for index = 2, 4 do
            local id = tostring(index)
            local photo = helper.fakePhoto({
                id = id,
                developSettings = {
                    Exposure2012 = 0,
                    Contrast2012 = 0,
                    ToneCurvePV2012 = { 0, 0, 255, 255 },
                },
            })
            snapshotState[id] = {}
            photo.getDevelopSnapshots = function() return snapshotState[id] end
            photo.createDevelopSnapshot = function(_, name)
                events[#events + 1] = "snapshot:" .. id
                snapshotState[id][#snapshotState[id] + 1] = { snapshotID = id .. "-snapshot", name = name }
                return true
            end
            photo.applyDevelopSettings = function(_, settings)
                events[#events + 1] = "apply:" .. id
                applied[id] = settings
                for key, value in pairs(settings) do
                    photo:getDevelopSettings()[key] = value
                end
            end
            targets[#targets + 1] = photo
        end
        catalog = helper.fakeCatalog({ photos = { reference, targets[1], targets[2], targets[3] } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDate = { currentTime = function() return 123 end },
            LrTasks = { pcall = pcall, sleep = function() end },
            LrLogger = helper.defaultLrLogger(),
            LrDevelopController = {},
            LrFileUtils = {},
            LrPathUtils = {},
            LrApplicationView = { getCurrentModuleName = function() return "library" end },
            LrSelection = {},
        })
        handler = require "HandlerDevelop"
    end)
    after_each(function()
        for _, name in ipairs({ "HandlerDevelop", "HandlerSnapshots", "DevelopSession", "DevelopReadBack" }) do
            package.loaded[name] = previous[name]
        end
    end)

    it("transfers exactly the keys the generated table marks as style, a newly added one included", function()
        local contract = require "Contract"
        local patched = setmetatable({ DEVELOP_KEYS = {} }, { __index = contract })
        for i, key in ipairs(contract.DEVELOP_KEYS) do
            patched.DEVELOP_KEYS[i] = key
        end
        table.insert(patched.DEVELOP_KEYS, { name = "FixtureLook", style = true })
        table.insert(patched.DEVELOP_KEYS, { name = "FixtureGeometry" })
        reference:getDevelopSettings().FixtureLook = 3
        reference:getDevelopSettings().FixtureGeometry = 7
        package.loaded.Contract = patched
        package.loaded.HandlerDevelop = nil
        local ok, err = pcall(
            function() require("HandlerDevelop").matchPhotoStyle({ reference_id = "1", target_ids = { "2" } }) end
        )
        package.loaded.Contract = contract
        assert.is_true(ok, tostring(err))
        assert.same({
            Exposure2012 = 0.5,
            Contrast2012 = 20,
            ToneCurvePV2012 = { 0, 0, 255, 255 },
            ExtendedToneCurvePV2012 = { 0, 0, 255, 255 },
            FixtureLook = 3,
        }, applied["2"])
    end)

    it("transfers a calibration key and leaves a perspective offset, by the generated style flags", function()
        reference:getDevelopSettings().RedHue = 20
        reference:getDevelopSettings().PerspectiveX = 10
        handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.equals(20, applied["2"].RedHue)
        assert.is_nil(applied["2"].PerspectiveX)
    end)

    it("matches a target named twice once, with one snapshot and one result", function()
        local reply = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "2", 2 } })
        assert.same({ "snapshot:2", "apply:2" }, events)
        assert.are.equal(1, reply.data.matched)
        assert.are.equal(1, #reply.data.results)
    end)

    it("transfers the reference curve from its Extended field into both fields of each target", function()
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
        reference:getDevelopSettings().ExtendedToneCurvePV2012 = long
        handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.same(long, applied["2"].ToneCurvePV2012)
        assert.same(long, applied["2"].ExtendedToneCurvePV2012)
    end)

    it("snapshots before applying global style and counts changed values", function()
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3" } })
        assert.same({ "snapshot:2", "apply:2", "snapshot:3", "apply:3" }, events)
        assert.same({
            Exposure2012 = 0.5,
            Contrast2012 = 20,
            ToneCurvePV2012 = { 0, 0, 255, 255 },
            ExtendedToneCurvePV2012 = { 0, 0, 255, 255 },
        }, applied["2"])
        assert.equals(2, result.data.matched)
        assert.equals(2, result.data.results[1].settings_changed)
        assert.equals("2-snapshot", result.data.results[1].snapshot.id)
        assert.matches("Style match from 1", result.data.results[1].snapshot.name)
        assert.is_nil(result.problem)
        assert.is_nil(result.failed)
        assert.is_false(catalog:getQueriedInsideReadAccess())
    end)

    it("counts as matched only the targets the read-back verified", function()
        local context =
            helper.requestContext(nil, { stopping = function() return false end, timeLeft = function() return 1 end })
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3" } }, context)
        assert.equals(0, result.data.matched)
        assert.same({}, result.data.results)
        assert.same({ "2", "3" }, { result.unknown[1].photo_id, result.unknown[2].photo_id })
    end)

    it("fails a target whose saved settings Lightroom does not return, writes nothing to it and continues", function()
        targets[2].getDevelopSettings = function() return nil end
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3", "4" } })
        assert.is_nil(applied["3"])
        assert.truthy(applied["2"] and applied["4"])
        assert.equals(2, result.data.matched)
        assert.same({ { photo_id = "3", reason = "Lightroom returned no saved settings for photo 3" } }, result.failed)
    end)

    it("fails a target whose snapshot step raised inside its gate, writes nothing to it and continues", function()
        targets[2].createDevelopSnapshot = function() error("snapshot interrupted") end
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3", "4", "999" } })
        assert.same({ "snapshot:2", "apply:2", "snapshot:4", "apply:4" }, events)
        assert.is_nil(applied["3"])
        assert.same({ "999" }, result.not_found)
        assert.is_nil(result.unknown)
        assert.equals("3", result.failed[1].photo_id)
        assert.matches("snapshot interrupted", result.failed[1].reason)
    end)

    it("answers unknown, without writing, when the snapshot it created cannot be read back", function()
        targets[1].getDevelopSnapshots = function() return {} end
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.equals(0, result.data.matched)
        assert.is_nil(applied["2"])
        assert.is_nil(result.failed)
        assert.matches("could not be read back", result.unknown[1].reason)
        assert.matches("written before this stopped: Create Develop Snapshot", result.unknown[1].reason)
    end)

    it("fails a target whose snapshot Lightroom refused, and writes nothing to it", function()
        targets[1].createDevelopSnapshot = function() return false end
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.is_nil(applied["2"])
        assert.is_nil(result.unknown)
        assert.equals("2", result.failed[1].photo_id)
        assert.matches("Snapshot name already exists", result.failed[1].reason)
    end)

    it("rejects reference aliases anywhere in the targets before snapshotting", function()
        for _, id in ipairs({ "1", "/reference.raw" }) do
            assert.are.equal(
                "Reference photo must not appear in target_ids",
                helper.failedOf(function() handler.matchPhotoStyle({ reference_id = 1, target_ids = { "2", id } }) end)
            )
        end
        assert.same({}, events)
    end)

    it("answers unknown for a target that throws after Lightroom stored part of the style", function()
        targets[1].applyDevelopSettings = function(photo, settings)
            photo:getDevelopSettings().Exposure2012 = settings.Exposure2012
            error("write interrupted")
        end
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.is_nil(result.failed)
        assert.equals("2", result.unknown[1].photo_id)
        assert.matches("write interrupted", result.unknown[1].reason)
    end)

    it("never transfers a key another tool writes", function()
        reference:getDevelopSettings().ConvertToGrayscale = false
        targets[1]:getDevelopSettings().ConvertToGrayscale = false
        handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2" } })
        assert.is_nil(applied["2"].ConvertToGrayscale)
    end)

    it("fails a target whose treatment differs from the reference and writes nothing to it", function()
        reference:getDevelopSettings().ConvertToGrayscale = true
        reference:getDevelopSettings().GrayMixerRed = -20
        targets[1]:getDevelopSettings().ConvertToGrayscale = false
        targets[2]:getDevelopSettings().ConvertToGrayscale = true
        local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3" } })
        assert.is_nil(applied["2"])
        assert.equals("2", result.failed[1].photo_id)
        assert.matches(
            "treatment differs from the reference; convert it with set_treatment, then match",
            result.failed[1].reason
        )
        assert.equals(-20, applied["3"].GrayMixerRed)
    end)

    for _, case in ipairs({
        {
            what = "applying raises",
            arrange = function()
                targets[1].applyDevelopSettings = function() error("write refused") end
                return "write refused"
            end,
        },
        {
            what = "the catalog stays busy for the style write",
            arrange = function()
                local aborted = false
                catalog = helper.fakeCatalog({
                    photos = { reference, targets[1], targets[2], targets[3] },
                    writeAccessAborts = function(action)
                        if action ~= "Match Photo Style" or aborted then return false end
                        aborted = true
                        return true
                    end,
                })
                return helper.catalogBusy("Match Photo Style")
            end,
        },
    }) do
        it("answers unknown naming the recovery snapshot it kept when " .. case.what .. ", and continues", function()
            local problem = case.arrange()
            local result = handler.matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3" } })
            assert.is_nil(result.failed)
            assert.equals("2", result.unknown[1].photo_id)
            assert.matches(
                problem .. "; the style was not confirmed stored and recovery snapshot Style match from 1",
                result.unknown[1].reason,
                1,
                true
            )
            assert.matches("was kept", result.unknown[1].reason, 1, true)
            assert.equals(1, #snapshotState["2"])
            assert.equals(1, result.data.matched)
            assert.is_not_nil(applied["3"])
        end)
    end
end)

describe("reference style matching within the budget", function()
    it("matches the targets that fit and lists the rest as remaining", function()
        local reference = helper.fakePhoto({ id = "1", path = "/r.raw", developSettings = { Exposure2012 = 0.5 } })
        local targets = {}
        for index = 2, 3 do
            local id = tostring(index)
            local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".raw", developSettings = {} })
            local snapshots = {}
            photo.getDevelopSnapshots = function() return snapshots end
            photo.createDevelopSnapshot = function(_, name)
                snapshots[#snapshots + 1] = { snapshotID = id, name = name }
                return true
            end
            targets[#targets + 1] = photo
        end
        local catalog = helper.fakeCatalog({ photos = { reference, targets[1], targets[2] } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDate = { currentTime = function() return 123 end },
            LrTasks = { pcall = pcall, sleep = function() end },
            LrLogger = helper.defaultLrLogger(),
            LrDevelopController = {},
            LrFileUtils = {},
            LrPathUtils = {},
            LrSelection = {},
            LrApplicationView = { getCurrentModuleName = function() return "library" end },
        })
        for _, name in ipairs({ "HandlerDevelop", "HandlerSnapshots", "DevelopSession", "DevelopReadBack" }) do
            package.loaded[name] = nil
        end
        local asked = 0
        local context = helper.requestContext(nil, {
            stopping = function()
                asked = asked + 1
                return asked > 1
            end,
        })

        local result =
            require("HandlerDevelop").matchPhotoStyle({ reference_id = "1", target_ids = { "2", "3" } }, context)

        assert.equals(1, result.data.matched)
        assert.same({ "3" }, result.remaining)
    end)
end)
