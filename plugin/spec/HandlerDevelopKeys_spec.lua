local fake = require "fake_mask_develop"
local helper = require "spec_helper"

local function setup(opts)
    opts = opts or {}
    local ctx = fake.build({
        photos = { { id = "1", masks = { ["mask-a"] = { local_Exposure = 0 }, ["mask-b"] = { local_Exposure = 0 } } } },
        modules = { "HandlerDevelopKeys", "DevelopSession", "MaskSelection", "RunningLightroom" },
        handler = "HandlerDevelopKeys",
        version = { major = 16, minor = 0, revision = 0, build = 202611041403 },
        extend = function(controller, state)
            controller.getRange = function(key)
                if key == "Exposure2012" then return -5, 5 end
                if key == "Temperature" then error("no range for this key") end
                if key == "local_Exposure" then
                    if opts.clickedDuringRead then controller.selectMask(opts.clickedDuringRead) end
                    if state.currentValues() == nil then return -100, 100 end
                    return -4, 4
                end
                return nil
            end
        end,
    })
    local getSettings = ctx.photos[1].getDevelopSettings
    ctx.photos[1].getDevelopSettings = function()
        local settings = getSettings()
        settings.ProcessVersion = "15.4"
        return settings
    end
    return ctx
end

describe("HandlerDevelopKeys.ranges", function()
    it("reports a key with a range, leaves out keys without one and names the build and process version", function()
        local ctx = setup()

        local r = ctx.Handler.ranges(
            { photo_id = "1", keys = { "Exposure2012", "Temperature", "Texture" } },
            helper.requestContext()
        )

        assert.are.same({ Exposure2012 = { -5, 5 } }, r.ranges)
        assert.are.same({ version = "16.0", build = "16.0.0 build 202611041403" }, r.lightroom)
        assert.are.equal("15.4", r.process_version)
        assert.is_nil(r.local_ranges)
        assert.are.same({ "develop", "library" }, ctx.calls.modules)
    end)

    it("reads a local key's range with the given mask selected", function()
        local ctx = setup()

        local r = ctx.Handler.ranges({
            photo_id = "1",
            keys = { "Exposure2012" },
            mask_id = "mask-a",
            local_keys = { "local_Exposure" },
        }, helper.requestContext())

        assert.are.same({ local_Exposure = { -4, 4 } }, r.local_ranges)
        assert.are.same({ "develop", "library" }, ctx.calls.modules)
    end)

    it("refuses the local ranges when another mask was selected while they were read", function()
        local ctx = setup({ clickedDuringRead = "mask-b" })

        local message = helper.failedOf(
            function()
                ctx.Handler.ranges(
                    { photo_id = "1", keys = {}, mask_id = "mask-a", local_keys = { "local_Exposure" } },
                    helper.requestContext()
                )
            end
        )

        assert.are.equal(
            "Mask mask-b became selected in Develop while mask mask-a was read on photo 1; call again"
                .. " without changing the selection",
            message
        )
    end)
end)
