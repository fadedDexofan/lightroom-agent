require 'spec_helper'

local AIMaskData = require 'AIMaskData'

local function settingsWith(components)
    return { MaskGroupBasedCorrections = { { CorrectionMasks = components } } }
end

describe("AIMaskData", function()
    it("detects AI masks in settings", function()
        assert.is_true(AIMaskData.containsAIMasks(settingsWith({ { What = "Mask/Image" } })))
        assert.is_false(AIMaskData.containsAIMasks(settingsWith({ { What = "Mask/Gradient" } })))
        assert.is_false(AIMaskData.containsAIMasks({}))
        assert.is_false(AIMaskData.containsAIMasks(nil))
    end)

    it("strips the computed keys from AI masks only and leaves the input untouched", function()
        local settings = settingsWith({
            { What = "Mask/Image", MaskDigest = "a", InputDigest = "b", LocalInputDigest = "c", Origin = "1,0" },
            { What = "Mask/Gradient", MaskDigest = "kept" },
        })

        local stripped = AIMaskData.withoutComputedData(settings)

        assert.are.same({
            { What = "Mask/Image", Origin = "1,0" },
            { What = "Mask/Gradient", MaskDigest = "kept" },
        }, stripped.MaskGroupBasedCorrections[1].CorrectionMasks)
        assert.are.equal("a", settings.MaskGroupBasedCorrections[1].CorrectionMasks[1].MaskDigest)
    end)

    it("returns settings without AI masks as they are", function()
        local settings = settingsWith({ { What = "Mask/Gradient" } })

        assert.are.equal(settings, AIMaskData.withoutComputedData(settings))
    end)

    it("tells whether a correction holds an AI component with neither a digest nor an error reason", function()
        local function uncomputed(components) return AIMaskData.uncomputed({ CorrectionMasks = components }) end
        assert.is_true(uncomputed({ { What = "Mask/Image", ErrorReason = 1 }, { What = "Mask/Image" } }))
        assert.is_true(uncomputed({ { What = "Mask/Image", MaskDigest = "" } }))
        assert.is_true(uncomputed({ { What = "Mask/Image", MaskDigest = "a" }, { What = "Mask/Image", ErrorReason = 0 } }))
        assert.is_false(uncomputed({ { What = "Mask/Image", ErrorReason = 1 }, { What = "Mask/Image", MaskDigest = "a" } }))
        assert.is_false(uncomputed({ { What = "Mask/Image", MaskDigest = "a" } }))
        assert.is_false(uncomputed({ { What = "Mask/Gradient" } }))
        assert.is_false(uncomputed({}))
    end)

    it("calls a correction computed only when every AI mask carries its digest, failed on an error reason and none without AI masks", function()
        local function state(components) return AIMaskData.computeState({ CorrectionMasks = components }) end
        assert.are.equal("computed", state({ { What = "Mask/Image", MaskDigest = "a" } }))
        assert.are.equal("computed", state({ { What = "Mask/Image", MaskDigest = "a", ErrorReason = 0 } }))
        assert.are.equal("pending", state({ { What = "Mask/Image" } }))
        assert.are.equal("pending", state({ { What = "Mask/Image", MaskDigest = "" } }))
        assert.are.equal("pending", state({ { What = "Mask/Image", MaskDigest = "a" }, { What = "Mask/Image" } }))
        assert.are.equal("failed", state({ { What = "Mask/Image", MaskDigest = "a", ErrorReason = 3 } }))
        assert.are.equal("none", state({ { What = "Mask/Gradient" } }))
        assert.are.equal("pending", AIMaskData.computeState(nil))
        assert.are.equal("pending", AIMaskData.computeState({}))
    end)
end)
