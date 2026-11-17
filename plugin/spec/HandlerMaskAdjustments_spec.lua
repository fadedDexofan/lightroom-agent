local helper = require 'spec_helper'
local Develop = require 'fake_mask_develop'

local function setup(opts)
    opts = opts or {}
    local unreadable, reverts = {}, {}
    for name in pairs(opts.unreadable or {}) do unreadable[name] = true end
    local ctx = Develop.build({
        photos = opts.photos,
        version = false,
        rejectSet = opts.rejectSet,
        ignoreSet = opts.ignoreSet,
        neverCommit = opts.neverCommit,
        commitLagSleeps = opts.commitLagSleeps,
        handler = "HandlerMaskAdjustments",
        modules = { "HandlerMaskAdjustments", "DevelopSession", "LocalSliders", "MaskSelection" },
        onSleep = function()
            for _, revert in ipairs(reverts) do revert() end
            reverts = {}
        end,
        extend = function(controller, built)
            built.module = opts.startModule or built.module
            local listMasks, getValue, setValue = controller.getAllMasks, controller.getValue, controller.setValue
            if opts.listedEmpty then
                controller.getAllMasks = function()
                    listMasks()
                    return {}
                end
            end
            if opts.selectIgnored then
                controller.selectMask = function(id) built.calls.selectMask[#built.calls.selectMask + 1] = id end
            end
            if opts.ranges then
                controller.getRange = function(name)
                    local range = opts.ranges[name]
                    if range then return range[1], range[2] end
                    error("no range")
                end
            end
            controller.getValue = function(name)
                local value = getValue(name)
                if unreadable[name] then return nil end
                return value
            end
            controller.setValue = function(name, value)
                if opts.roundSet then value = math.floor(value + 0.5) end
                setValue(name, value)
                if opts.unreadableAfterSet and opts.unreadableAfterSet[name] then unreadable[name] = true end
                local values = built.currentValues()
                if opts.revertAfterSettle and opts.revertAfterSettle[name] then
                    reverts[#reverts + 1] = function() values[name] = opts.revertAfterSettle[name] end
                end
                if opts.stealSelectionOnSet then built.selectedMaskOf[built.active] = opts.stealSelectionOnSet end
            end
            if opts.withoutStopTracking then controller.stopTracking = nil end
            if opts.withoutSetValue then controller.setValue = nil end
            if opts.withoutMaskApi then
                controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
            end
            if opts.maskMissingFromStore then
                for _, photo in ipairs(built.photos) do
                    photo.getDevelopSettings = function() return { MaskGroupBasedCorrections = {} } end
                end
            end
        end,
    })
    return ctx.Handler, ctx.calls, ctx.catalog, ctx.valuesOf, ctx.photos, ctx.selectedMaskOf
end

local function twoMasks()
    return {
        ["mask-a"] = { local_Exposure = 0.5, local_Contrast = 10, local_Shadows = 20 },
        ["mask-b"] = { local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 },
    }
end

local function everyPhotoAndMask(masks)
    return { photos = { { id = "1", masks = masks, selectedMask = "mask-b" } } }
end

describe("HandlerMaskAdjustments.setMaskAdjustments", function()
    it("changes only the requested sliders of the requested mask", function()
        local Handler, calls, _, valuesOf, photos = setup(everyPhotoAndMask(twoMasks()))

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 1.25, local_Shadows = -15 },
        }).data

        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ local_Exposure = 1.25, local_Shadows = -15 }, r.adjustments)
        assert.are.same({
            { slider = "local_Exposure", from = 0.5, to = 1.25 },
            { slider = "local_Shadows", from = 20, to = -15 },
        }, r.changed)
        assert.are.same({}, r.unchanged)
        assert.are.same({ local_Exposure = 1.25, local_Contrast = 10, local_Shadows = -15 }, valuesOf[photos[1]]["mask-a"])
        assert.are.same({ local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 }, valuesOf[photos[1]]["mask-b"])
        assert.are.equal(2, #calls.setValue)
    end)

    it("writes sliders in a fixed order whatever the key order", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Shadows = 1, local_Contrast = 2, local_Exposure = 3 },
        })

        assert.are.same({ "local_Exposure", "local_Contrast", "local_Shadows" },
            { calls.setValue[1][1], calls.setValue[2][1], calls.setValue[3][1] })
    end)

    it("skips a slider already at the value and writes nothing when all are", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 0.5, local_Contrast = 10 },
        }).data

        assert.are.same({}, r.changed)
        assert.are.same({ "local_Exposure", "local_Contrast" }, r.unchanged)
        assert.are.equal(0, #calls.setValue)
    end)

    it("puts back the previously selected mask, module and photo selection", function()
        local Handler, calls, _, _, _, selectedMaskOf = setup({
            photos = {
                { id = "1" },
                { id = "2", masks = twoMasks(), selectedMask = "mask-b" },
            },
        })

        Handler.setMaskAdjustments({ photo_id = "2", mask_id = "mask-a", adjustments = { local_Contrast = 0 } })

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
        assert.are.equal("mask-b", calls.selectMask[#calls.selectMask])
        local photoTwo
        for photo, id in pairs(selectedMaskOf) do
            if photo.localIdentifier == "2" then photoTwo = id end
        end
        assert.are.equal("mask-b", photoTwo)
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup(everyPhotoAndMask(twoMasks()))

        local byNumber = Handler.setMaskAdjustments({ photo_id = 1, mask_id = "mask-a", adjustments = { local_Contrast = 10 } }).data
        local byPath = Handler.setMaskAdjustments({ photo_id = "/1.jpg", mask_id = "mask-a", adjustments = { local_Contrast = 10 } }).data

        assert.are.equal("1", byNumber.photo_id)
        assert.are.equal("1", byPath.photo_id)
    end)

    it("writes a value the schema accepts whatever range Lightroom reports for the slider", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            ranges = { local_Contrast = { -50, 50 } },
        })

        local r = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 60 } })

        assert.are.same({ { slider = "local_Contrast", from = 10, to = 60 } }, r.data.changed)
    end)

    it("names the unknown mask, changes no mask and restores the view", function()
        local Handler, calls, _, valuesOf, photos = setup(everyPhotoAndMask(twoMasks()))

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "nope", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.truthy(err:find("mask-a, mask-b", 1, true))
        assert.are.equal(0, #calls.setValue)
        assert.are.equal(0, #calls.selectMask)
        assert.are.equal(10, valuesOf[photos[1]]["mask-a"].local_Contrast)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("reports a photo without masks as having no such mask", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = {} } } })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Mask not found on photo 1: m (masks on this photo: none)", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("says Develop has not listed the saved masks instead of reporting the mask missing", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = { m = { Contrast = 0 } } } }, listedEmpty = true })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Develop lists 0 of the 1 masks in photo 1's saved settings", 1, true))
        assert.is_nil(err:find("Mask not found", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("names the photo when it is unknown and never touches Develop", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        assert.are.equal("404", helper.notFoundOf(function()
            Handler.setMaskAdjustments({ photo_id = "404", mask_id = "mask-a", adjustments = { local_Tint = 1 } })
        end))
        assert.are.equal(0, #calls.modules)
    end)

    it("fails when Lightroom never selects the mask", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            selectIgnored = true,
        })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Could not select mask mask-a on photo 1", 1, true))
        assert.are.equal(0, #calls.setValue)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("fails before writing when a slider cannot be read on the mask", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            unreadable = { local_Shadows = true },
        })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Contrast = 1, local_Shadows = 2 },
            })
        end)

        assert.truthy(err:find("local_Shadows is not available on mask mask-a", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("accepts a value Lightroom rounds to a whole number", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            roundSet = true,
        })

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Contrast = 12.4 },
        }).data

        assert.are.same({ local_Contrast = 12 }, r.adjustments)
        assert.are.equal(12, r.changed[1].to)
    end)

    it("retries a write Lightroom ignored once, then answers partial with the sliders already written", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            ignoreSet = { local_Contrast = true },
        })

        local reply = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 2, local_Contrast = 40 },
        })

        assert.truthy(reply.problem:find("Lightroom did not keep local_Contrast 40 (reads 10)", 1, true))
        assert.are.same({ { slider = "local_Exposure", from = 0.5, to = 2 } }, reply.data.changed)
        assert.are.equal("1", reply.data.photo_id)
        assert.are.equal(3, #calls.setValue)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("refuses with no effect when the first slider Lightroom ignores is still at its old value", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            ignoreSet = { local_Contrast = true },
        })

        assert.matches("nothing was written", helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 40 } })
        end), 1, true)
    end)

    it("reports a problem, not a refusal, when the slider cannot be read after the write", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            unreadableAfterSet = { local_Contrast = true },
        })

        local reply = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 9 },
        })

        assert.truthy(reply.problem:find("Lightroom did not keep local_Contrast 9 (reads nothing)", 1, true))
        assert.is_nil(reply.data.adjustments.local_Contrast)
    end)

    it("answers partial, naming the change Lightroom dropped after showing it", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            revertAfterSettle = { local_Contrast = 10 },
        })

        local reply = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Contrast = 40 },
        })

        assert.truthy(reply.problem:find("Lightroom did not keep local_Contrast 40 (reads 10)", 1, true))
        assert.are.equal(10, reply.data.adjustments.local_Contrast)
    end)

    it("commits the sliders to the photo with a forced flush instead of waiting for Lightroom's own timer", function()
        local Handler, calls, _, _, photos = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            commitLagSleeps = 100000,
        })

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.are.same({ true }, calls.stopTracking)
        local savedExposure
        for _, entry in ipairs(photos[1]:getDevelopSettings().MaskGroupBasedCorrections) do
            if entry.CorrectionID == "mask-a" then savedExposure = entry["Stored_local_Exposure"] end
        end
        assert.are.equal(2, savedExposure)
    end)

    it("works on a Lightroom without stopTracking by waiting for the save", function()
        local Handler, _, _, _, photos = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            commitLagSleeps = 12,
            withoutStopTracking = true,
        })

        local reply = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.is_nil(reply.unknown)
        assert.is_nil(reply.problem)
        local savedExposure
        for _, entry in ipairs(photos[1]:getDevelopSettings().MaskGroupBasedCorrections) do
            if entry.CorrectionID == "mask-a" then savedExposure = entry["Stored_local_Exposure"] end
        end
        assert.are.equal(2, savedExposure)
    end)

    it("flushes edits pending on a photo already open in Develop before touching it", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            startModule = "develop",
        })

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 0.5 } })

        assert.are.same({ true }, calls.stopTracking)
    end)

    it("does not flush when it has to open the photo, which Lightroom saves on switching", function()
        local Handler, calls = setup({
            photos = {
                { id = "1" },
                { id = "2", masks = twoMasks(), selectedMask = "mask-b" },
            },
            startModule = "develop",
        })

        Handler.setMaskAdjustments({ photo_id = "2", mask_id = "mask-a", adjustments = { local_Exposure = 0.5 } })

        assert.are.same({}, calls.stopTracking)
    end)

    it("does not wait for a save when no slider changed", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            neverCommit = true,
        })

        local reply = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 0.5 },
        })

        assert.is_nil(reply.unknown)
        assert.is_nil(reply.problem)
        assert.are.same({}, reply.data.changed)
    end)

    it("answers unknown naming the late save when Lightroom never saves the sliders", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            neverCommit = true,
        })

        local reply = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.truthy(reply.unknown[1].reason:find("had not saved them to the photo's settings after 8 s", 1, true))
        assert.are.equal("1", reply.unknown[1].photo_id)
        assert.are.equal("local_Exposure", reply.data.changed[1].slider)
    end)

    it("answers unknown when the mask is absent from the photo's saved settings", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            maskMissingFromStore = true,
        })

        local reply = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.truthy(reply.unknown[1].reason:find("had not saved them", 1, true))
    end)

    it("refuses with nothing written when Lightroom rejects the first slider and it keeps its old value", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            rejectSet = { local_Contrast = "slider is disabled" },
        })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 40 } })
        end)

        assert.truthy(err:find("Lightroom rejected local_Contrast 40: ", 1, true), err)
        assert.truthy(err:find("slider is disabled; nothing was written", 1, true), err)
    end)

    it("answers partial with the sliders already written when Lightroom rejects a later slider", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            rejectSet = { local_Contrast = "slider is disabled" },
        })

        local reply = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2, local_Contrast = 40 },
        })

        assert.truthy(reply.problem:find("Lightroom rejected local_Contrast 40: ", 1, true), reply.problem)
        assert.truthy(reply.problem:find("slider is disabled", 1, true), reply.problem)
        assert.are.same({ { slider = "local_Exposure", from = 0.5, to = 2 } }, reply.data.changed)
    end)

    it("answers unknown naming the written slider and leaves the mask selected meanwhile unchanged", function()
        local Handler, calls, _, valuesOf, photos = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            stealSelectionOnSet = "mask-b",
        })

        local reply = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.are.same({ local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 }, valuesOf[photos[1]]["mask-b"])
        assert.are.equal(1, #calls.setValue)
        assert.are.same({ { photo_id = "1", reason = "Another mask became selected while writing mask mask-a; written:"
            .. " local_Exposure; read the mask before retrying" } }, reply.unknown)
        assert.is_nil(reply.data.adjustments)
    end)

    it("refuses with nothing written when another mask became selected before the first write", function()
        local Handler, calls, _, valuesOf, photos, selectedMaskOf = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
        })
        local readSlider = package.loaded.MaskSelection.readSlider
        package.loaded.MaskSelection.readSlider = function(name)
            local value = readSlider(name)
            selectedMaskOf[photos[1]] = "mask-b"
            return value
        end

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })
        end)

        assert.are.equal("Another mask became selected before mask mask-a was written; nothing was written", err)
        assert.are.equal(0, #calls.setValue)
        assert.are.same({ local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 }, valuesOf[photos[1]]["mask-b"])
    end)

    it("answers unknown, not partial, when another mask became selected before the read-back", function()
        local Handler, _, _, valuesOf, photos, selectedMaskOf = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
        })
        local flush = package.loaded.DevelopSession.flushPendingEdits
        package.loaded.DevelopSession.flushPendingEdits = function(...)
            flush(...)
            selectedMaskOf[photos[1]] = "mask-b"
        end

        local reply = Handler.setMaskAdjustments({
            photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2, local_Contrast = 40 },
        })

        assert.is_nil(reply.problem)
        assert.are.same({ { photo_id = "1", reason = "Another mask became selected while writing mask mask-a; written:"
            .. " local_Exposure, local_Contrast; read the mask before retrying" } }, reply.unknown)
        assert.are.same({ local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 }, valuesOf[photos[1]]["mask-b"])
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, calls = setup({ photos = { { id = "1" } }, withoutMaskApi = true })

        local err = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Tint = 1 } })
        end)

        assert.truthy(err:find("^set_mask_adjustments needs LrDevelopController%.%a+, which this Lightroom does not offer %(Lightroom Classic 11 or later has it%)$"))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when setValue is missing", function()
        local Handler = setup({ photos = { { id = "1" } }, withoutSetValue = true })

        local refusal = helper.refusalOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Tint = 1 } })
        end)

        assert.are.equal("set_mask_adjustments needs LrDevelopController.setValue, which this Lightroom does not offer"
            .. " (Lightroom Classic 11 or later has it)", refusal)
    end)

    it("opens no catalog gate", function()
        local Handler, _, catalog = setup(everyPhotoAndMask(twoMasks()))

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 1 } })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)


describe("Local Color Grading and Glow sliders", function()
    local GRADING_SLIDERS = {
        "local_colorgradeShadowHue", "local_colorgradeShadowSat", "local_colorgradeShadowLum",
        "local_colorgradeMidtoneHue", "local_colorgradeMidtoneSat", "local_colorgradeMidtoneLum",
        "local_colorgradeHighlightHue", "local_colorgradeHighlightSat", "local_colorgradeHighlightLum",
        "local_colorgradeGlobalHue", "local_colorgradeGlobalSat", "local_colorgradeGlobalLum",
        "local_colorgradeBlending", "local_colorgradeBalance", "local_glow",
    }

    local function gradedMask()
        local values = {}
        for _, name in ipairs(GRADING_SLIDERS) do values[name] = 10 end
        return { photos = { { id = "1", masks = { ["mask-a"] = values }, selectedMask = "mask-a" } } }
    end

    it("reads the written values back with the other sliders of the selected mask", function()
        local Handler = setup(gradedMask())
        Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_colorgradeMidtoneHue = 35, local_glow = 25 },
        })

        local r = Handler.readSelected()

        assert.are.equal(35, r.adjustments.local_colorgradeMidtoneHue)
        assert.are.equal(25, r.adjustments.local_glow)
        assert.are.equal(10, r.adjustments.local_colorgradeShadowSat)
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
            assert.is_true(slider.tolerance > 0)
            assert.truthy(slider.stored:match("^Local%w+$"))
            assert.is_true(slider.scale > 0)
            assert.are.equal(slider, LocalSliders.byStored[slider.stored])
        end
    end)
end)

describe("a local slider added to the table", function()
    it("is settable and read back by set_mask_adjustments", function()
        helper.withFixtureSlider(function()
            local Handler = setup({ photos = { { id = "1", masks = { ["mask-a"] = { local_Fixture = 0 } }, selectedMask = "mask-a" } } })

            local r = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Fixture = 5 } }).data

            assert.are.equal(5, r.adjustments.local_Fixture)
        end)
    end)
end)
