local helper = require 'spec_helper'
helper.installImport({})
local ImageFrame = require 'ImageFrame'

local function near(expected, actual, tolerance)
    return math.abs(expected - actual) < (tolerance or 1e-12)
end

local SIZE = { width = 3000, height = 2000 }

local function frameOf(orientation, settings, dimensions)
    return ImageFrame.of({ orientation = orientation, dimensions = dimensions or SIZE, settings = settings or {} })
end

describe("ImageFrame orientation", function()
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
            local x, y = frameOf(orientation).toStored(DISPLAYED_X, DISPLAYED_Y)

            assert.is_true(near(expected[1], x))
            assert.is_true(near(expected[2], y))
        end)
    end

    local LIGHTROOM_AUTHORED = {
        CB = { start = { 0.3, 0.2 }, finish = { 0.45, 0.6 } },
        AD = { start = { 0.7, 0.8 }, finish = { 0.55, 0.4 } },
        BC = { start = { 0.3, 0.8 }, finish = { 0.45, 0.4 } },
    }

    for orientation, stored in pairs(LIGHTROOM_AUTHORED) do
        it("stores a displayed drag as the gradient Lightroom 16.0 authored for " .. orientation, function()
            local frame = frameOf(orientation)

            local startX, startY = frame.toStored(0.2, 0.3)
            local finishX, finishY = frame.toStored(0.6, 0.45)

            assert.is_true(near(stored.start[1], startX) and near(stored.start[2], startY))
            assert.is_true(near(stored.finish[1], finishX) and near(stored.finish[2], finishY))
        end)
    end

    it("swaps the stored pixel size only for orientations that swap the axes", function()
        for orientation, swaps in pairs({ AB = false, BA = false, CD = false, DC = false, CB = true, BC = true, AD = true, DA = true }) do
            local frame = frameOf(orientation)

            assert.are.same(swaps and { width = 2000, height = 3000 } or SIZE, frame.storedSize)
            assert.are.same(SIZE, frame.displayedSize)
        end
    end)

    it("refuses an orientation it does not know", function()
        for _, bad in ipairs({ "AC", "XY", "ABC", "", "ab", 6 }) do
            local refusal = helper.failedOf(function() frameOf(bad) end)
            assert.is_truthy(refusal:find("cannot map", 1, true))
            assert.is_nil(refusal:find("nothing was", 1, true))
        end
        assert.is_truthy(helper.failedOf(function() ImageFrame.of({ dimensions = SIZE }) end):find("cannot map", 1, true))
    end)

    it("refuses a photo whose pixel size Lightroom does not report", function()
        for _, dimensions in ipairs({ false, {}, { width = 0, height = 10 }, { width = 10 } }) do
            local message = helper.failedOf(function()
                ImageFrame.of({ orientation = "AB", dimensions = dimensions or nil })
            end)
            assert.is_truthy(message:find("pixel size", 1, true))
        end
    end)
end)

describe("ImageFrame crop and straighten", function()
    local SESSION_A_SIZE = { width = 1500, height = 1000 }
    local SESSION_A_CROP = { CropLeft = 0.15, CropTop = 0.1, CropRight = 0.92, CropBottom = 0.9 }

    local function sessionA(angle)
        local settings = { CropAngle = angle }
        for key, value in pairs(SESSION_A_CROP) do settings[key] = value end
        return frameOf("AB", settings, SESSION_A_SIZE)
    end

    local DISCS_AT_8 = {
        red = { displayed = { 0.6255, 0.3057 }, source = { 0.6503, 0.4005 } },
        blue = { displayed = { 0.2445, 0.892 }, source = { 0.3003, 0.7005 } },
        green = { displayed = { 0.9121, 0.9454 }, source = { 0.8503, 0.8505 } },
    }

    for colour, disc in pairs(DISCS_AT_8) do
        it("maps the " .. colour .. " disc Lightroom 16.0 displayed at an 8 degree crop to where it sits in the photo",
            function()
                local x, y = sessionA(8).toStored(disc.displayed[1], disc.displayed[2])

                assert.is_true(near(disc.source[1], x, 0.001) and near(disc.source[2], y, 0.001))
            end)
    end

    it("measures the displayed frame of the 8 degree crop as Lightroom renders it", function()
        local size = sessionA(8).displayedSize

        assert.is_true(near(1255 / 631, size.width / size.height, 0.002))
        assert.is_true(near(1255.2, size.width, 0.5) and near(631.4, size.height, 0.5))
    end)

    it("maps the red disc displayed without a crop angle through the crop rectangle alone", function()
        local x, y = sessionA(0).toStored(0.6498, 0.3756)

        assert.is_true(near(0.6503, x, 0.001) and near(0.4005, y, 0.001))
    end)

    it("crops an Orientation 8 photo in its stored frame, as the verified portrait crop mapping states", function()
        local frame = frameOf("DA", { CropLeft = 0.1, CropRight = 0.8, CropTop = 0.1, CropBottom = 0.7 })

        local topLeftX, topLeftY = frame.toStored(0, 0)
        local bottomRightX, bottomRightY = frame.toStored(1, 1)

        assert.is_true(near(0.8, topLeftX) and near(0.1, topLeftY))
        assert.is_true(near(0.1, bottomRightX) and near(0.7, bottomRightY))
    end)

    it("maps a point to the stored frame and back for every orientation with a crop angle", function()
        for _, orientation in ipairs({ "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }) do
            local frame = frameOf(orientation, { CropLeft = 0.2, CropTop = 0.1, CropRight = 0.9, CropBottom = 0.8, CropAngle = -12 })

            local x, y = frame.toDisplayed(frame.toStored(0.3, 0.6))

            assert.is_true(near(0.3, x, 1e-9) and near(0.6, y, 1e-9))
        end
    end)

    it("turns a displayed direction by the crop angle into the stored frame and back", function()
        local frame = sessionA(8)

        assert.is_true(near(38, frame.turnToStored(30), 1e-9))
        assert.is_true(near(30, frame.turnToDisplayed(38), 1e-9))
    end)

    it("scales a fraction of the displayed longer edge to the stored longer edge", function()
        local frame = frameOf("AB", { CropLeft = 0.25, CropRight = 0.75 })

        assert.is_true(near(0.1 * 2000 / 3000, frame.longEdgeToStored(0.1)))
    end)
end)

describe("ImageFrame warning for corrections it cannot invert", function()
    it("names every active Upright, Transform and manual distortion setting with the measured error", function()
        local frame = frameOf("AB", {
            PerspectiveUpright = 4, PerspectiveScale = 90, LensManualDistortionAmount = 60, PerspectiveRotate = 0,
        })

        assert.is_truthy(frame.warning:find("PerspectiveUpright 4", 1, true))
        assert.is_truthy(frame.warning:find("PerspectiveScale 90", 1, true))
        assert.is_truthy(frame.warning:find("LensManualDistortionAmount 60", 1, true))
        assert.is_falsy(frame.warning:find("PerspectiveRotate", 1, true))
        assert.is_truthy(frame.warning:find("0.05", 1, true))
    end)

    it("stays silent for a lens profile, a crop and neutral Transform values", function()
        local frame = frameOf("AB", {
            LensProfileEnable = 1, CropAngle = 8, PerspectiveUpright = 0, PerspectiveScale = 100, PerspectiveVertical = 0,
        })

        assert.is_nil(frame.warning)
    end)
end)

describe("ImageFrame.forPhoto", function()
    it("refuses a photo whose saved settings Lightroom does not return instead of taking it as uncropped", function()
        local catalog = { withReadAccessDo = function(_, fn) fn() end }
        local photo = {
            localIdentifier = 7,
            getRawMetadata = function(_, key) return ({ orientation = "AB", dimensions = SIZE })[key] end,
            getDevelopSettings = function() return nil end,
        }

        assert.has_error(function() ImageFrame.forPhoto(catalog, photo) end,
            "Lightroom returned no saved settings for photo 7")
    end)

    it("reads the orientation, pixel size and develop settings inside the read gate", function()
        local insideGate = false
        local readOutsideGate = false
        local catalog = {
            withReadAccessDo = function(_, fn)
                insideGate = true
                fn()
                insideGate = false
            end,
        }
        local photo = {
            getRawMetadata = function(_, key)
                readOutsideGate = readOutsideGate or not insideGate
                return ({ orientation = "BC", dimensions = SIZE })[key]
            end,
            getDevelopSettings = function()
                readOutsideGate = readOutsideGate or not insideGate
                return { CropLeft = 0.5 }
            end,
        }

        local frame = ImageFrame.forPhoto(catalog, photo)

        assert.is_false(readOutsideGate)
        local x = frame.toStored(0, 0)
        assert.is_true(near(0.5, x))
    end)
end)

describe("ImageFrame crop planning", function()
    local SESSION_A = { orientation = "AB", dimensions = { width = 1500, height = 1000 } }
    local ORIENTATIONS = { "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }

    local function sessionAFrameWidth(angle)
        local radians = math.rad(angle)
        return 1155 * math.cos(radians) + 800 * math.sin(radians), 800 * math.cos(radians) - 1155 * math.sin(radians)
    end

    it("plans the crop keys Session A wrote for the frame Lightroom 16.0 displayed at 8 degrees", function()
        local width, height = sessionAFrameWidth(8)

        local settings = ImageFrame.cropSettingsFor(SESSION_A, {
            center = { x = 0.535, y = 0.5 }, width = width, height = height, angle = 8,
        })

        assert.is_true(near(0.15, settings.CropLeft, 1e-9) and near(0.1, settings.CropTop, 1e-9))
        assert.is_true(near(0.92, settings.CropRight, 1e-9) and near(0.9, settings.CropBottom, 1e-9))
        assert.is_true(near(8, settings.CropAngle, 1e-9))
    end)

    it("plans an Orientation 8 crop as the photo skill's verified portrait mapping", function()
        local photo = { orientation = "DA", dimensions = SIZE }

        local settings = ImageFrame.cropSettingsFor(photo, ImageFrame.cropOfRectangle(photo,
            { left = 0.1, top = 0.2, right = 0.7, bottom = 0.9 }, 0))

        assert.is_true(near(1 - 0.9, settings.CropLeft) and near(1 - 0.2, settings.CropRight))
        assert.is_true(near(0.1, settings.CropTop) and near(0.7, settings.CropBottom))
        assert.is_true(near(0, settings.CropAngle))
    end)

    for _, orientation in ipairs(ORIENTATIONS) do
        it("plans keys that ImageFrame.of maps back to the requested frame, a consistency check of the two, for " .. orientation, function()
            local photo = { orientation = orientation, dimensions = SIZE }
            local crop = ImageFrame.cropOfRectangle(photo, { left = 0.25, top = 0.2, right = 0.7, bottom = 0.75 }, -6)

            local frame = ImageFrame.of({
                orientation = orientation, dimensions = SIZE, settings = ImageFrame.cropSettingsFor(photo, crop),
            })

            local uncropped = frameOf(orientation)
            local cornerX, cornerY = uncropped.toDisplayed(frame.toStored(0, 0))
            local radians = math.rad(-6)
            local expectedX = crop.center.x * 3000 - crop.width / 2 * math.cos(radians) + crop.height / 2 * math.sin(radians)
            local expectedY = crop.center.y * 2000 - crop.width / 2 * math.sin(radians) - crop.height / 2 * math.cos(radians)
            assert.is_true(near(crop.width, frame.displayedSize.width, 1e-6))
            assert.is_true(near(crop.height, frame.displayedSize.height, 1e-6))
            assert.is_true(near(expectedX, cornerX * 3000, 1e-6) and near(expectedY, cornerY * 2000, 1e-6))
        end)
    end

    it("finds the largest frame of an aspect ratio around a centre", function()
        local photo = { orientation = "AB", dimensions = SIZE }

        local crop = ImageFrame.largestCrop(photo, { width = 4, height = 5 }, { x = 0.5, y = 0.5 }, 0)
        local offCentre = ImageFrame.largestCrop(photo, { width = 1, height = 1 }, { x = 0.2, y = 0.5 }, 0)

        assert.is_true(near(1600, crop.width, 1e-9) and near(2000, crop.height, 1e-9))
        assert.is_true(near(1200, offCentre.width, 1e-9) and near(1200, offCentre.height, 1e-9))
        assert.are.same({ left = 0.5 - 800 / 3000, top = 0, right = 0.5 + 800 / 3000, bottom = 1 },
            ImageFrame.rectangleOf(photo, crop))
    end)

    it("fits the largest straightened frame inside the photo", function()
        local photo = { orientation = "AB", dimensions = SIZE }

        local crop = ImageFrame.largestCrop(photo, { width = 3, height = 2 }, { x = 0.5, y = 0.5 }, 5)

        assert.is_truthy(pcall(ImageFrame.cropSettingsFor, photo, crop))
        local radians = math.rad(5)
        local reachY = (crop.width * math.sin(radians) + crop.height * math.cos(radians)) / 2
        assert.is_true(near(1000, reachY, 1e-6))
    end)

    it("refuses a straightened frame that leaves the photo and names the largest one that fits", function()
        local photo = { orientation = "AB", dimensions = SIZE }
        local crop = ImageFrame.cropOfRectangle(photo, { left = 0, top = 0, right = 1, bottom = 1 }, 5)
        local largest = ImageFrame.rectangleOf(photo, ImageFrame.largestCrop(photo, { width = 3000, height = 2000 },
            { x = 0.5, y = 0.5 }, 5))

        local message = helper.failedOf(function() ImageFrame.cropSettingsFor(photo, crop) end)

        assert.is_truthy(message:find("corners would be empty", 1, true))
        assert.is_truthy(message:find(string.format("left %.4f, top %.4f", largest.left, largest.top), 1, true))
    end)
end)

describe("ImageFrame current crop", function()
    local function frameWidths(angle)
        local radians = math.rad(angle)
        return 1155 * math.cos(radians) + 800 * math.sin(radians), 800 * math.cos(radians) - 1155 * math.sin(radians)
    end

    it("reads Session A's stored keys as the frame Lightroom 16.0 displayed at 8 degrees", function()
        local crop = ImageFrame.currentCrop({
            orientation = "AB", dimensions = { width = 1500, height = 1000 },
            settings = { CropLeft = 0.15, CropTop = 0.1, CropRight = 0.92, CropBottom = 0.9, CropAngle = 8 },
        })

        local width, height = frameWidths(8)
        assert.is_true(near(0.535, crop.center.x, 1e-9) and near(0.5, crop.center.y, 1e-9))
        assert.is_true(near(width, crop.width, 1e-6) and near(height, crop.height, 1e-6))
        assert.is_true(near(8, crop.angle, 1e-9))
    end)

    it("reads an uncropped photo as the whole displayed frame", function()
        local crop = ImageFrame.currentCrop({ orientation = "BC", dimensions = SIZE, settings = {} })

        assert.are.same({ left = 0, top = 0, right = 1, bottom = 1 }, ImageFrame.rectangleOf({ dimensions = SIZE }, crop))
        assert.is_true(near(0, crop.angle))
    end)

    for _, orientation in ipairs({ "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }) do
        it("reads back the frame it planned for " .. orientation, function()
            local photo = { orientation = orientation, dimensions = SIZE }
            local planned = ImageFrame.cropOfRectangle(photo, { left = 0.2, top = 0.15, right = 0.75, bottom = 0.8 }, 7)

            local read = ImageFrame.currentCrop({
                orientation = orientation, dimensions = SIZE, settings = ImageFrame.cropSettingsFor(photo, planned),
            })

            local rectangle = ImageFrame.rectangleOf(photo, read)
            assert.is_true(near(0.2, rectangle.left, 1e-9) and near(0.15, rectangle.top, 1e-9))
            assert.is_true(near(0.75, rectangle.right, 1e-9) and near(0.8, rectangle.bottom, 1e-9))
            assert.is_true(near(7, read.angle, 1e-9))
        end)
    end

    it("places a frame stated inside the current crop in the photo, adding the angles", function()
        local photo = {
            orientation = "AB", dimensions = { width = 1500, height = 1000 },
            settings = { CropLeft = 0.15, CropTop = 0.1, CropRight = 0.92, CropBottom = 0.9, CropAngle = 8 },
        }
        local current = ImageFrame.currentCrop(photo)

        local placed = ImageFrame.withinCrop(photo, current, { center = { x = 0.5, y = 0.5 }, width = 400, height = 500, angle = 2 })
        local corner = ImageFrame.withinCrop(photo, current, { center = { x = 0, y = 0 }, width = 10, height = 10, angle = 0 })

        assert.is_true(near(0.535, placed.center.x, 1e-9) and near(0.5, placed.center.y, 1e-9))
        assert.is_true(near(400, placed.width) and near(500, placed.height) and near(10, placed.angle, 1e-9))
        assert.is_true(near(0.15, corner.center.x, 1e-9) and near(0.1, corner.center.y, 1e-9))
    end)
end)
