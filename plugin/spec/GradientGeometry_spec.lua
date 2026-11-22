local helper = require "spec_helper"
local RadialEllipse = require "radial_ellipse"

local GradientGeometry

local function point(x, y) return { x = x, y = y } end

local function linearArgs(overrides)
    local args = { shape = "linear", start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }
    for key, value in pairs(overrides or {}) do
        args[key] = value
    end
    return args
end

local function radialArgs(overrides)
    local args = { shape = "radial", center = point(0.5, 0.5), width = 0.4, height = 0.6 }
    for key, value in pairs(overrides or {}) do
        args[key] = value
    end
    return args
end

describe("GradientGeometry.parseCreate", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require "GradientGeometry"
    end)

    it("parses a linear gradient into start and end", function()
        local request = GradientGeometry.parseCreate(linearArgs())

        assert.are.equal("linear", request.shape)
        assert.are.same({ start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }, request.geometry)
        assert.are.equal("add", request.mode)
        assert.is_nil(request.maskId)
    end)

    it("fills radial defaults", function()
        local request = GradientGeometry.parseCreate(radialArgs())

        assert.are.equal(0, request.geometry.rotation)
        assert.are.equal(50, request.geometry.feather)
        assert.are.equal("inside", request.geometry.area)
    end)

    it("keeps explicit radial rotation, feather and area", function()
        local request = GradientGeometry.parseCreate(radialArgs({ rotation = -45, feather = 0, area = "outside" }))

        assert.are.equal(-45, request.geometry.rotation)
        assert.are.equal(0, request.geometry.feather)
        assert.are.equal("outside", request.geometry.area)
    end)

    it("rejects identical start and end", function()
        local message = helper.failedOf(
            function() GradientGeometry.parseCreate(linearArgs({ start = point(0.3, 0.3), ["end"] = point(0.3, 0.3) })) end
        )

        assert.is_truthy(message:find("same point", 1, true), message)
    end)
end)

describe("GradientGeometry.parseUpdate", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require "GradientGeometry"
    end)

    it("collects only the fields that were given", function()
        local request = GradientGeometry.parseUpdate({ tool_id = "T1", center = point(0.4, 0.4), feather = 80 })

        assert.are.equal("T1", request.toolId)
        assert.are.same({ center = point(0.4, 0.4), feather = 80 }, request.changes)
    end)
end)

describe("GradientGeometry stored form", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require "GradientGeometry"
    end)

    it("stores a linear gradient with the full effect at start and none at end", function()
        local component =
            GradientGeometry.newComponent("linear", GradientGeometry.parseCreate(linearArgs()).geometry, "add")

        assert.are.equal("Mask/Gradient", component.What)
        assert.are.equal(0.5, component.FullX)
        assert.are.equal(0.2, component.FullY)
        assert.are.equal(0.5, component.ZeroX)
        assert.are.equal(0.6, component.ZeroY)
        assert.are.equal(0, component.MaskBlendMode)
        assert.is_false(component.MaskInverted)
    end)

    it("stores a radial gradient as a box around the center", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({
            center = point(0.5, 0.4),
            rotation = 0,
            feather = 20,
            area = "outside",
        })).geometry

        local component = GradientGeometry.newComponent("radial", geometry, "add", 1.5)

        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_true(math.abs(component.Left - 0.3) < 1e-9)
        assert.is_true(math.abs(component.Right - 0.7) < 1e-9)
        assert.is_true(math.abs(component.Top - 0.1) < 1e-9)
        assert.is_true(math.abs(component.Bottom - 0.7) < 1e-9)
        assert.are.equal(0, component.Angle)
        assert.are.equal(20, component.Feather)
        assert.are.equal(50, component.Midpoint)
        assert.are.equal(0, component.Roundness)
        assert.are.equal(2, component.Version)
        assert.is_true(component.MaskInverted)
        assert.is_nil(component.Flipped)
    end)

    it("stores the half extents of a rotated radial as the rotated semi axes, as Lightroom reads them", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({
            center = point(0.5, 0.4),
            width = 0.4,
            height = 0.6,
            rotation = 45,
        })).geometry

        local component = GradientGeometry.newComponent("radial", geometry, "add", 1)

        local reach = math.sqrt(0.5)
        assert.is_true(math.abs(component.Left - (0.5 + 0.1 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Right - (0.5 - 0.1 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Top - (0.4 - 0.5 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Bottom - (0.4 + 0.5 * reach)) < 1e-9)
        assert.are.equal(45, component.Angle)
    end)

    it("scales a rotated radial by the photo aspect ratio so it is an ellipse in pixels", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({
            center = point(0.5, 0.4),
            width = 0.2,
            height = 0.2,
            rotation = 45,
        })).geometry

        local component = GradientGeometry.newComponent("radial", geometry, "add", 1.5)

        local reach = math.sqrt(0.5)
        assert.is_true(math.abs(component.Left - (0.5 - 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Right - (0.5 + 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Top - (0.4 - 0.25 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Bottom - (0.4 + 0.25 * reach)) < 1e-9)
    end)

    it("marks a subtract component with blend mode 1", function()
        local geometry = GradientGeometry.parseCreate(linearArgs()).geometry

        local component = GradientGeometry.newComponent("linear", geometry, "subtract")

        assert.are.equal(1, component.MaskBlendMode)
        assert.are.equal(0, component.MaskValue)
    end)

    it("reads geometry back from a stored component", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({ rotation = 15, area = "outside" })).geometry
        local component = GradientGeometry.newComponent("radial", geometry, "add", 1.5)

        local shape, read = GradientGeometry.geometryOf(component, 1.5)

        assert.are.equal("radial", shape)
        assert.are.same(geometry, read)
    end)

    it(
        "reports no shape for other mask types",
        function() assert.is_nil(GradientGeometry.geometryOf({ What = "Mask/Aggregate" }, 1.5)) end
    )

    it("merges changes over the current geometry and re-checks it", function()
        local current = GradientGeometry.parseCreate(linearArgs()).geometry

        local merged = GradientGeometry.mergeChanges("linear", current, { ["end"] = point(0.9, 0.9) })

        assert.are.same(point(0.5, 0.2), merged.start)
        assert.are.same(point(0.9, 0.9), merged["end"])
        assert.are.same(point(0.5, 0.6), current["end"])
        assert.is_truthy(
            helper
                .failedOf(function() GradientGeometry.mergeChanges("linear", current, { ["end"] = point(0.5, 0.2) }) end)
                :find("same point", 1, true)
        )
    end)

    it("refuses a field of the other shape when merging", function()
        local current = GradientGeometry.parseCreate(linearArgs()).geometry

        local message = helper.failedOf(
            function() GradientGeometry.mergeChanges("linear", current, { feather = 5 }) end
        )

        assert.is_truthy(message:find("feather only applies to radial gradients, but this tool is a linear", 1, true))
    end)

    it("clears the derived Flipped flag when it rewrites a radial component", function()
        local component = { What = "Mask/CircularGradient", Flipped = true, MaskInverted = false }
        local geometry = GradientGeometry.parseCreate(radialArgs({ area = "outside" })).geometry

        GradientGeometry.applyGeometry("radial", component, geometry, 1.5)

        assert.is_nil(component.Flipped)
        assert.is_true(component.MaskInverted)
    end)
end)

local LIGHTROOM_AUTHORED_UPRIGHT = {
    center = point(0.4168865, 0.445748),
    width = 0.263853,
    height = 0.234604,
    feather = 0,
    area = "inside",
}

local LIGHTROOM_AUTHORED = {
    {
        label = "dragged to 60 degrees clockwise",
        rotation = 60.1617,
        stored = { Left = 0.290194, Right = 0.543579, Top = 0.313328, Bottom = 0.578168, Angle = -29.8383 },
    },
    {
        label = "dragged to 120 degrees clockwise",
        rotation = 120.1391,
        stored = { Left = 0.422288, Right = 0.411485, Top = 0.19667, Bottom = 0.694826, Angle = 30.1391 },
    },
    {
        label = "dragged to 60 degrees counterclockwise",
        rotation = -60.1616,
        stored = { Left = 0.421504, Right = 0.412269, Top = 0.196626, Bottom = 0.69487, Angle = 29.8384 },
    },
}

local PHOTO_ASPECT = 1000 / 600

local function turnedBy(rotation, overrides)
    local geometry = {}
    for key, value in pairs(LIGHTROOM_AUTHORED_UPRIGHT) do
        geometry[key] = value
    end
    geometry.rotation = rotation
    for key, value in pairs(overrides or {}) do
        geometry[key] = value
    end
    return geometry
end

local function rotationSweep()
    local rotations = {}
    for rotation = -360, 360, 7.5 do
        rotations[#rotations + 1] = rotation
    end
    for _, rotation in ipairs({ -91, -90, -89, -61, -59, -46, -45.5, -45, 45, 45.5, 46, 59, 61, 89, 90, 91, 135 }) do
        rotations[#rotations + 1] = rotation
    end
    return rotations
end

local SHAPES_BY_ASPECT = {
    { label = "wider than tall", width = 0.5, height = 0.25 },
    { label = "taller than wide", width = 0.2, height = 0.6 },
    { label = "round in the image", width = 0.3, height = 0.5 },
}

describe("GradientGeometry radial rotation", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require "GradientGeometry"
    end)

    for _, aspect in ipairs({ PHOTO_ASPECT, 1, 1 / PHOTO_ASPECT }) do
        for _, shape in ipairs(SHAPES_BY_ASPECT) do
            it(
                string.format(
                    "stores the requested ellipse within 45 degrees for a %s radial at aspect %.3f",
                    shape.label,
                    aspect
                ),
                function()
                    for _, rotation in ipairs(rotationSweep()) do
                        local geometry = turnedBy(rotation, { width = shape.width, height = shape.height })

                        local component = GradientGeometry.newComponent("radial", geometry, "add", aspect)

                        assert.is_true(
                            math.abs(component.Angle) <= 45,
                            "angle " .. component.Angle .. " for " .. rotation
                        )
                        local difference = RadialEllipse.differenceBetween(
                            RadialEllipse.ofGeometry(geometry, aspect),
                            RadialEllipse.ofComponent(component, aspect)
                        )
                        assert.is_true(difference < 1e-9, "ellipse differs for rotation " .. rotation)
                    end
                end
            )

            it(
                string.format(
                    "reads back the requested ellipse within 45 degrees for a %s radial at aspect %.3f",
                    shape.label,
                    aspect
                ),
                function()
                    for _, rotation in ipairs(rotationSweep()) do
                        local geometry = turnedBy(rotation, { width = shape.width, height = shape.height })
                        local component = GradientGeometry.newComponent("radial", geometry, "add", aspect)

                        local _, read = GradientGeometry.geometryOf(component, aspect)

                        assert.is_true(
                            math.abs(read.rotation) <= 45,
                            "rotation " .. read.rotation .. " for " .. rotation
                        )
                        local difference = RadialEllipse.differenceBetween(
                            RadialEllipse.ofGeometry(geometry, aspect),
                            RadialEllipse.ofGeometry(read, aspect)
                        )
                        assert.is_true(difference < 1e-4, "read back differs for rotation " .. rotation)
                    end
                end
            )
        end
    end

    it("keeps the requested size, rotation and box unchanged up to 45 degrees either way", function()
        for _, rotation in ipairs({ -45, -30, -7.5, 0, 12, 30, 45 }) do
            local geometry = turnedBy(rotation, { width = 0.5, height = 0.25 })

            local component = GradientGeometry.newComponent("radial", geometry, "add", PHOTO_ASPECT)
            local _, read = GradientGeometry.geometryOf(component, PHOTO_ASPECT)

            assert.are.equal(rotation, component.Angle)
            assert.are.equal(rotation, read.rotation)
            assert.is_true(math.abs(read.width - 0.5) < 1e-5)
            assert.is_true(math.abs(read.height - 0.25) < 1e-5)
        end
    end)

    it("stores a turn past 45 degrees as the same ellipse with width and height swapped", function()
        local geometry = turnedBy(61, { width = 0.5, height = 0.25 })

        local component = GradientGeometry.newComponent("radial", geometry, "add", PHOTO_ASPECT)
        local _, read = GradientGeometry.geometryOf(component, PHOTO_ASPECT)

        assert.is_true(math.abs(component.Angle - -29) < 1e-9)
        assert.is_true(math.abs(read.rotation - -29) < 1e-5)
        assert.is_true(math.abs(read.width - 0.25 / PHOTO_ASPECT) < 1e-5)
        assert.is_true(math.abs(read.height - 0.5 * PHOTO_ASPECT) < 1e-5)
    end)

    it("stores a quarter turn as an unrotated ellipse with width and height swapped", function()
        local geometry = turnedBy(90, { width = 0.5, height = 0.25 })

        local component = GradientGeometry.newComponent("radial", geometry, "add", PHOTO_ASPECT)

        assert.are.equal(0, component.Angle)
        assert.is_true(math.abs((component.Right - component.Left) - 0.25 / PHOTO_ASPECT) < 1e-9)
        assert.is_true(math.abs((component.Bottom - component.Top) - 0.5 * PHOTO_ASPECT) < 1e-9)
    end)

    it("treats a half turn and a full turn like no turn", function()
        for _, rotation in ipairs({ -360, -180, 180, 360 }) do
            local component = GradientGeometry.newComponent("radial", turnedBy(rotation), "add", PHOTO_ASPECT)

            assert.are.equal(0, component.Angle)
            assert.is_true(math.abs((component.Right - component.Left) - 0.263853) < 1e-9)
            assert.is_true(math.abs((component.Bottom - component.Top) - 0.234604) < 1e-9)
        end
    end)

    for _, authored in ipairs(LIGHTROOM_AUTHORED) do
        it("writes the box Lightroom stored for a gradient " .. authored.label, function()
            local component = GradientGeometry.newComponent("radial", turnedBy(authored.rotation), "add", PHOTO_ASPECT)

            for key, value in pairs(authored.stored) do
                assert.is_true(math.abs(component[key] - value) < 2e-4, key .. " " .. component[key] .. " vs " .. value)
            end
        end)

        it("reads the gradient Lightroom stored for a gradient " .. authored.label, function()
            local component = { What = "Mask/CircularGradient", Feather = 0, MaskInverted = false }
            for key, value in pairs(authored.stored) do
                component[key] = value
            end

            local _, read = GradientGeometry.geometryOf(component, PHOTO_ASPECT)

            assert.is_true(math.abs(read.rotation - authored.stored.Angle) < 1e-5)
            local difference = RadialEllipse.differenceBetween(
                RadialEllipse.ofGeometry(turnedBy(authored.rotation), PHOTO_ASPECT),
                RadialEllipse.ofGeometry(read, PHOTO_ASPECT)
            )
            assert.is_true(difference < 1e-3, "ellipse differs: " .. difference)
        end)
    end
end)

describe("GradientGeometry frame conversion", function()
    local ImageFrame

    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        package.loaded.ImageFrame = nil
        GradientGeometry = require "GradientGeometry"
        ImageFrame = require "ImageFrame"
    end)

    local function frameOf(orientation, settings)
        return ImageFrame.of({
            orientation = orientation,
            dimensions = { width = 3000, height = 2000 },
            settings = settings or {},
        })
    end

    local radial =
        { center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30, feather = 40, area = "outside" }

    it("keeps the geometry of an uncropped upright photo", function()
        local frame = frameOf("AB")

        assert.are.same(radial, GradientGeometry.toStoredFrame("radial", radial, frame))
        assert.are.same(radial, GradientGeometry.toDisplayedFrame("radial", radial, frame))
    end)

    it("turns a displayed radial into the stored one and back for every orientation, crop and straighten", function()
        for _, settings in ipairs({
            {},
            { CropLeft = 0.1, CropTop = 0.05, CropRight = 0.8, CropBottom = 0.9, CropAngle = -6 },
        }) do
            for _, orientation in ipairs({ "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }) do
                local frame = frameOf(orientation, settings)

                local stored = GradientGeometry.toStoredFrame("radial", radial, frame)
                local displayed = GradientGeometry.toDisplayedFrame("radial", stored, frame)

                assert.is_true(math.abs(displayed.center.x - 0.2) < 1e-5 and math.abs(displayed.center.y - 0.1) < 1e-5)
                assert.is_true(math.abs(displayed.width - 0.3) < 1e-5 and math.abs(displayed.height - 0.5) < 1e-5)
                assert.is_true(math.abs(displayed.rotation - 30) < 1e-5)
                assert.are.equal(40, stored.feather)
                assert.are.equal("outside", stored.area)
                assert.is_true(math.abs(stored.width * frame.storedSize.width - 0.3 * frame.displayedSize.width) < 1e-6)
            end
        end
    end)

    it("reports a displayed radial turned past 45 degrees with swapped sizes, as the stored one is", function()
        local frame = frameOf("AB", { CropAngle = 8 })
        local stored = GradientGeometry.toStoredFrame("radial", radial, frame)
        stored.rotation = stored.rotation + 30

        local displayed = GradientGeometry.toDisplayedFrame("radial", stored, frame)

        assert.is_true(math.abs(displayed.rotation + 30) < 1e-5)
        assert.is_true(math.abs(displayed.width * frame.displayedSize.width - 0.5 * frame.displayedSize.height) < 1e-3)
    end)

    it("does not change the geometry it was given", function()
        GradientGeometry.toStoredFrame("radial", radial, frameOf("BC"))

        assert.are.same(point(0.2, 0.1), radial.center)
        assert.are.equal(0.3, radial.width)
    end)
end)
