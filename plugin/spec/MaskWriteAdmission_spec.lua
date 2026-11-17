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
    package.loaded.RunningLightroom = nil
    return require 'MaskWriteAdmission'
end

local THROWAWAY_CATALOG = HOME .. "/Pictures/lrmcp-live-1/lrmcp-live-1.lrcat"
local THROWAWAY_MARKER = HOME .. "/Pictures/lrmcp-live-1/lrmcp-live-catalog.json"

local catalog = { getPath = function() return PERSONAL_CATALOG end }
local throwaway = { getPath = function() return THROWAWAY_CATALOG end }

local function certification(build)
    return '{"lightroom":{"version":"16.0","build":"' .. build .. '"},'
        .. '"process_versions":["15.4","15.3"],"certified_at":"2026-11-12T10:00:00Z","checks":["linear create"]}'
end

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

describe("MaskWriteAdmission.decide", function()
    it("admits the running build for a process version its certification exercised", function()
        local Admission = load({ [CERTIFICATION_FILE] = certification(RUNNING_BUILD) })

        assert.is_true(Admission.decide(catalog, "15.3").admitted)
    end)

    it("refuses without a certification and says how to certify", function()
        local decision = load({}).decide(catalog, "15.4")

        assert.is_false(decision.admitted)
        assert.is_truthy(decision.reason:find("Lightroom Classic 16.0 (" .. RUNNING_BUILD .. ") is not certified", 1, true))
        assert.is_truthy(decision.reason:find("certified: none", 1, true))
        assert.is_truthy(decision.reason:find("certify-mask-writes.mjs", 1, true))
    end)

    it("refuses a certification for another build and names that build", function()
        local decision = load({ [CERTIFICATION_FILE] = certification("16.0.0 build 7654321") }).decide(catalog, "15.4")

        assert.is_false(decision.admitted)
        assert.is_truthy(decision.reason:find("certified: 16.0.0 build 7654321", 1, true))
    end)

    it("refuses a process version the certification did not exercise and lists the ones it did", function()
        local decision = load({ [CERTIFICATION_FILE] = certification(RUNNING_BUILD) }).decide(catalog, "11.0")

        assert.is_false(decision.admitted)
        assert.is_truthy(decision.reason:find("process version (11.0)", 1, true))
        assert.is_truthy(decision.reason:find("certified: 15.4, 15.3", 1, true))
    end)

    it("admits any process version on the kit's throwaway catalog without a certification", function()
        local decision = load({ [THROWAWAY_MARKER] = "{}" }).decide(throwaway, "11.0")

        assert.is_true(decision.admitted)
        assert.is_true(decision.throwaway_catalog)
    end)
end)

describe("MaskWriteAdmission.requireAdmitted", function()
    it("refuses with the decision's reason and leaves what was written to the outcome", function()
        local Admission = load({ [CERTIFICATION_FILE] = certification(RUNNING_BUILD) })

        local refusal = helper.failedOf(function() Admission.requireAdmitted(catalog, "11.0") end)

        assert.is_truthy(refusal:find("process version (11.0)", 1, true))
        assert.is_nil(refusal:find("othing was", 1, true))
    end)

    it("returns quietly when the write is admitted", function()
        local Admission = load({ [CERTIFICATION_FILE] = certification(RUNNING_BUILD) })

        assert.has_no.errors(function() Admission.requireAdmitted(catalog, "15.4") end)
    end)
end)
