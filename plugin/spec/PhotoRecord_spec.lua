local helper = require 'spec_helper'

describe("PhotoRecord", function()
    local PhotoRecord

    before_each(function()
        helper.installImport({})
        package.loaded.PhotoRecord = nil
        PhotoRecord = require 'PhotoRecord'
    end)

    it("keeps a group only when one of its fields carries a value", function()
        assert.is_nil(PhotoRecord.nonEmptyGroup({ city = "", country = nil }))
        assert.are.same({ city = "", country = "JP" }, PhotoRecord.nonEmptyGroup({ city = "", country = "JP" }))
    end)

    it("builds the marks, keywords, gps and location groups both metadata tools answer", function()
        local parent = helper.fakeKeyword("Animals")
        local bird = helper.fakeKeyword("Bird", { parent = parent })
        local shared = PhotoRecord.shared({
            rating = 3, pickStatus = 1, colorNameForLabel = "green",
            keywords = { bird }, gps = { latitude = 35.6, longitude = 139.7 }, gpsAltitude = 12,
        }, { city = "Tokyo", country = "" }, PhotoRecord.keywordReader())
        assert.are.same({
            rating = 3, flag = "pick", color_label = "green",
            keywords = { "Bird" }, keyword_paths = { "Animals|Bird" },
            gps = { latitude = 35.6, longitude = 139.7, altitude = 12 },
            location = { city = "Tokyo", country = "" },
        }, shared)
        assert.is_nil(PhotoRecord.shared({ gps = {} }, {}, PhotoRecord.keywordReader()).gps)
    end)

    it("walks a keyword's parents once per reader however many photos carry it", function()
        local parent = helper.fakeKeyword("Animals")
        local bird = helper.fakeKeyword("Bird", { parent = parent })
        local walks = 0
        local getParent = bird.getParent
        bird.getParent = function(self) walks = walks + 1; return getParent(self) end
        local read = PhotoRecord.keywordReader()
        read({ bird })
        read({ bird })
        assert.are.equal(1, walks)
    end)

    it("reads each keyword's name once per reader, for its name and its path", function()
        local parent = helper.fakeKeyword("Animals")
        local bird = helper.fakeKeyword("Bird", { parent = parent })
        local reads = 0
        local getName = bird.getName
        bird.getName = function(self) reads = reads + 1; return getName(self) end
        local read = PhotoRecord.keywordReader()

        read({ bird })
        local names, paths = read({ bird })

        assert.are.equal(1, reads)
        assert.are.same({ { "Bird" }, { "Animals|Bird" } }, { names, paths })
    end)
end)
