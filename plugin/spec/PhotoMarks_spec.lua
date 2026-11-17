local helper = require 'spec_helper'

local MARK_CASES = {
    { meta = {}, rating = 0, flag = "none", color_label = "none" },
    { meta = { rating = 3, pickStatus = 1, colorNameForLabel = "green" }, rating = 3, flag = "pick", color_label = "green" },
    { meta = { rating = 1, pickStatus = 0, colorNameForLabel = "gray" }, rating = 1, flag = "none", color_label = "none" },
    { meta = { rating = 2, pickStatus = -1, colorNameForLabel = "red" }, rating = 2, flag = "reject", color_label = "red" },
    { meta = { rating = 4, colorNameForLabel = "yellow" }, rating = 4, flag = "none", color_label = "yellow" },
    { meta = { rating = 5, colorNameForLabel = "blue" }, rating = 5, flag = "none", color_label = "blue" },
    { meta = { colorNameForLabel = "purple" }, rating = 0, flag = "none", color_label = "purple" },
    { meta = { colorNameForLabel = "none" }, rating = 0, flag = "none", color_label = "none" },
}

describe("PhotoMarks.of", function()
    local PhotoMarks

    before_each(function()
        helper.installImport({})
        package.loaded.PhotoMarks = nil
        PhotoMarks = require 'PhotoMarks'
    end)

    it("reads rating, flag and color label in the vocabulary of the write tools and the search filter", function()
        for _, case in ipairs(MARK_CASES) do
            assert.are.same({ rating = case.rating, flag = case.flag, color_label = case.color_label }, PhotoMarks.of(case.meta))
        end
    end)
end)
