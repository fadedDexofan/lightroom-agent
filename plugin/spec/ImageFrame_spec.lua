local ImageFrame = require 'ImageFrame'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe("ImageFrame.fromOrientation", function()
    local ORIENTATIONS = { "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }
    local DISPLAYED_X, DISPLAYED_Y = 0.1, 0.3

    local STORED_BY_ORIENTATION = {
        AB = { 0.1, 0.3 },
        BA = { 0.9, 0.3 },
        CD = { 0.9, 0.7 },
        DC = { 0.1, 0.7 },
        BC = { 0.3, 0.9 },
        DA = { 0.7, 0.1 },
        AD = { 0.7, 0.9 },
        CB = { 0.3, 0.1 },
    }

    for orientation, expected in pairs(STORED_BY_ORIENTATION) do
        it("maps a displayed point into the stored frame as Lightroom does for " .. orientation, function()
            local frame = ImageFrame.fromOrientation(orientation)

            local x, y = frame.toStored(DISPLAYED_X, DISPLAYED_Y)

            assert.is_true(math.abs(x - expected[1]) < 1e-12)
            assert.is_true(math.abs(y - expected[2]) < 1e-12)
        end)
    end

    local LIGHTROOM_AUTHORED = {
        CB = { start = { 0.3, 0.2 }, finish = { 0.45, 0.6 } },
        AD = { start = { 0.7, 0.8 }, finish = { 0.55, 0.4 } },
        BC = { start = { 0.3, 0.8 }, finish = { 0.45, 0.4 } },
    }

    for orientation, stored in pairs(LIGHTROOM_AUTHORED) do
        it("stores a displayed drag as the gradient Lightroom 16.0 authored for " .. orientation, function()
            local frame = ImageFrame.fromOrientation(orientation)

            local startX, startY = frame.toStored(0.2, 0.3)
            local finishX, finishY = frame.toStored(0.6, 0.45)

            assert.is_true(math.abs(startX - stored.start[1]) < 1e-12 and math.abs(startY - stored.start[2]) < 1e-12)
            assert.is_true(math.abs(finishX - stored.finish[1]) < 1e-12 and math.abs(finishY - stored.finish[2]) < 1e-12)
        end)
    end

    it("keeps every corner of the displayed image inside the unit square", function()
        for _, orientation in ipairs(ORIENTATIONS) do
            local frame = ImageFrame.fromOrientation(orientation)
            for _, corner in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }) do
                local x, y = frame.toStored(corner[1], corner[2])
                assert.is_true(x == 0 or x == 1)
                assert.is_true(y == 0 or y == 1)
            end
        end
    end)

    it("flags only the normal orientation as normal", function()
        assert.is_true(ImageFrame.fromOrientation("AB").isNormal)
        assert.is_false(ImageFrame.fromOrientation("BC").isNormal)
        assert.is_false(ImageFrame.fromOrientation("BA").isNormal)
    end)

    it("refuses an orientation it does not know", function()
        for _, bad in ipairs({ "AC", "XY", "ABC", "", "ab" }) do
            local message = errorOf(function() ImageFrame.fromOrientation(bad) end)
            assert.is_truthy(message:find("cannot map", 1, true))
        end
        assert.is_truthy(errorOf(function() ImageFrame.fromOrientation(nil) end):find("cannot map", 1, true))
        assert.is_truthy(errorOf(function() ImageFrame.fromOrientation(6) end):find("cannot map", 1, true))
    end)
end)

describe("ImageFrame axis facts", function()
    local FACTS = {
        AB = { swapsAxes = false, reversesTurnDirection = false },
        BA = { swapsAxes = false, reversesTurnDirection = true },
        CD = { swapsAxes = false, reversesTurnDirection = false },
        DC = { swapsAxes = false, reversesTurnDirection = true },
        CB = { swapsAxes = true, reversesTurnDirection = true },
        BC = { swapsAxes = true, reversesTurnDirection = false },
        AD = { swapsAxes = true, reversesTurnDirection = true },
        DA = { swapsAxes = true, reversesTurnDirection = false },
    }

    for orientation, expected in pairs(FACTS) do
        it("reports whether " .. orientation .. " swaps the axes and reverses the turn direction", function()
            local frame = ImageFrame.fromOrientation(orientation)

            assert.are.equal(expected.swapsAxes, frame.swapsAxes)
            assert.are.equal(expected.reversesTurnDirection, frame.reversesTurnDirection)
        end)

        it("maps a point to the stored frame and back for " .. orientation, function()
            local frame = ImageFrame.fromOrientation(orientation)

            local storedX, storedY = frame.toStored(0.2, 0.7)
            local x, y = frame.toDisplayed(storedX, storedY)

            assert.is_true(math.abs(x - 0.2) < 1e-12)
            assert.is_true(math.abs(y - 0.7) < 1e-12)
        end)
    end
end)

describe("ImageFrame.forPhoto", function()
    it("reads the orientation inside the read gate", function()
        local insideGate = false
        local readInsideGate
        local catalog = {
            withReadAccessDo = function(_, fn)
                insideGate = true
                fn()
                insideGate = false
            end,
        }
        local photo = {
            getRawMetadata = function(_, key)
                readInsideGate = insideGate
                assert.are.equal("orientation", key)
                return "BC"
            end,
        }

        local frame = ImageFrame.forPhoto(catalog, photo)

        assert.is_true(readInsideGate)
        assert.are.equal("BC", frame.orientation)
    end)
end)
