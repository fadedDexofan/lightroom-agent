local helper = require 'spec_helper'

local function load()
    helper.installImport({
        LrApplicationView = {},
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "MaskCreationAdjustments", "MaskSelection", "DevelopSession", "LocalSliders", "Log" }) do
        package.loaded[name] = nil
    end
    return require 'MaskCreationAdjustments'
end

describe("MaskCreationAdjustments.write", function()
    it("stores each requested slider as Lightroom 16.0 stored it and leaves the others unset", function()
        local entry = {}

        load().write(entry, {
            local_Exposure = 2, local_Contrast = -25, local_colorgradeMidtoneHue = 200, local_glow = 25,
        })

        assert.are.same({
            LocalExposure2012 = 0.5, LocalContrast2012 = -0.25, LocalColorGradeMidtoneHue = 200, LocalGlow = 0.25,
        }, entry)
    end)

    it("writes nothing when no adjustments were requested", function()
        local entry = { CorrectionName = "Sky" }

        load().write(entry, nil)

        assert.are.same({ CorrectionName = "Sky" }, entry)
    end)
end)

describe("MaskCreationAdjustments.parse", function()
    it("asks nothing of Lightroom when the request has no adjustments", function()
        assert.is_nil(load().parse({}))
    end)
end)
