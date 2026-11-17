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

    it("strips what Lightroom computes for the photo, its failure included, from AI masks only and leaves the input"
        .. " untouched", function()
        local settings = settingsWith({
            { What = "Mask/Image", MaskSubType = 2, MaskBlendMode = 1, MaskValue = 0, MaskInverted = true, MaskName = "Sky 1",
                MaskID = "S1", MaskDigest = "a", InputDigest = "b", InputDigestVersion = 1, LocalInputDigest = "c",
                LocalInputDigestVersion = 1, ModelVersion = 3, FullMaskSize = "6000,4000", Origin = "1,0",
                ReferencePoint = "0.5 0.5", WholeImageArea = "0 0 1 1", MaskSyncID = "SS1", ErrorReason = 1 },
            { What = "Mask/Gradient", MaskDigest = "kept", Origin = "kept" },
        })

        local stripped = AIMaskData.withoutComputedData(settings)

        assert.are.same({
            { What = "Mask/Image", MaskSubType = 2, MaskBlendMode = 1, MaskValue = 0, MaskInverted = true,
                MaskName = "Sky 1", MaskID = "S1" },
            { What = "Mask/Gradient", MaskDigest = "kept", Origin = "kept" },
        }, stripped.MaskGroupBasedCorrections[1].CorrectionMasks)
        assert.are.equal("a", settings.MaskGroupBasedCorrections[1].CorrectionMasks[1].MaskDigest)
    end)

    it("names each ErrorReason Lightroom assigns beside its number, and only the number for another value", function()
        assert.are.same({
            "ErrorReason 1, no result", "ErrorReason 2, model unavailable or not loaded", "ErrorReason 3, another failure",
            "ErrorReason 4, model could not be downloaded", "ErrorReason 7",
        }, { AIMaskData.errorReasonText(1), AIMaskData.errorReasonText(2), AIMaskData.errorReasonText(3),
            AIMaskData.errorReasonText(4), AIMaskData.errorReasonText(7) })
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
