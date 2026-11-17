local helper = require 'spec_helper'

describe("JsonValue.equal", function()
    local JsonValue

    before_each(function()
        helper.installImport({})
        package.loaded.JsonValue = nil
        JsonValue = require 'JsonValue'
    end)

    it("compares scalars by value and type", function()
        assert.is_true(JsonValue.equal(1, 1))
        assert.is_true(JsonValue.equal("a", "a"))
        assert.is_false(JsonValue.equal(1, "1"))
        assert.is_false(JsonValue.equal(true, 1))
    end)

    it("compares nested tables key by key in both directions", function()
        assert.is_true(JsonValue.equal({ a = { 1, 2 }, b = "x" }, { b = "x", a = { 1, 2 } }))
        assert.is_false(JsonValue.equal({ a = { 1, 2 } }, { a = { 1, 3 } }))
        assert.is_false(JsonValue.equal({ a = 1 }, { a = 1, b = 2 }))
        assert.is_false(JsonValue.equal({ a = 1, b = 2 }, { a = 1 }))
        assert.is_false(JsonValue.equal({}, nil))
    end)
end)

describe("JsonValue.differences", function()
    local JsonValue

    before_each(function()
        helper.installImport({})
        package.loaded.JsonValue = nil
        JsonValue = require 'JsonValue'
    end)

    it("lists the path of every value that differs, in both directions, with no tolerance", function()
        local expected = { { LocalExposure2012 = 0.125, CorrectionMasks = { { MaskDigest = "A" } } }, { Name = "b" } }
        local actual = { { LocalExposure2012 = 0.1250001, CorrectionMasks = { {} }, Extra = true }, { Name = "b" } }

        assert.are.same({ "1.CorrectionMasks.1.MaskDigest", "1.Extra", "1.LocalExposure2012" },
            JsonValue.differences(expected, actual))
        assert.are.same({}, JsonValue.differences(expected, { { LocalExposure2012 = 0.125, CorrectionMasks = { { MaskDigest = "A" } } }, { Name = "b" } }))
        assert.are.same({ "" }, JsonValue.differences(1, "1"))
    end)
end)
