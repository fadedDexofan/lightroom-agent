require 'spec_helper'

local MaskTypes = require 'MaskTypes'

describe("MaskTypes", function()
    it("maps every type to an SDK tool type and subtype", function()
        for _, spec in pairs(MaskTypes.SPECS) do
            assert.is_string(spec.toolType)
            assert.is_string(spec.subtype)
        end
        assert.are.same({ toolType = "aiSelection", subtype = "sky", label = "Sky", stored = { MaskSubType = 2 } }, MaskTypes.SPECS.sky)
    end)
end)
