local helper = require 'spec_helper'

local HOME = "/Users/tester"
local CERTIFICATION_FILE = HOME .. "/.config/lightroom-mcp/mask-certification.json"
local PERSONAL_CATALOG = HOME .. "/Pictures/Lightroom/Lightroom Catalog.lrcat"
local RUNNING_BUILD = "16.0.0 build 1234567"

local function load(files, versionTable)
    helper.installImport({
        LrApplication = {
            versionTable = function() return versionTable or { major = 16, minor = 0, revision = 0, build = 1234567 } end,
            versionString = function() return "16.0" end,
        },
        LrFileUtils = {
            exists = function(path) return files[path] ~= nil and "file" or false end,
            readFile = function(path) return files[path] end,
        },
        LrPathUtils = {
            child = function(parent, name) return parent .. "/" .. name end,
            parent = function(path) return path:match("^(.*)/[^/]*$") end,
            getStandardFilePath = function() return HOME end,
        },
    })
    package.loaded.MaskWriteAdmission = nil
    package.loaded.PluginFiles = nil
    return require 'MaskWriteAdmission'
end

local catalog = { getPath = function() return PERSONAL_CATALOG end }

describe("MaskWriteAdmission.status", function()
    it("reports the running Lightroom, the certification file and no certification", function()
        local status = load({}).status(catalog)

        assert.is_false(status.admitted)
        assert.is_false(status.throwaway_catalog)
        assert.are.same({ version = "16.0", build = RUNNING_BUILD, version_table = { major = 16, minor = 0, revision = 0, build = 1234567 } }, status.running)
        assert.are.equal(CERTIFICATION_FILE, status.certification_file)
        assert.is_nil(status.certified)
        assert.is_truthy(status.reason:find("certified: none", 1, true))
    end)

    it("reports the certified build, process versions, time and checks", function()
        local status = load({
            [CERTIFICATION_FILE] = '{"lightroom":{"version":"16.0","build":"' .. RUNNING_BUILD .. '"},'
                .. '"process_versions":["15.4"],"certified_at":"2026-11-12T10:00:00Z","checks":["linear create","sky batch"]}',
        }).status(catalog)

        assert.is_true(status.admitted)
        assert.is_nil(status.reason)
        assert.are.same({
            version = "16.0", build = RUNNING_BUILD, process_versions = { "15.4" },
            certified_at = "2026-11-12T10:00:00Z", checks = { "linear create", "sky batch" },
        }, status.certified)
    end)

    it("admits nothing when Lightroom reports no build number", function()
        local status = load({
            [CERTIFICATION_FILE] = '{"lightroom":{"version":"16.0","build":"16.0"},"process_versions":["15.4"],"certified_at":"x"}',
        }, { major = 16, minor = 0, revision = 0 }).status(catalog)

        assert.is_false(status.admitted)
        assert.is_nil(status.running.build)
        assert.is_truthy(status.reason:find("reports no build number", 1, true))
    end)

    it("does not admit on a certification file it cannot read as a record", function()
        for _, content in ipairs({ "not json", '{"lightroom":{"version":"16.0"}}', '{"lightroom":{"version":"16.0","build":"' .. RUNNING_BUILD .. '"},"process_versions":[],"certified_at":"x"}' }) do
            local status = load({ [CERTIFICATION_FILE] = content }).status(catalog)

            assert.is_false(status.admitted)
            assert.is_nil(status.certified)
            assert.is_truthy(status.reason:find("is not a certification record", 1, true))
        end
    end)
end)
