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
