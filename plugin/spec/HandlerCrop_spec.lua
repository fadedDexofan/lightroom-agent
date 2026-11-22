local helper = require "spec_helper"

describe("HandlerCrop", function()
    local function setup(settings)
        local photo = helper.fakePhoto({
            id = "7",
            path = "/7.arw",
            orientation = "AB",
            dimensions = { width = 1500, height = 1000 },
            developSettings = settings or {},
        })
        local catalog = helper.fakeCatalog({ photos = { photo } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
        })
        for _, name in ipairs({ "HandlerCrop", "ImageFrame", "PhotoLookup", "Log" }) do
            package.loaded[name] = nil
        end
        return require "HandlerCrop", catalog
    end

    it("plans the keys, rectangle and pixel size of a 4:5 frame around a centre without writing", function()
        local Handler, catalog = setup()

        local plan = Handler.plan({
            photo_id = "7",
            aspect = { width = 4, height = 5 },
            center = { x = 0.4, y = 0.5 },
            scale = 0.5,
            angle = 0,
        }, helper.requestContext())

        assert.are.equal("7", plan.photo_id)
        assert.is_true(math.abs(plan.size.width - 400) < 1e-6 and math.abs(plan.size.height - 500) < 1e-6)
        assert.is_true(math.abs(plan.rectangle.left - (0.4 - 200 / 1500)) < 1e-6)
        assert.is_true(math.abs(plan.settings.CropLeft - (0.4 - 200 / 1500)) < 1e-9)
        assert.is_true(math.abs(plan.settings.CropBottom - 0.75) < 1e-9)
        assert.are.equal(0, plan.angle)
        assert.are.equal(0, catalog:getWriteAccessCount())
    end)

    it("plans a displayed rectangle with an angle", function()
        local Handler = setup()

        local plan = Handler.plan(
            { photo_id = "7", rectangle = { left = 0.2, top = 0.2, right = 0.8, bottom = 0.8 }, angle = 3 },
            helper.requestContext()
        )

        assert.is_true(math.abs(plan.size.width - 900) < 1e-6 and math.abs(plan.size.height - 600) < 1e-6)
        assert.is_true(math.abs(plan.settings.CropAngle - 3) < 1e-9)
    end)

    it("warns that Upright moves the frame away from the preview", function()
        local Handler = setup({ PerspectiveUpright = 1 })
        local context = helper.requestContext()

        Handler.plan({ photo_id = "7", aspect = { width = 1, height = 1 }, angle = 0 }, context)

        assert.are.equal(1, #context.warnings)
        assert.is_truthy(context.warnings[1]:find("PerspectiveUpright 1", 1, true))
    end)

    it("reads the current crop as the frame in the photo as displayed before any crop, with its pixel size", function()
        local Handler = setup({ CropLeft = 0.15, CropTop = 0.1, CropRight = 0.92, CropBottom = 0.9, CropAngle = 8 })

        local crop = Handler.read({ photo_id = "7" }, helper.requestContext())

        assert.are.equal("7", crop.photo_id)
        assert.are.same({ width = 1255, height = 631 }, crop.size)
        assert.are.equal(8, crop.angle)
        assert.is_true(math.abs(crop.rectangle.left - (0.535 - 1255.18 / 3000)) < 1e-4)
        assert.is_true(math.abs(crop.rectangle.bottom - (0.5 + 631.45 / 2000)) < 1e-4)
    end)

    it("plans a 4:5 frame inside the current crop and reports it in the photo's frame", function()
        local Handler = setup({ CropLeft = 0.2, CropTop = 0, CropRight = 0.8, CropBottom = 1, CropAngle = 0 })

        local plan = Handler.plan(
            { photo_id = "7", relative_to = "crop", aspect = { width = 4, height = 5 }, angle = 0 },
            helper.requestContext()
        )

        assert.are.same({ width = 800, height = 1000 }, plan.size)
        assert.is_true(math.abs(plan.rectangle.left - (0.5 - 400 / 1500)) < 1e-6)
        assert.is_true(math.abs(plan.rectangle.right - (0.5 + 400 / 1500)) < 1e-6)
        assert.are.equal(0, plan.rectangle.top)
        assert.are.equal(1, plan.rectangle.bottom)
        assert.is_true(math.abs(plan.settings.CropLeft - (0.5 - 400 / 1500)) < 1e-9)
    end)

    it("plans a rectangle stated in the current crop's own coordinates", function()
        local Handler = setup({ CropLeft = 0.2, CropTop = 0, CropRight = 0.8, CropBottom = 1, CropAngle = 0 })

        local plan = Handler.plan({
            photo_id = "7",
            relative_to = "crop",
            rectangle = { left = 0, top = 0, right = 0.5, bottom = 0.5 },
            angle = 0,
        }, helper.requestContext())

        assert.is_true(math.abs(plan.rectangle.left - 0.2) < 1e-6 and math.abs(plan.rectangle.right - 0.5) < 1e-6)
        assert.is_true(math.abs(plan.rectangle.bottom - 0.5) < 1e-6)
    end)

    it("keeps a straightened aspect fit inside the current crop", function()
        local Handler = setup({ CropLeft = 0.2, CropTop = 0, CropRight = 0.8, CropBottom = 1, CropAngle = 0 })

        local plan = Handler.plan(
            { photo_id = "7", relative_to = "crop", aspect = { width = 1, height = 1 }, angle = 5 },
            helper.requestContext()
        )

        local radians = math.rad(plan.angle)
        local halfWidth = (plan.size.width * math.cos(radians) + plan.size.height * math.sin(radians)) / 2
        local centre = (plan.rectangle.left + plan.rectangle.right) / 2 * 1500
        assert.is_true(centre - halfWidth >= 0.2 * 1500 - 1)
        assert.is_true(centre + halfWidth <= 0.8 * 1500 + 1)
        assert.are.equal(5, plan.angle)
    end)

    it("refuses a frame whose turned corners cross in the crop keys, in set_crop's own words", function()
        local Handler = setup()

        local refusal = helper.failedOf(
            function()
                Handler.plan(
                    { photo_id = "7", aspect = { width = 1, height = 3 }, angle = 40 },
                    helper.requestContext()
                )
            end
        )

        assert.is_truthy(refusal:find("At angle 40 this frame's turned corners cross", 1, true))
        assert.is_nil(refusal:find("CropLeft", 1, true))
    end)

    it("refuses a frame inside the current crop whose turned corners cross", function()
        local Handler = setup({ CropLeft = 0.2, CropTop = 0, CropRight = 0.8, CropBottom = 1, CropAngle = 0 })

        local refusal = helper.failedOf(
            function()
                Handler.plan(
                    { photo_id = "7", relative_to = "crop", aspect = { width = 1, height = 4 }, angle = 40 },
                    helper.requestContext()
                )
            end
        )

        assert.is_truthy(refusal:find("turned corners cross", 1, true))
    end)
end)
