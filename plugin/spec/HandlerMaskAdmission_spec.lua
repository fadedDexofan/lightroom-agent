local helper = require 'spec_helper'

local Store = require 'fake_mask_store'

local HOME = "/Users/tester"
local CERTIFICATION_FILE = HOME .. "/.config/lightroom-mcp/mask-certification.json"
local PERSONAL_CATALOG = HOME .. "/Pictures/Lightroom/Lightroom Catalog.lrcat"
local RUNNING_BUILD = "16.0.0 build 1234567"
local CERTIFIED = '{"lightroom":{"version":"16.0","build":"' .. RUNNING_BUILD .. '"},'
    .. '"process_versions":["15.4"],"certified_at":"2026-11-12T10:00:00Z","checks":["linear create"]}'

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ localIdentifier = 7 })
    local state = Store.attach(photo, opts)
    local catalog = helper.fakeCatalog({ photos = { photo } })
    catalog.getPath = function() return PERSONAL_CATALOG end
    Store.trackGates(state, catalog)
    local files = opts.files or {}
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            versionTable = function() return { major = 16, minor = 0, revision = 0, build = 1234567 } end,
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
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskAdmission", "GuardedMaskWrite", "MaskWriteAdmission", "PluginFiles", "PhotoLookup", "Log" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskAdmission', state
end

describe("HandlerMaskAdmission.get", function()
    it("reports an uncertified Lightroom without reading any photo", function()
        local Handler, state = setup()

        local result = Handler.get({})

        assert.is_false(result.admitted)
        assert.are.same({ version = "16.0", build = RUNNING_BUILD, version_table = { major = 16, minor = 0, revision = 0, build = 1234567 } }, result.running)
        assert.are.equal(CERTIFICATION_FILE, result.certification_file)
        assert.is_truthy(result.reason:find("certify-mask-writes.mjs", 1, true))
        assert.is_nil(result.photo)
        assert.are.equal(0, state.reads)
    end)

    it("admits a photo of a certified build with a certified process version and pinned masks", function()
        local Handler = setup({
            files = { [CERTIFICATION_FILE] = CERTIFIED },
            entries = { Store.correction("A", { Store.linearComponent() }) },
        })

        local result = Handler.get({ photo_id = "7" })

        assert.is_true(result.admitted)
        assert.are.same({
            photo_id = "7", process_version = "15.4", mask_count = 1, schema_problems = {}, admitted = true,
        }, result.photo)
    end)

    it("does not admit a photo whose existing masks leave the pinned format and lists the problems", function()
        local odd = Store.correction("Odd", { { What = "Mask/Mystery", MaskActive = true } })
        local Handler = setup({ files = { [CERTIFICATION_FILE] = CERTIFIED }, entries = { odd } })

        local photo = Handler.get({ photo_id = "7" }).photo

        assert.is_false(photo.admitted)
        assert.are.equal(1, #photo.schema_problems)
        assert.is_truthy(photo.reason:find("pinned mask format", 1, true))
    end)

    it("does not admit a photo whose process version the certification did not exercise", function()
        local Handler = setup({ files = { [CERTIFICATION_FILE] = CERTIFIED }, processVersion = "11.0" })

        local photo = Handler.get({ photo_id = "7" }).photo

        assert.is_false(photo.admitted)
        assert.is_truthy(photo.reason:find("process version (11.0)", 1, true))
    end)

    it("refuses an unknown photo", function()
        local Handler = setup()

        assert.has_error(function() Handler.get({ photo_id = "99" }) end, "Photo not found: 99")
    end)
end)
