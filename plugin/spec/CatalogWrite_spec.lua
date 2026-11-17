local helper = require 'spec_helper'

local function catalogAnswering(outcome)
    local calls = {}
    return {
        withWriteAccessDo = function(_, title, fn, timeoutParams)
            calls[#calls + 1] = { title = title, timeoutParams = timeoutParams }
            if outcome == "aborted" then return "aborted" end
            fn()
            return "executed"
        end,
    }, calls
end

describe("CatalogWrite.run", function()
    before_each(function()
        package.loaded.CatalogWrite = nil
    end)

    it("waits for write access for WAIT_SECONDS and runs the write", function()
        local CatalogWrite = require 'CatalogWrite'
        local catalog, calls = catalogAnswering("executed")
        local ran = false

        CatalogWrite.run(catalog, "Set Rating", function() ran = true end)

        assert.is_true(ran)
        assert.are.same({ { title = "Set Rating", timeoutParams = { timeout = CatalogWrite.WAIT_SECONDS } } }, calls)
    end)

    it("refuses when the catalog stays busy and nothing was written before", function()
        local CatalogWrite = require 'CatalogWrite'
        local catalog = catalogAnswering("aborted")

        assert.are.equal("The catalog stayed busy with another write for " .. CatalogWrite.WAIT_SECONDS
            .. " s, so Lightroom did not run Set Rating", helper.refusalOf(function()
            CatalogWrite.run(catalog, "Set Rating", function() end)
        end))
    end)

    it("answers unknown, naming what was written, when the catalog stays busy after earlier writes", function()
        local CatalogWrite = require 'CatalogWrite'
        local catalog = catalogAnswering("aborted")

        local err = helper.unknownOf(function()
            CatalogWrite.run(catalog, "Create Collection", function() end, "the collection set Trips was created")
        end)

        assert.are.equal("The catalog stayed busy with another write for " .. CatalogWrite.WAIT_SECONDS
            .. " s, so Lightroom did not run Create Collection; the collection set Trips was created", err)
    end)
end)
