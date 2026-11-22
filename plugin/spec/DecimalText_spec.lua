local DecimalText = require "DecimalText"

describe("DecimalText.fixed", function()
    after_each(function() os.setlocale("C", "numeric") end)

    it("writes a decimal point and never an exponent, whatever the locale", function()
        assert.truthy(os.setlocale("ru_RU.UTF-8", "numeric"))
        assert.are.equal("0.500000", DecimalText.fixed(0.5, 6))
        assert.are.equal("0.000000", DecimalText.fixed(1e-7, 6))
        assert.are.equal("0.000001", DecimalText.fixed(1e-6, 6))
        assert.are.equal("12345678.9", DecimalText.fixed(12345678.9, 1))
    end)

    it("rounds to the requested places and keeps the sign", function()
        assert.are.equal("0.3000", DecimalText.fixed(0.3, 4))
        assert.are.equal("1.000000", DecimalText.fixed(0.9999996, 6))
        assert.are.equal("-0.250000", DecimalText.fixed(-0.25, 6))
        assert.are.equal("0.000000", DecimalText.fixed(-1e-9, 6))
    end)

    it("writes the shortest decimal that reads back exactly, and whole numbers without a fraction", function()
        assert.truthy(os.setlocale("ru_RU.UTF-8", "numeric"))
        assert.are.equal("0.1", DecimalText.number(0.1))
        assert.are.equal("0.30000000000000004", DecimalText.number(0.1 + 0.2))
        assert.are.equal("42", DecimalText.number(42))
        assert.are.equal("-67.5 12.5", DecimalText.significant(-67.5, 10) .. " " .. DecimalText.significant(12.5, 10))
        assert.are.equal(0.1, DecimalText.parse("0.1"))
        assert.are.equal(15.4, DecimalText.parse(15.4))
        assert.is_nil(DecimalText.parse(nil))
    end)

    it("refuses a non-finite number", function()
        for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
            assert.is_false(pcall(DecimalText.fixed, value, 6))
        end
    end)
end)
