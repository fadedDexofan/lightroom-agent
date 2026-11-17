local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local correction = Store.correction
local brushComponent = Store.brushComponent
local paint = Store.paint

local function point(x, y) return { x = x, y = y } end

local function setup(opts)
    return Store.guardedHandler("HandlerBrushMasks", { "BrushStrokes", "ImageFrame" }, opts)
end

local function stroke(overrides)
    local value = { points = { point(0.2, 0.3), point(0.3, 0.3) } }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function createRequest(overrides)
    local args = { photo_id = "1", strokes = { stroke() } }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function existingBrush()
    return {
        correction("Face", {
            brushComponent({ MaskID = "C1T1" }, { paint(), paint({ Radius = 0.05 }) }),
            Store.linearComponent({ MaskID = "C1T2" }),
        }, { CorrectionID = "C1" }),
    }
end

describe("HandlerBrushMasks.createBrushMask", function()
    it("writes the requested adjustments into the new mask as Lightroom stores them, in the one guarded write", function()
        local previous = { correction("Existing", { Store.linearComponent({ MaskID = "C1T1" }) },
            { CorrectionID = "C1" }) }
        local Handler, stores = setup({ photos = { { id = "1", entries = previous } } })

        Handler.createBrushMask(createRequest({ adjustments = { local_Exposure = 1, local_colorgradeMidtoneHue = 61.83 } }))

        local written = stores["1"].writes[1]
        assert.are.equal(0.25, written[#written].LocalExposure2012)
        assert.are.equal(62, written[#written].LocalColorGradeMidtoneHue)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("paints a new brush mask and returns its ids", function()
        local Handler, stores = setup()

        local result = Handler.createBrushMask(createRequest({
            name = "Face", strokes = { stroke({ radius = 0.05 }), stroke({ points = { point(0.7, 0.8) } }) },
        }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Face", written[1].CorrectionName)
        local aggregate = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Aggregate", aggregate.What)
        assert.are.equal(2, #aggregate.Masks)
        assert.are.equal(0.05, aggregate.Masks[1].Radius)
        assert.are.same({ "d 0.700000 0.800000" }, aggregate.Masks[2].Dabs)
        assert.are.equal("1", result.photo_id)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal(2, result.strokes_added)
        assert.are.equal(2, result.stroke_count)
        assert.is_true(result.new_mask)
    end)

    it("maps displayed points into the stored frame of a rotated photo", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "BC" } } })

        Handler.createBrushMask(createRequest({
            strokes = { stroke({ points = { point(0.25, 0.75) }, radius = 0.05 }) },
        }))

        local dabs = stores["1"].writes[1][1].CorrectionMasks[1].Masks[1].Dabs
        assert.are.same({ "d 0.750000 0.750000" }, dabs)
    end)

    it("maps a displayed path into the stored frame when it is appended to a brush", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "CD", entries = existingBrush() } } })

        Handler.addBrushStrokes({
            photo_id = "1", tool_id = "C1T1", strokes = { stroke({ points = { point(0.25, 0.75) } }) },
        })

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.same({ "d 0.750000 0.250000" }, masks[#masks].Dabs)
    end)

    it("refuses a photo whose orientation it cannot map, writing nothing", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "ZZ" } } })

        local message = helper.failedOf(function() Handler.createBrushMask(createRequest()) end)

        assert.matches("cannot map", message, 1, true)
        assert.are.equal(0, stores["1"].attempts)
    end)

    it("writes a low-flow stroke with the flow token and verifies it when Lightroom reads it back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored)
                    local lightroomPaint = stored[1].CorrectionMasks[1].Masks[1]
                    lightroomPaint.Flow = 0.299998
                    return stored
                end,
            } },
        })

        Handler.createBrushMask(createRequest({ strokes = { stroke({ flow = 0.3 }) } }))

        local written = stores["1"].writes[1][1].CorrectionMasks[1].Masks[1]
        assert.are.equal(0.3, written.Flow)
        assert.are.equal("f 0.3000", written.Dabs[1])
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("adds a brush component to an existing mask and keeps the other entries verbatim", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local result = Handler.createBrushMask(createRequest({ mask_id = "C1" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal(3, #written[1].CorrectionMasks)
        assert.are.equal("C1T1", written[1].CorrectionMasks[1].MaskID)
        assert.are.equal(2, #written[1].CorrectionMasks[1].Masks)
        assert.are.equal("Mask/Aggregate", written[1].CorrectionMasks[3].What)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T3", result.tool_id)
        assert.is_false(result.new_mask)
    end)

    it("never queries or reads settings outside the gates", function()
        local Handler, stores, _, catalog = setup()

        Handler.createBrushMask(createRequest())

        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, stores["1"].readsOutsideGate)
        assert.are.equal(0, stores["1"].writesOutsideGate)
    end)

    it("writes without opening Develop or reading its mask list", function()
        local Handler, _, calls = setup()

        Handler.createBrushMask(createRequest())

        assert.are.same({}, calls.modules)
        assert.are.equal(0, calls.getAllMasks)
    end)

    it("accepts a numeric photo id", function()
        local Handler = setup({ photos = { { id = "7" } } })

        assert.are.equal("7", Handler.createBrushMask(createRequest({ photo_id = 7 })).photo_id)
    end)

    it("rejects a path that needs too many dabs in the stored frame before writing", function()
        local Handler, stores = setup()

        local message = helper.failedOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ points = { point(0, 0), point(1, 1) }, radius = 0.0001 }) } }))
        end)

        assert.is_truthy(message:find("dabs along its path", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("writes feather, density and erase strokes and verifies them when Lightroom reads them back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored)
                    for _, lightroomPaint in ipairs(stored[1].CorrectionMasks[1].Masks) do
                        lightroomPaint.CenterWeight = lightroomPaint.CenterWeight + 0.0000004
                        lightroomPaint.Radius = lightroomPaint.Radius - 0.0000004
                    end
                    return stored
                end,
            } },
        })

        Handler.createBrushMask(createRequest({
            strokes = {
                stroke({ radius = 0.411904, feather = 50, density = 0.3, points = { point(0.5, 0.5) } }),
                stroke({ erase = true, feather = 0, points = { point(0.5, 0.5) } }),
            },
        }))

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.equal(0.3, masks[1].MaskValue)
        assert.is_true(math.abs(masks[1].CenterWeight - 0.16214) < 1e-5)
        assert.are.equal("h 0.1621", masks[1].Dabs[1])
        assert.are.equal(0, masks[2].MaskValue)
        assert.are.equal(1, masks[2].CenterWeight)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("rolls back when Lightroom keeps a different density", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].MaskValue = 1 end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ density = 0.3 }) } }))
        end)

        assert.is_truthy(message:find("MaskValue: wrote 0.3, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("rolls back when Lightroom turns an erase stroke into an add stroke", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].MaskValue = 1 end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ erase = true }) } }))
        end)

        assert.is_truthy(message:find("MaskValue: wrote 0, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("answers an unknown photo with not_found", function()
        local Handler = setup()

        assert.are.equal("404", helper.notFoundOf(function() Handler.createBrushMask(createRequest({ photo_id = "404" })) end))
    end)

    it("fails for an unknown mask id without writing", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local message = helper.failedOf(function() Handler.createBrushMask(createRequest({ mask_id = "C9" })) end)

        assert.is_truthy(message:find("Mask not found on this photo: C9", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("refuses on an uncertified Lightroom, leaving the photo and the view alone", function()
        local Handler, stores = setup({ maskWrites = { refuse = "Lightroom Classic 16.0 (16.0 [ 202611041403-7ac14c66 ]) is not certified for writing mask geometry (certified: none)." } })

        local message = helper.failedOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("is not certified", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("restores the previous masks when Lightroom reads different dabs back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingBrush(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[2].CorrectionMasks[1].Masks[1].Dabs[1] = "d 0.900000 0.900000" end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.is_truthy(message:find("dab 1 changed", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom drops a stroke", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks = {} end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke(), stroke() } }))
        end)

        assert.is_truthy(message:find("count changed from 2 to 0", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom ignores the flow", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].Flow = 1 end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ flow = 0.3 }) } }))
        end)

        assert.is_truthy(message:find("Flow: wrote 0.3, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

end)

describe("HandlerBrushMasks.addBrushStrokes", function()
    local function addRequest(overrides)
        local args = { photo_id = "1", tool_id = "C1T1", strokes = { stroke({ points = { point(0.6, 0.6) } }) } }
        for key, value in pairs(overrides or {}) do args[key] = value end
        return args
    end

    it("appends strokes to the brush and keeps its ids and earlier strokes", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local result = Handler.addBrushStrokes(addRequest({ strokes = { stroke(), stroke({ flow = 0.5 }) } }))

        local written = stores["1"].writes[1][1].CorrectionMasks
        assert.are.equal("C1T1", written[1].MaskID)
        assert.are.equal(4, #written[1].Masks)
        assert.are.equal(0.05, written[1].Masks[2].Radius)
        assert.are.equal("f 0.5000", written[1].Masks[4].Dabs[1])
        assert.are.equal("C1T2", written[2].MaskID)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal(2, result.strokes_added)
        assert.are.equal(4, result.stroke_count)
        assert.is_nil(result.new_mask)
    end)

    it("rejects a path that needs too many dabs in the stored frame before writing", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local message = helper.failedOf(function()
            Handler.addBrushStrokes(addRequest({ strokes = { stroke({ points = { point(0, 0), point(1, 1) }, radius = 0.0001 }) } }))
        end)

        assert.is_truthy(message:find("dabs along its path", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("fails for an unknown tool id or a tool that is not a brush, writing nothing", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local unknown = helper.failedOf(function() Handler.addBrushStrokes(addRequest({ tool_id = "NOPE" })) end)
        local gradient = helper.failedOf(function() Handler.addBrushStrokes(addRequest({ tool_id = "C1T2" })) end)

        assert.is_truthy(unknown:find("Brush tool not found on this photo: NOPE", 1, true))
        assert.is_truthy(gradient:find("Mask/Gradient mask, not a brush", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("appends an erase stroke with feather after the strokes it erases", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        Handler.addBrushStrokes(addRequest({ strokes = { stroke({ erase = true, feather = 0, radius = 0.1 }) } }))

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.equal(3, #masks)
        assert.are.equal(1, masks[2].MaskValue)
        assert.are.equal(0, masks[3].MaskValue)
        assert.are.equal(1, masks[3].CenterWeight)
    end)

    it("rolls back when Lightroom reads fewer strokes back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingBrush(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then table.remove(stored[1].CorrectionMasks[1].Masks) end
                    return stored
                end,
            } },
        })

        local message = helper.failedOf(function() Handler.addBrushStrokes(addRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(2, #stores["1"].entries[1].CorrectionMasks[1].Masks)
    end)

end)

describe("brush strokes on a cropped photo", function()
    local CROP = { CropLeft = 0.25, CropTop = 0, CropRight = 0.75, CropBottom = 1, CropAngle = 0 }

    it("maps displayed points into the stored frame and the radius to the stored longer edge", function()
        local Uncropped, uncroppedStores = setup()
        Uncropped.createBrushMask(createRequest({ strokes = { stroke({ points = { point(0.2, 0.5) }, radius = 0.06 }) } }))
        local Handler, stores = setup({ photos = { { id = "1", settings = CROP } } })

        Handler.createBrushMask(createRequest({ strokes = { stroke({ points = { point(0.2, 0.5) }, radius = 0.06 }) } }))

        local painted = stores["1"].writes[1][1].CorrectionMasks[1].Masks[1]
        local reference = uncroppedStores["1"].writes[1][1].CorrectionMasks[1].Masks[1]
        assert.are.same({ "d 0.350000 0.500000" }, painted.Dabs)
        assert.is_true(math.abs(painted.Radius - reference.Radius * 2000 / 3000) < 1e-6)
    end)

    it("paints and warns when Upright is active", function()
        local settings = { PerspectiveUpright = 2 }
        for key, value in pairs(CROP) do settings[key] = value end
        local Handler, stores = setup({ photos = { { id = "1", settings = settings } } })
        local context = helper.requestContext()

        Handler.createBrushMask(createRequest(), context)

        assert.are.equal(1, #stores["1"].writes)
        assert.are.equal(1, #context.warnings)
        assert.is_truthy(context.warnings[1]:find("PerspectiveUpright", 1, true))
    end)
end)
