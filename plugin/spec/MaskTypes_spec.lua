require "spec_helper"

local MaskTypes = require "MaskTypes"

describe("MaskTypes", function()
    it("keeps each type's label and stored selectors and nothing else", function()
        assert.are.same({ label = "Sky", stored = { MaskSubType = 2 } }, MaskTypes.SPECS.sky)
        assert.are.same(
            { label = "Background", stored = { MaskSubType = 0, MaskSubCategoryID = 22 } },
            MaskTypes.SPECS.background
        )
    end)

    it("builds a component from the type's selectors in the operation's form", function()
        assert.are.same({
            What = "Mask/Image",
            MaskVersion = 1,
            MaskName = "Background 1",
            MaskActive = true,
            MaskSubType = 0,
            MaskSubCategoryID = 22,
            MaskBlendMode = 1,
            MaskValue = 0,
            MaskInverted = true,
        }, MaskTypes.component("background", "intersect"))
        assert.are.same({
            What = "Mask/Image",
            MaskVersion = 1,
            MaskName = "Subject 1",
            MaskActive = true,
            MaskSubType = 1,
            MaskBlendMode = 0,
            MaskValue = 1,
            MaskInverted = false,
        }, MaskTypes.component("subject", "add"))
    end)
end)
