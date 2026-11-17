local helper = require 'spec_helper'
local Store = require 'fake_mask_store'
local RadialEllipse = require 'radial_ellipse'

local linearComponent = Store.linearComponent
local radialComponent = Store.radialComponent
local correction = Store.correction

local function point(x, y) return { x = x, y = y } end

local function setup(opts)
    return Store.guardedHandler("HandlerGradientMasks", { "GradientGeometry" }, opts)
end

local function linearRequest(overrides)
    local args = { photo_id = "1", shape = "linear", start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function radialRequest(overrides)
    local args = {
        photo_id = "1", shape = "radial", center = point(0.5, 0.5), width = 0.4, height = 0.6,
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function existingGradients()
    return {
        correction("Sky", {
            linearComponent({ MaskID = "C1T1" }),
            radialComponent({ MaskID = "C1T2", Flipped = true, Angle = 0 }),
        }, { CorrectionID = "C1" }),
    }
end

describe("HandlerGradientMasks.createGradientMask", function()
    it("writes the requested adjustments into the new mask as Lightroom stores them, in the one guarded write", function()
        local previous = { correction("Existing", { Store.linearComponent({ MaskID = "C1T1" }) },
            { CorrectionID = "C1" }) }
        local Handler, stores = setup({ photos = { { id = "1", entries = previous } } })

        Handler.createGradientMask(radialRequest({ adjustments = { local_Exposure = 1, local_colorgradeMidtoneHue = 61.83 } }))

        local written = stores["1"].writes[1]
        assert.are.equal(0.25, written[#written].LocalExposure2012)
        assert.are.equal(62, written[#written].LocalColorGradeMidtoneHue)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("writes a value the schema accepts whatever range Lightroom reports for the slider", function()
        local Handler, stores = setup({ narrowRange = true })

        Handler.createGradientMask(radialRequest({ adjustments = { local_Exposure = 1 } }))

        assert.are.equal(0.25, stores["1"].entries[1].LocalExposure2012)
    end)

    it("commits an edit pending on the photo open in Develop before it writes the mask", function()
        local Handler, _, calls = setup({ startModule = "develop" })

        Handler.createGradientMask(linearRequest())

        assert.are.same({ { committed = true, writes = 0 }, { committed = true, writes = 1 } }, calls.stopTracking)
    end)

    it("commits nothing before the write when it has to open the photo itself", function()
        local Handler, _, calls = setup()

        Handler.createGradientMask(linearRequest())

        assert.are.same({ { committed = true, writes = 1 } }, calls.stopTracking)
    end)

    it("places a linear gradient as a new mask and returns its ids", function()
        local Handler, stores = setup()

        local result = Handler.createGradientMask(linearRequest({ name = "Sky" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Sky", written[1].CorrectionName)
        local component = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Gradient", component.What)
        assert.are.equal(0.2, component.FullY)
        assert.are.equal(0.6, component.ZeroY)
        assert.are.equal("1", result.photo_id)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal("linear", result.shape)
        assert.are.equal("add", result.mode)
        assert.is_true(result.new_mask)
        assert.are.same({ start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }, result.geometry)
    end)

    it("places a radial gradient outside the ellipse with rotation and feather", function()
        local Handler, stores = setup()

        local result = Handler.createGradientMask(radialRequest({ rotation = 30, feather = 10, area = "outside" }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_true(component.MaskInverted)
        assert.are.equal(30, component.Angle)
        assert.are.equal(10, component.Feather)
        assert.are.equal("radialGradient", Store.maskListOf(stores["1"].entries)[1].Tools[1].Type)
        assert.are.equal("outside", result.geometry.area)
        assert.are.equal(0.4, result.geometry.width)
    end)

    it("adds a component to an existing mask and keeps the other entries verbatim", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.createGradientMask(linearRequest({
            mask_id = "C1", mode = "subtract", start = point(0.1, 0.1), ["end"] = point(0.9, 0.9),
        }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal(3, #written[1].CorrectionMasks)
        assert.are.equal("C1T1", written[1].CorrectionMasks[1].MaskID)
        assert.are.equal(1, written[1].CorrectionMasks[3].MaskBlendMode)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T3", result.tool_id)
        assert.are.equal("subtract", result.mode)
        assert.is_false(result.new_mask)
    end)

    it("adds a second mask next to existing ones", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.createGradientMask(linearRequest())

        assert.are.equal(2, #stores["1"].writes[1])
        assert.are.equal("C2", result.mask_id)
    end)

    it("never queries or reads settings outside the gates", function()
        local Handler, stores, _, catalog = setup()

        Handler.createGradientMask(linearRequest())

        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, stores["1"].readsOutsideGate)
        assert.are.equal(0, stores["1"].writesOutsideGate)
    end)

    it("opens Develop for the cross-check and puts the module back", function()
        local Handler, _, calls = setup()

        Handler.createGradientMask(linearRequest())

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_true(calls.getAllMasks >= 1)
    end)

    it("accepts a numeric photo id and a file path and answers with the photo's own id", function()
        local Handler = setup({ photos = { { id = "7" } } })

        assert.are.equal("7", Handler.createGradientMask(linearRequest({ photo_id = 7 })).photo_id)
        assert.are.equal("7", Handler.createGradientMask(linearRequest({ photo_id = "/7.jpg" })).photo_id)
    end)

    it("rejects a degenerate linear gradient before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = helper.refusalOf(function()
            Handler.createGradientMask(linearRequest({ ["end"] = point(0.5, 0.2) }))
        end)

        assert.is_truthy(message:find("same point", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("answers an unknown photo with not_found before opening Develop", function()
        local Handler, _, calls = setup()

        assert.are.equal("404", helper.notFoundOf(function() Handler.createGradientMask(linearRequest({ photo_id = "404" })) end))
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown mask id without writing or opening Develop", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest({ mask_id = "C9" })) end)

        assert.is_truthy(message:find("Mask not found on this photo: C9", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses on an uncertified Lightroom, leaving the photo and the view alone", function()
        local Handler, stores, calls = setup({ maskWrites = { refuse = "Lightroom Classic 16.0 (16.0 [ 202611041403-7ac14c66 ]) is not certified for writing mask geometry (certified: none)." } })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("is not certified", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, stores, calls = setup({ withoutMaskApi = true })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("^create_gradient_mask needs LrDevelopController%.%a+, which this Lightroom does not offer %(Lightroom Classic 11 or later has it%)$"))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("restores the previous masks when Lightroom reads different geometry back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingGradients(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[2].CorrectionMasks[1].FullY = 0.99 end
                    return stored
                end,
            } },
        })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
        assert.are.equal("C1", stores["1"].entries[1].CorrectionID)
    end)

    it("restores the previous masks when Lightroom drops the component", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks = {} end
                    return stored
                end,
            } },
        })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("count changed from 1 to 0", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom's mask list does not show the new tool", function()
        local Handler, stores, calls = setup({ hideNewMasks = true })

        local message = helper.refusalOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("Lightroom's mask list has no gradient tool C1T1 in mask C1", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(0, #stores["1"].entries)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)
end)

describe("HandlerGradientMasks.updateGradientMask", function()
    it("moves a linear gradient and keeps its ids", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T1", ["end"] = point(0.9, 0.9),
        })

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        assert.are.equal("C1T1", component.MaskID)
        assert.are.equal(0.9, component.ZeroX)
        assert.are.equal(0.9, component.ZeroY)
        assert.are.equal(0.5, component.FullX)
        assert.are.equal(0.2, component.FullY)
        assert.is_nil(stores["1"].writes[1][1].CorrectionReferenceX)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.same(point(0.9, 0.9), result.geometry["end"])
        assert.are.same(point(0.5, 0.2), result.geometry.start)
    end)

    it("reshapes a radial gradient and leaves the other components alone", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T2", center = point(0.4, 0.5), width = 0.2, feather = 80, area = "outside",
        })

        local written = stores["1"].writes[1][1].CorrectionMasks
        assert.are.equal(0.5, written[1].ZeroX)
        local radial = written[2]
        assert.are.equal(80, radial.Feather)
        assert.are.equal(0, radial.Angle)
        assert.is_true(radial.MaskInverted)
        assert.are.equal(50, radial.Midpoint)
        assert.are.equal("radial", result.shape)
        assert.are.equal("outside", result.geometry.area)
        assert.are.equal(0.2, result.geometry.width)
        assert.is_true(math.abs(result.geometry.height - 0.6) < 1e-9)
        assert.is_true(math.abs(result.geometry.center.x - 0.4) < 1e-9)
    end)

    it("does not write the derived Flipped flag", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T2", feather = 5 })

        assert.is_nil(stores["1"].writes[1][1].CorrectionMasks[2].Flipped)
    end)

    it("changes only one field when only one is given", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T2", rotation = 45 })

        assert.are.equal(45, result.geometry.rotation)
        assert.are.equal(50, result.geometry.feather)
        assert.is_true(math.abs(result.geometry.width - 0.4) < 1e-5)
        assert.is_true(math.abs(result.geometry.height - 0.6) < 1e-5)
        assert.are.equal(45, stores["1"].writes[1][1].CorrectionMasks[2].Angle)
    end)

    it("stores a rotated radial in the pixel space of the photo and reports the requested size", function()
        local Handler, stores = setup({ photos = { { id = "1", dimensions = { width = 3000, height = 2000 } } } })

        local result = Handler.createGradientMask(radialRequest({
            center = point(0.5, 0.4), width = 0.2, height = 0.2, rotation = 45,
        }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        local reach = math.sqrt(0.5)
        assert.is_true(math.abs(component.Left - (0.5 - 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Right - (0.5 + 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Top - (0.4 - 0.25 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Bottom - (0.4 + 0.25 * reach)) < 1e-9)
        assert.are.equal(45, component.Angle)
        assert.is_true(math.abs(result.geometry.width - 0.2) < 1e-5)
        assert.is_true(math.abs(result.geometry.height - 0.2) < 1e-5)
    end)

    it("refuses a gradient when Lightroom reports no photo size, before anything is written", function()
        for _, request in ipairs({ radialRequest(), linearRequest() }) do
            local Handler, stores = setup({ photos = { { id = "1", noDimensions = true } } })

            local message = helper.refusalOf(function() Handler.createGradientMask(request) end)

            assert.is_truthy(message:find("pixel size", 1, true))
            assert.are.equal(0, #stores["1"].writes)
        end
    end)

    it("rejects a degenerate gradient without writing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local degenerate = helper.refusalOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", ["end"] = point(0.5, 0.2) })
        end)

        assert.is_truthy(degenerate:find("same point", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown tool id or a tool that is not a gradient", function()
        local entries = existingGradients()
        entries[1].CorrectionMasks[#entries[1].CorrectionMasks + 1] = {
            What = "Mask/Aggregate",
            MaskID = "C1T3",
            Masks = { { What = "Mask/Paint", Dabs = { "d 0.1 0.1" }, Radius = 0.1, Flow = 1, CenterWeight = 0 } },
        }
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

        local unknown = helper.refusalOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "NOPE", feather = 5 })
        end)
        local brush = helper.refusalOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T3", start = point(0, 0) })
        end)

        assert.is_truthy(unknown:find("Gradient tool not found on this photo: NOPE", 1, true))
        assert.is_truthy(brush:find("Mask/Aggregate mask, not a linear or radial gradient", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects a field of the other shape", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local message = helper.refusalOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", feather = 5 })
        end)

        assert.is_truthy(message:find("feather only applies to radial gradients", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("rolls back when Lightroom reads different geometry back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingGradients(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].ZeroY = 0.1 end
                    return stored
                end,
            } },
        })

        local message = helper.refusalOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", ["end"] = point(0.9, 0.9) })
        end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(0.6, stores["1"].entries[1].CorrectionMasks[1].ZeroY)
    end)

end)

local LINEAR_BY_ORIENTATION = {
    AB = { start = point(0.2, 0.1), finish = point(0.2, 0.6) },
    BA = { start = point(0.8, 0.1), finish = point(0.8, 0.6) },
    CD = { start = point(0.8, 0.9), finish = point(0.8, 0.4) },
    DC = { start = point(0.2, 0.9), finish = point(0.2, 0.4) },
    CB = { start = point(0.1, 0.2), finish = point(0.6, 0.2) },
    BC = { start = point(0.1, 0.8), finish = point(0.6, 0.8) },
    AD = { start = point(0.9, 0.8), finish = point(0.4, 0.8) },
    DA = { start = point(0.9, 0.2), finish = point(0.4, 0.2) },
}

local RADIAL_BY_ORIENTATION = {
    AB = { width = 0.3, height = 0.5, angle = 30 },
    BA = { width = 0.3, height = 0.5, angle = -30 },
    CD = { width = 0.3, height = 0.5, angle = 30 },
    DC = { width = 0.3, height = 0.5, angle = -30 },
    CB = { width = 0.5, height = 0.3, angle = -30 },
    BC = { width = 0.5, height = 0.3, angle = 30 },
    AD = { width = 0.5, height = 0.3, angle = -30 },
    DA = { width = 0.5, height = 0.3, angle = 30 },
}

local ORIENTATIONS = { "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }

local function near(expected, actual)
    return math.abs(expected - actual) < 1e-9
end

local function displayedVertical(overrides)
    return linearRequest(overrides or {
        start = point(0.2, 0.1), ["end"] = point(0.2, 0.6),
    })
end

describe("HandlerGradientMasks in the stored frame of a rotated photo", function()
    for _, orientation in ipairs(ORIENTATIONS) do
        local expected = LINEAR_BY_ORIENTATION[orientation]

        it("stores a displayed vertical linear gradient for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

            local result = Handler.createGradientMask(displayedVertical())

            local component = stores["1"].writes[1][1].CorrectionMasks[1]
            assert.is_true(near(expected.start.x, component.FullX))
            assert.is_true(near(expected.start.y, component.FullY))
            assert.is_true(near(expected.finish.x, component.ZeroX))
            assert.is_true(near(expected.finish.y, component.ZeroY))
            assert.are.same(point(0.2, 0.1), result.geometry.start)
            assert.are.same(point(0.2, 0.6), result.geometry["end"])
        end)

        it("moves one end of a linear gradient in the displayed frame for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
            local created = Handler.createGradientMask(displayedVertical())

            local result = Handler.updateGradientMask({
                photo_id = "1", tool_id = created.tool_id, ["end"] = point(0.2, 0.8),
            })

            assert.are.same(point(0.2, 0.1), result.geometry.start)
            assert.are.same(point(0.2, 0.8), result.geometry["end"])
            local component = stores["1"].writes[2][1].CorrectionMasks[1]
            assert.is_true(near(expected.start.x, component.FullX))
            assert.is_true(near(expected.start.y, component.FullY))
        end)

        local radial = RADIAL_BY_ORIENTATION[orientation]

        it("stores a displayed radial gradient with swapped sizes and mirrored rotation for " .. orientation,
            function()
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

                local result = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
                }))

                local component = stores["1"].writes[1][1].CorrectionMasks[1]
                local storedCenter = LINEAR_BY_ORIENTATION[orientation].start
                assert.are.equal(radial.angle, component.Angle)
                assert.is_true(near(storedCenter.x, (component.Left + component.Right) / 2))
                assert.is_true(near(storedCenter.y, (component.Top + component.Bottom) / 2))
                assert.is_true(near(0.2, result.geometry.center.x))
                assert.is_true(near(0.1, result.geometry.center.y))
                assert.is_true(math.abs(0.3 - result.geometry.width) < 1e-5)
                assert.is_true(math.abs(0.5 - result.geometry.height) < 1e-5)
                assert.are.equal(30, result.geometry.rotation)
            end)

        it("sizes an unrotated radial gradient along the stored axes for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

            Handler.createGradientMask(radialRequest({
                center = point(0.2, 0.1), width = 0.3, height = 0.5,
            }))

            local component = stores["1"].writes[1][1].CorrectionMasks[1]
            assert.is_true(near(radial.width, component.Right - component.Left))
            assert.is_true(near(radial.height, component.Bottom - component.Top))
            assert.are.equal(0, component.Angle)
        end)

        it("reshapes a radial gradient in the displayed frame for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
            local created = Handler.createGradientMask(radialRequest({
                center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
            }))

            local result = Handler.updateGradientMask({
                photo_id = "1", tool_id = created.tool_id, rotation = 45, feather = 20,
            })

            assert.are.equal(45, result.geometry.rotation)
            assert.are.equal(20, result.geometry.feather)
            assert.is_true(near(0.2, result.geometry.center.x))
            assert.is_true(near(0.1, result.geometry.center.y))
            assert.is_true(math.abs(0.3 - result.geometry.width) < 1e-5)
            assert.is_true(math.abs(0.5 - result.geometry.height) < 1e-5)
            local component = stores["1"].writes[2][1].CorrectionMasks[1]
            assert.are.equal(45, math.abs(component.Angle))
        end)
    end

    local function rotationSweep()
        local rotations = {}
        for rotation = -180, 180, 15 do rotations[#rotations + 1] = rotation end
        for _, rotation in ipairs({ -360, -61, -59, -46, 46, 59, 61, 91, 270, 360 }) do
            rotations[#rotations + 1] = rotation
        end
        return rotations
    end

    local DISPLAYED_ASPECT = 3000 / 2000

    local function requestedEllipse(rotation)
        return RadialEllipse.ofGeometry({
            center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = rotation,
        }, DISPLAYED_ASPECT)
    end

    local function expectedStoredEllipse(orientation, rotation)
        local radial = RADIAL_BY_ORIENTATION[orientation]
        local storedAspect = radial.width == 0.5 and 1 / DISPLAYED_ASPECT or DISPLAYED_ASPECT
        local center = LINEAR_BY_ORIENTATION[orientation].start
        return RadialEllipse.ofGeometry({
            center = center, width = radial.width, height = radial.height,
            rotation = (radial.angle > 0 and 1 or -1) * rotation,
        }, storedAspect)
    end

    local function storedEllipseOf(orientation, component)
        local radial = RADIAL_BY_ORIENTATION[orientation]
        local storedAspect = radial.width == 0.5 and 1 / DISPLAYED_ASPECT or DISPLAYED_ASPECT
        return RadialEllipse.ofComponent(component, storedAspect)
    end

    for _, orientation in ipairs(ORIENTATIONS) do
        it("creates the displayed radial ellipse at every rotation for " .. orientation, function()
            for _, rotation in ipairs(rotationSweep()) do
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

                local result = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = rotation,
                }))

                local component = stores["1"].writes[1][1].CorrectionMasks[1]
                assert.is_true(math.abs(component.Angle) <= 45, "angle " .. component.Angle .. " for " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    expectedStoredEllipse(orientation, rotation), storedEllipseOf(orientation, component)) < 1e-9,
                    "stored ellipse differs for rotation " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    requestedEllipse(rotation), RadialEllipse.ofGeometry(result.geometry, DISPLAYED_ASPECT)) < 1e-4,
                    "reported ellipse differs for rotation " .. rotation)
            end
        end)

        it("turns an existing radial to every rotation for " .. orientation, function()
            for _, rotation in ipairs(rotationSweep()) do
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
                local created = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5,
                }))

                local result = Handler.updateGradientMask({
                    photo_id = "1", tool_id = created.tool_id, rotation = rotation,
                })

                local component = stores["1"].writes[2][1].CorrectionMasks[1]
                assert.is_true(math.abs(component.Angle) <= 45, "angle " .. component.Angle .. " for " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    expectedStoredEllipse(orientation, rotation), storedEllipseOf(orientation, component)) < 1e-9,
                    "stored ellipse differs for rotation " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    requestedEllipse(rotation), RadialEllipse.ofGeometry(result.geometry, DISPLAYED_ASPECT)) < 1e-4,
                    "reported ellipse differs for rotation " .. rotation)
            end
        end)
    end

    it("reads an existing gradient from the stored frame back to the displayed one", function()
        local entries = {
            correction("Sky", {
                linearComponent({ MaskID = "C1T1", FullX = 0.1, FullY = 0.2, ZeroX = 0.6, ZeroY = 0.2 }),
            }, { CorrectionID = "C1" }),
        }
        local Handler = setup({ photos = { { id = "1", orientation = "CB", entries = entries } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T1", ["end"] = point(0.2, 0.9),
        })

        assert.are.same(point(0.2, 0.1), result.geometry.start)
        assert.are.same(point(0.2, 0.9), result.geometry["end"])
    end)

    it("leaves the stored values equal to the displayed ones when the photo is not rotated", function()
        local Handler, stores = setup()

        Handler.createGradientMask(radialRequest({
            center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
        }))
        Handler.createGradientMask(displayedVertical())

        local radial = stores["1"].writes[1][1].CorrectionMasks[1]
        local linear = stores["1"].writes[2][2].CorrectionMasks[1]
        assert.are.equal(30, radial.Angle)
        assert.are.equal(0.2, linear.FullX)
        assert.are.equal(0.1, linear.FullY)
        assert.are.equal(0.2, linear.ZeroX)
        assert.are.equal(0.6, linear.ZeroY)
    end)

    it("refuses a photo whose orientation it cannot map, writing nothing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", orientation = "ZZ" } } })

        local message = helper.refusalOf(function() Handler.createGradientMask(displayedVertical()) end)

        assert.is_truthy(message:find("cannot map", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)
end)

describe("gradients on a cropped and straightened photo", function()
    local SESSION_A_CROP = { CropLeft = 0.15, CropTop = 0.1, CropRight = 0.92, CropBottom = 0.9, CropAngle = 8 }

    local function croppedPhoto(extra)
        local settings = {}
        for key, value in pairs(SESSION_A_CROP) do settings[key] = value end
        for key, value in pairs(extra or {}) do settings[key] = value end
        return { id = "1", dimensions = { width = 1500, height = 1000 }, settings = settings }
    end

    it("stores a radial where Lightroom 16.0 rendered the disc seen at that displayed point", function()
        local Handler, stores = setup({ photos = { croppedPhoto() } })

        local result = Handler.createGradientMask(radialRequest({
            center = point(0.6255, 0.3057), width = 0.12, height = 0.12,
        }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        assert.is_true(math.abs((component.Left + component.Right) / 2 - 0.6503) < 0.001)
        assert.is_true(math.abs((component.Top + component.Bottom) / 2 - 0.4005) < 0.001)
        assert.is_true(math.abs(result.geometry.center.x - 0.6255) < 1e-5)
        assert.is_true(math.abs(result.geometry.center.y - 0.3057) < 1e-5)
    end)

    it("turns a displayed horizontal linear gradient by the crop angle in the stored frame", function()
        local Handler, stores = setup({ photos = { croppedPhoto() } })

        local result = Handler.createGradientMask(linearRequest({ start = point(0.381, 0.5), ["end"] = point(0.612, 0.5) }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        local degrees = math.deg(math.atan((component.ZeroY - component.FullY) * 1000,
            (component.ZeroX - component.FullX) * 1500))
        assert.is_true(math.abs(degrees - 8) < 0.01)
        assert.is_true(math.abs(result.geometry.start.y - 0.5) < 1e-5)
        assert.is_true(math.abs(result.geometry["end"].y - 0.5) < 1e-5)
    end)

    it("keeps the pixel size of a displayed radial and turns it by the crop angle", function()
        local Handler, stores = setup({ photos = { croppedPhoto() } })

        local result = Handler.createGradientMask(radialRequest({
            center = point(0.5, 0.5), width = 0.2, height = 0.1, rotation = 30,
        }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        local _, stored = require('GradientGeometry').geometryOf(component, 1.5)
        local displayedWidth = 1155 * math.cos(math.rad(8)) + 800 * math.sin(math.rad(8))
        local displayedHeight = -1155 * math.sin(math.rad(8)) + 800 * math.cos(math.rad(8))
        assert.is_true(math.abs(stored.rotation - 38) < 1e-4)
        assert.is_true(math.abs(stored.width * 1500 - 0.2 * displayedWidth) < 0.01)
        assert.is_true(math.abs(stored.height * 1000 - 0.1 * displayedHeight) < 0.01)
        assert.is_true(math.abs(result.geometry.rotation - 30) < 1e-4)
        assert.is_true(math.abs(result.geometry.width - 0.2) < 1e-5)
        assert.is_true(math.abs(result.geometry.height - 0.1) < 1e-5)
    end)

    for _, warp in ipairs({
        { key = "PerspectiveUpright", value = 4 },
        { key = "PerspectiveVertical", value = -30 },
        { key = "LensManualDistortionAmount", value = 60 },
    }) do
        it("writes and warns that " .. warp.key .. " moves the mask away from the preview position", function()
            local Handler, stores = setup({ photos = { croppedPhoto({ [warp.key] = warp.value }) } })
            local context = helper.requestContext()

            Handler.createGradientMask(radialRequest(), context)

            assert.are.equal(1, #stores["1"].writes)
            assert.are.equal(1, #context.warnings)
            assert.is_truthy(context.warnings[1]:find(warp.key, 1, true))
            assert.is_truthy(context.warnings[1]:find("0.05", 1, true))
        end)
    end

    it("does not warn for a lens profile alone or for Transform at its neutral values", function()
        local Handler = setup({ photos = { croppedPhoto({
            LensProfileEnable = 1, PerspectiveUpright = 0, PerspectiveScale = 100, PerspectiveVertical = 0,
        }) } })
        local context = helper.requestContext()

        Handler.createGradientMask(radialRequest(), context)

        assert.are.same({}, context.warnings)
    end)
end)
