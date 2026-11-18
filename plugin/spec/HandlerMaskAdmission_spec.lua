local helper = require 'spec_helper'

local Store = require 'fake_mask_store'

local HOME = "/Users/tester"
local CERTIFICATION_FILE = HOME .. "/.config/lightroom-agent/mask-certification.json"
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
        LrApplicationView = {},
        LrDevelopController = {},
        LrSelection = {},
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
    for _, name in ipairs({ "HandlerMaskAdmission", "GuardedMaskWrite", "MaskWriteAdmission", "RunningLightroom", "PluginFiles", "PhotoLookup", "Log" }) do
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

    for _, case in ipairs({
        { held = "masks of the pinned format", entry = Store.correction("A", { Store.linearComponent() }), problems = {} },
        { held = "a mask outside the pinned format, listing it", entry = Store.correction("Odd", { { What = "Mask/Mystery", MaskActive = true } }),
            problems = { "existing mask 1.CorrectionMasks[1]: unknown mask type Mask/Mystery" } },
        { held = "a mask Lightroom has not named yet, listing it", entry = Store.correction("New", { Store.linearComponent() }),
            unnamed = true, problems = { "existing mask 1: missing CorrectionID" } },
    }) do
        it("admits a photo of a certified build with a certified process version holding " .. case.held, function()
            local Handler, state = setup({ files = { [CERTIFICATION_FILE] = CERTIFIED }, entries = { case.entry } })
            if case.unnamed then state.entries[1].CorrectionID, state.entries[1].CorrectionSyncID = nil, nil end

            local result = Handler.get({ photo_id = "7" })

            assert.is_true(result.admitted)
            assert.are.same({ photo_id = "7", process_version = "15.4", mask_count = 1, schema_problems = case.problems,
                admitted = true }, result.photo)
        end)
    end

    it("does not admit a photo whose process version the certification did not exercise", function()
        local Handler = setup({ files = { [CERTIFICATION_FILE] = CERTIFIED }, processVersion = "11.0" })

        local photo = Handler.get({ photo_id = "7" }).photo

        assert.is_false(photo.admitted)
        assert.is_truthy(photo.reason:find("process version (11.0)", 1, true))
    end)

    it("answers an unknown photo as not found", function()
        local Handler = setup()

        assert.are.equal("99", helper.notFoundOf(function() Handler.get({ photo_id = "99" }) end))
    end)
end)
