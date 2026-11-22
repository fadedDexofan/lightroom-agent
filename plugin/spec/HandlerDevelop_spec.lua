local helper = require 'spec_helper'

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = deepCopy(child) end
    return result
end

local function fakePreset(name, opts)
    opts = opts or {}
    local minted = 0
    return {
        getName = function() return name end,
        getUuid = function() return opts.uuid or ("uuid-" .. name) end,
        getFile = function() return opts.file end,
        getSetting = function()
            local settings = deepCopy(opts.settings or {})
            for _, entry in ipairs(type(settings.MaskGroupBasedCorrections) == "table"
                and settings.MaskGroupBasedCorrections or {}) do
                minted = minted + 1
                entry.CorrectionID = name .. "-read-" .. minted
            end
            return settings
        end,
    }
end

local LONG_CURVE = { 0, 0, 13, 15, 27, 31, 40, 46, 54, 61, 67, 76, 81, 91, 94, 105, 107, 119, 121, 133, 134, 146, 148, 160, 161, 172, 174, 186, 188, 199, 201, 212, 214, 226, 228, 238, 241, 249, 255, 255 }

local AI_MASK_SETTINGS = {
    Exposure2012 = 1.0,
    MaskGroupBasedCorrections = {
        { CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1 } } },
    },
}

local function fakeFolder(name, presets)
    return {
        getName = function() return name end,
        getDevelopPresets = function() return presets end,
    }
end

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {}, writeAccessAborts = opts.writeAccessAborts })
    local pluginPresets = opts.pluginPresets or {}
    local files = opts.files or {}
    local copies = {}
    local function leafName(path)
        return path:match("([^/\\]+)$") or path
    end
    local function extension(path)
        return leafName(path):match("%.([^%.]+)$") or ""
    end
    _G._PLUGIN = { id = "io.github.fadeddexofan.lightroomagent" }
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            developPresetFolders = function() return opts.folders or {} end,
            getDevelopPresetsForPlugin = function() return pluginPresets end,
            addDevelopPresetForPlugin = function(_, name, settings)
                local preset = fakePreset(name, {
                    uuid = "plugin-" .. tostring(#pluginPresets + 1),
                    file = "/plugin/" .. name .. ".xmp",
                    settings = settings,
                })
                table.insert(pluginPresets, preset)
                files[preset:getFile()] = "file"
                return preset
            end,
        },
        LrFileUtils = {
            exists = function(path) return files[path] or false end,
            createAllDirectories = function(path) files[path] = "directory" return true end,
            copy = function(source, destination)
                if opts.copyFails or files[source] ~= "file" or files[destination] then return false, "copy refused" end
                files[destination] = "file"
                table.insert(copies, { source = source, destination = destination })
                return true
            end,
        },
        LrPathUtils = {
            leafName = leafName,
            extension = extension,
            parent = function(path) return path:match("^(.+)/[^/]+$") end,
            child = function(parent, child) return parent .. "/" .. child end,
            getStandardFilePath = function(name) assert(name == "home"); return "/home/u" end,
        },
        LrApplicationView = opts.applicationView or {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function() end,
        },
        LrDate = opts.date or { currentTime = function() return 0 end },
        LrDevelopController = opts.developController or {},
        LrSelection = opts.selection or { selectNone = function() end },
        LrStringUtils = opts.stringUtils or { lower = string.lower },
        LrTasks = opts.tasks or { sleep = function() end, pcall = pcall },
        LrLogger = helper.defaultLrLogger(),
    })
    local Store = require 'fake_mask_store'
    local function storedMasks(photo) return (photo:getDevelopSettings() or {}).MaskGroupBasedCorrections or {} end
    package.loaded.GuardedMaskWrite = not opts.realGuard and (opts.guardedMaskWrite or {
        apply = function(context, _, photo, spec)
            local previous = Store.clone(storedMasks(photo))
            context.ledger:record(spec.description)
            photo:applyDevelopSettings({ MaskGroupBasedCorrections = Store.clone(spec.build(Store.clone(previous))) })
            return { previous = previous }
        end,
        restore = function(context, _, photo, previous, mark)
            photo:applyDevelopSettings({ MaskGroupBasedCorrections = Store.clone(previous) })
            context.ledger:undone(mark)
            return true
        end,
        readEntries = function(_, photo) return Store.clone(storedMasks(photo)) end,
        deepClone = Store.clone,
    }) or nil
    package.loaded.AIMaskCompute = nil
    package.loaded.MaskWriteAdmission = opts.maskWriteAdmission or { status = function() return {} end, requireAdmitted = function() end }
    package.loaded.HandlerDevelop = nil
    package.loaded.DevelopSession = nil
    package.loaded.DevelopBatch = nil
    package.loaded.DevelopReadBack = nil
    return catalog, require 'HandlerDevelop', {
        pluginPresets = pluginPresets,
        files = files,
        copies = copies,
    }
end

describe("HandlerDevelop.listDevelopPresets", function()
    it("returns flat list with name + folder", function()
        local folders = {
            fakeFolder("User Presets", { fakePreset("Vibrant"), fakePreset("Moody") }),
            fakeFolder("Adobe Color", { fakePreset("Standard") }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.listDevelopPresets({})

        assert.are.equal(3, r.count)
        assert.are.equal(3, #r.presets)
        assert.are.equal("Vibrant", r.presets[1].name)
        assert.are.equal("User Presets", r.presets[1].folder)
        assert.are.equal("Standard", r.presets[3].name)
        assert.are.equal("Adobe Color", r.presets[3].folder)
    end)

    it("returns empty list when no folders", function()
        local _, Handler = setup({ folders = {} })
        local r = Handler.listDevelopPresets({})
        assert.are.equal(0, r.count)
        assert.are.same({}, r.presets)
    end)

    it("includes UUID, scope, and plugin-managed checkpoints", function()
        local visible = fakePreset("Visible", { uuid = "visible-1", file = "/user/Visible.xmp" })
        local checkpoint = fakePreset("Look-v2", { uuid = "plugin-1", file = "/plugin/Look-v2.xmp" })
        local _, Handler = setup({
            folders = { fakeFolder("User Presets", { visible }) },
            pluginPresets = { checkpoint },
        })

        local r = Handler.listDevelopPresets({})

        assert.are.equal(2, r.count)
        assert.are.equal("lightroom", r.presets[1].scope)
        assert.are.equal("visible-1", r.presets[1].uuid)
        assert.are.equal("plugin", r.presets[2].scope)
        assert.are.equal("Plugin Develop Presets", r.presets[2].folder)
        assert.are.same({ name = "Visible", folder = "User Presets", scope = "lightroom", uuid = "visible-1" }, r.presets[1])
        assert.is_false(r.has_more)
    end)

    it("pages 250 presets across folders with a default limit of 100", function()
        local first, second = {}, {}
        for i = 1, 125 do
            first[i] = fakePreset("First " .. i)
            second[i] = fakePreset("Second " .. i)
        end
        local _, Handler = setup({ folders = { fakeFolder("A", first), fakeFolder("B", second) } })
        local a = Handler.listDevelopPresets({})
        local b = Handler.listDevelopPresets({ offset = 100 })
        local c = Handler.listDevelopPresets({ offset = 200 })
        assert.are.equal(250, a.count)
        assert.are.equal(100, #a.presets)
        assert.is_true(a.has_more)
        assert.are.equal("First 101", b.presets[1].name)
        assert.are.equal("Second 76", c.presets[1].name)
        assert.are.equal(50, #c.presets)
        assert.are.equal(250, c.count)
        assert.is_false(c.has_more)
        local past = Handler.listDevelopPresets({ offset = 300 })
        assert.are.equal(250, past.count)
        assert.are.same({}, past.presets)
        assert.is_false(past.has_more)
    end)

    it("filters names literally ignoring case and folders exactly before paging", function()
        local _, Handler = setup({ folders = {
            fakeFolder("User Presets", { fakePreset("Vibrant"), fakePreset("Moody"), fakePreset("Vivid Skies") }),
            fakeFolder("Adobe Color", { fakePreset("Vivid Color"), fakePreset("100%") }),
        }, pluginPresets = { fakePreset("Checkpoint") } })
        local names = Handler.listDevelopPresets({ query = "vI" })
        assert.are.equal(3, names.count)
        local filtered = Handler.listDevelopPresets({ query = "VI", folder = "User Presets", offset = 1, limit = 1 })
        assert.are.equal(2, filtered.count)
        assert.are.equal("Vivid Skies", filtered.presets[1].name)
        assert.is_false(filtered.has_more)
        assert.are.equal(2, Handler.listDevelopPresets({ folder = "Adobe Color" }).count)
        assert.are.equal(1, Handler.listDevelopPresets({ folder = "Plugin Develop Presets" }).count)
        assert.are.equal(1, Handler.listDevelopPresets({ query = "100%" }).count)
        for _, query in ipairs({ "%", "-", " - , " }) do
            assert.matches("has no word to search", helper.failedOf(function() Handler.listDevelopPresets({ query = query }) end),
                1, true)
        end
        for _, args in ipairs({ { query = "absent" }, { folder = "Adobe" }, { folder = "adobe color" } }) do
            local none = Handler.listDevelopPresets(args)
            assert.are.equal(0, none.count)
            assert.are.same({}, none.presets)
            assert.is_false(none.has_more)
        end
    end)

    it("matches every word of the query in the preset's folder or name, ignoring punctuation-only words", function()
        local _, Handler = setup({ folders = {
            fakeFolder("Adaptive: Sky", { fakePreset("Blue Drama") }),
            fakeFolder("User Presets", { fakePreset("Soft Portrait") }),
            fakeFolder("日本語", { fakePreset("空のドラマ") }),
        } })
        local function names(query)
            local found = {}
            for _, preset in ipairs(Handler.listDevelopPresets({ query = query }).presets) do found[#found + 1] = preset.name end
            return found
        end

        for _, query in ipairs({ "sky", "adaptive", "Adaptive Sky - Blue Drama", "drama" }) do
            assert.are.same({ "Blue Drama" }, names(query), query)
        end
        assert.are.same({}, names("sky portrait"))
        assert.are.same({ "Soft Portrait" }, names("soft"))
        assert.are.same({ "空のドラマ" }, names("空"))
        assert.are.same({}, names("雪"))
        assert.are.equal(3, Handler.listDevelopPresets({}).count)
    end)

    it("supports count-only and paging", function()
        local _, Handler = setup({ folders = { fakeFolder("A", { fakePreset("One"), fakePreset("Two") }) } })
        local count = Handler.listDevelopPresets({ limit = 0 })
        assert.are.equal(2, count.count)
        assert.are.same({}, count.presets)
        assert.is_true(count.has_more)
        local page = Handler.listDevelopPresets({ limit = 1, offset = 1 })
        assert.are.equal(1, #page.presets)
        assert.are.equal("Two", page.presets[1].name)
        assert.is_false(page.has_more)
    end)

    it("uses Lightroom case folding for non-ASCII preset names", function()
        local function lower(value)
            return (value:gsub("É", "é")):lower()
        end
        local _, Handler = setup({
            folders = { fakeFolder("A", { fakePreset("Éclat") }) },
            stringUtils = { lower = lower },
        })
        assert.are.equal(1, Handler.listDevelopPresets({ query = "éCLAT" }).count)
    end)
end)

describe("HandlerDevelop.getDevelopPreset", function()
    it("returns exact preset settings", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Exposure2012 = 0.25, ToneCurvePV2012 = { 0, 0, 255, 255 } },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { preset }) } })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.are.equal("John Warm", r.name)
        assert.are.equal("warm-1", r.uuid)
        assert.are.equal("/user/John Warm.xmp", r.file)
        assert.are.equal(2, r.setting_count)
        assert.are.same({ 0, 0, 255, 255 }, r.settings.ToneCurvePV2012)
    end)

    it("rejects ambiguous names", function()
        local folders = {
            fakeFolder("A", { fakePreset("Same", { uuid = "same-a" }) }),
            fakeFolder("B", { fakePreset("Same", { uuid = "same-b" }) }),
        }
        local _, Handler = setup({ folders = folders })

        assert.are.equal("Preset selector is ambiguous; provide preset_uuid or preset_folder", helper.failedOf(function()
            Handler.getDevelopPreset({ preset_name = "Same" })
        end))
    end)

    it("accepts a name that resolves to one aliased preset", function()
        local shared = fakePreset("Portrait", {
            uuid = "portrait-1",
            settings = { Contrast2012 = 8 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_name = "Portrait" })

        assert.are.equal("portrait-1", r.uuid)
    end)

    it("accepts duplicate Lightroom aliases selected by UUID", function()
        local shared = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Contrast2012 = 12 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.are.equal("warm-1", r.uuid)
        assert.are.equal(12, r.settings.Contrast2012)
    end)
end)

describe("HandlerDevelop.compareDevelopPresets volatile ids", function()
    local function maskedPreset(name, uuid, maskId, extra)
        return fakePreset(name, {
            uuid = uuid,
            settings = {
                Contrast2012 = extra or 10,
                MaskGroupBasedCorrections = {
                    {
                        CorrectionActive = true,
                        CorrectionMasks = { { MaskID = maskId, MaskInverted = false } },
                    },
                },
            },
        })
    end

    it("ignores the per-read CorrectionID and MaskID Lightroom regenerates", function()
        local base = maskedPreset("Masked A", "a", "mask-1")
        local candidate = maskedPreset("Masked B", "b", "mask-2")
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(0, r.changed_count)
        assert.are.same({}, r.changes)
    end)

    it("still reports a real difference inside a masked preset", function()
        local base = maskedPreset("Masked A", "a", "mask-1", 10)
        local candidate = maskedPreset("Masked B", "b", "mask-2", 40)
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(40, r.changes[1].after)
    end)

    it("strips volatile ids from the reported diff values", function()
        local base = maskedPreset("Masked A", "a", "mask-1")
        local candidate = fakePreset("Plain", {
            uuid = "b",
            settings = { Contrast2012 = 10 },
        })
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("MaskGroupBasedCorrections", r.changes[1].key)
        assert.is_true(r.changes[1].before_present)
        assert.is_false(r.changes[1].after_present)
        assert.is_nil(r.changes[1].before[1].CorrectionID)
        assert.is_nil(r.changes[1].before[1].CorrectionMasks[1].MaskID)
        assert.is_true(r.changes[1].before[1].CorrectionActive)
    end)
end)

describe("HandlerDevelop.compareDevelopPresets", function()
    it("returns deterministic setting differences", function()
        local base = fakePreset("Approved", {
            uuid = "base",
            settings = { Contrast2012 = 10, Vibrance = 5, Saturation = -2 },
        })
        local candidate = fakePreset("Candidate", {
            uuid = "candidate",
            settings = { Contrast2012 = 15, Vibrance = 5, Dehaze = 3 },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "base" },
            candidate = { preset_uuid = "candidate" },
        })

        assert.are.equal(3, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(15, r.changes[1].after)
        assert.are.equal("Dehaze", r.changes[2].key)
        assert.is_false(r.changes[2].before_present)
        assert.are.equal("Saturation", r.changes[3].key)
        assert.is_false(r.changes[3].after_present)
    end)
end)

describe("HandlerDevelop.createDevelopPreset", function()
    it("creates a versioned plugin checkpoint from explicit photo settings", function()
        local photo = helper.fakePhoto({
            id = "7",
            path = "/raw/source.nef",
            developSettings = {
                Exposure2012 = 0.5,
                Contrast2012 = 12,
                ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
                CropTop = 0.1,
                RedHue = 18,
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "7",
            preset_name = "John Warm v2",
            settings = { "Contrast2012", "ToneCurvePV2012", "RedHue" },
        })

        assert.is_false(r.visible_in_develop)
        assert.is_nil(r.source_photo_id)
        assert.is_nil(r.settings)
        assert.are.equal("plugin", r.scope)
        assert.are.equal(1, #state.pluginPresets)
        assert.are.same({
            Contrast2012 = 12,
            ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
            ExtendedToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
            RedHue = 18,
        }, state.pluginPresets[1]:getSetting())
    end)

    it("resolves the source photo OUTSIDE the read-access gate", function()
        local photo = helper.fakePhoto({
            id = "7", path = "/raw/source.nef", developSettings = { Contrast2012 = 12 },
        })
        local catalog, Handler = setup({ photos = { photo } })

        Handler.createDevelopPreset({
            photo_id = "/raw/source.nef", preset_name = "Contrast v1", settings = { "Contrast2012" },
        })

        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("captures curves Lightroom stores off the 0-255 anchors", function()
        local photo = helper.fakePhoto({
            id = "7",
            path = "/raw/source.nef",
            developSettings = {
                ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 },
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "7",
            preset_name = "Clipped v1",
            settings = { "ToneCurvePV2012" },
        })

        assert.are.same({
            ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 },
            ExtendedToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 },
        }, state.pluginPresets[1]:getSetting())
    end)

    it("captures a curve from its Extended field first, with the companion", function()
        local photo = helper.fakePhoto({ id = "7", path = "/raw/source.nef", developSettings = {
            ToneCurvePV2012 = { 0, 0, 128, 120, 255, 255 }, ExtendedToneCurvePV2012 = LONG_CURVE,
        } })
        local _, Handler, state = setup({ photos = { photo } })

        Handler.createDevelopPreset({ photo_id = "7", preset_name = "Long v1", settings = { "ToneCurvePV2012" } })

        assert.are.same({ ToneCurvePV2012 = LONG_CURVE, ExtendedToneCurvePV2012 = LONG_CURVE },
            state.pluginPresets[1]:getSetting())
    end)

    it("refuses duplicate names and missing source settings", function()
        local existing = fakePreset("Existing")
        local photo = helper.fakePhoto({
            id = "7", path = "/raw/source.nef", developSettings = { Exposure2012 = 0.5 },
        })
        local _, Handler = setup({ photos = { photo }, pluginPresets = { existing } })

        assert.are.equal("Plugin preset already exists; use a versioned preset_name", helper.failedOf(function()
            Handler.createDevelopPreset({
                photo_id = "7", preset_name = "Existing", settings = { "Exposure2012" },
            })
        end))
        assert.are.equal("Source photo has no develop setting: Contrast2012", helper.failedOf(function()
            Handler.createDevelopPreset({
                photo_id = "7", preset_name = "New", settings = { "Contrast2012" },
            })
        end))
    end)
end)

describe("HandlerDevelop.exportDevelopPreset", function()
    it("copies the backing file without overwriting", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
        })
        local _, Handler, state = setup({
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/John Warm.xmp"] = "file" },
        })

        local r = Handler.exportDevelopPreset({
            preset_uuid = "warm-1",
            destination_dir = "/exports",
            filename = "John-Warm-v2",
        })

        assert.are.equal("/exports/John-Warm-v2.xmp", r.destination)
        assert.are.equal("/user/John Warm.xmp", state.copies[1].source)
        assert.are.equal("/exports/John-Warm-v2.xmp", state.copies[1].destination)
    end)

    it("fails a copy Lightroom refused when no file reached the destination, naming its reason", function()
        local preset = fakePreset("John Warm", { uuid = "warm-1", file = "/user/Warm.xmp" })
        local _, Handler, state = setup({
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/Warm.xmp"] = "file", ["/exports"] = "directory" },
            copyFails = true,
        })

        local message = helper.failedOf(function()
            Handler.exportDevelopPreset({ preset_uuid = "warm-1", destination_dir = "/exports" })
        end)

        assert.are.equal("could not copy /user/Warm.xmp to /exports/Warm.xmp: copy refused", message)
        assert.are.same({}, state.copies)
    end)

    it("expands a leading ~/ in destination_dir", function()
        local preset = fakePreset("John Warm", { uuid = "warm-1", file = "/user/Warm.xmp" })
        local _, Handler, state = setup({
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/Warm.xmp"] = "file", ["/home/u/exports"] = "directory" },
        })

        local r = Handler.exportDevelopPreset({ preset_uuid = "warm-1", destination_dir = "~/exports" })

        assert.are.equal("/home/u/exports/Warm.xmp", r.destination)
        assert.are.equal("/home/u/exports/Warm.xmp", state.copies[1].destination)
    end)

    it("refuses path traversal, extension changes, and existing files", function()
        local preset = fakePreset("John Warm", { uuid = "warm-1", file = "/user/Warm.xmp" })
        local base = {
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/Warm.xmp"] = "file", ["/exports"] = "directory" },
        }
        local _, Handler = setup(base)

        assert.are.equal("filename must be a leaf filename without path separators", helper.failedOf(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "../escape.xmp",
            })
        end))
        assert.are.equal("filename extension must match preset backing file: .xmp", helper.failedOf(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.lrtemplate",
            })
        end))

        for _, case in ipairs({
            { dir = "exports", refusal = "destination_dir must be an absolute path" },
            { dir = "/exports/../user", refusal = "destination_dir must be written canonically" },
        }) do
            local refusal = helper.failedOf(function()
                Handler.exportDevelopPreset({ preset_uuid = "warm-1", destination_dir = case.dir })
            end)
            assert.truthy(refusal:find(case.refusal, 1, true), refusal)
        end

        base.files["/exports/Warm.xmp"] = "file"
        local _, ExistingHandler = setup(base)
        assert.are.equal("destination preset already exists; choose a new filename", helper.failedOf(function()
            ExistingHandler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.xmp",
            })
        end))
    end)
end)

describe("HandlerDevelop.applyDevelopPreset", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Vibrant")
        local catalog, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Vibrant" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("applies preset to resolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local preset = fakePreset("Vibrant")
        local folders = { fakeFolder("User", { preset }) }
        local _, Handler = setup({ photos = { p1, p2 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Vibrant" })

        assert.is_nil(r.problem)
        assert.are.equal(2, r.data.applied)
        assert.is_nil(r.warnings and r.warnings[1])
        assert.are.equal("Vibrant", r.data.preset)
        assert.are.equal("User", r.data.folder)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(preset, p2.getRawMetadata(p2, "__appliedPreset"))
    end)

    it("counts as applied only the photos the read-back verified", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local _, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { fakePreset("Vibrant") }) } })
        local context = helper.requestContext(nil, { stopping = function() return false end, timeLeft = function() return 1 end })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Vibrant" }, context)

        assert.are.equal(0, r.data.applied)
        assert.are.same({ "1", "2" }, { r.unknown[1].photo_id, r.unknown[2].photo_id })
    end)

    it("fails the photo the catalog stayed busy for, keeps the photos before it and lists the rest as remaining", function()
        local photos = {}
        for _, id in ipairs({ "1", "2", "3" }) do photos[#photos + 1] = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg" }) end
        local applies = 0
        local _, Handler = setup({
            photos = photos, folders = { fakeFolder("User", { fakePreset("Vibrant") }) },
            writeAccessAborts = function(name)
                if name ~= "Apply Develop Preset" then return false end
                applies = applies + 1
                return applies == 2
            end,
        })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2", "3" }, preset_name = "Vibrant" })

        assert.are.equal(1, r.data.applied)
        assert.are.same({ { photo_id = "2", reason = helper.catalogBusy("Apply Develop Preset") } }, r.failed)
        assert.is_nil(r.unknown)
        assert.are.same({ "3" }, r.remaining)
    end)

    it("answers unknown for a photo whose apply raised, keeps the photos before it and lists the rest as remaining", function()
        local photos = {}
        for _, id in ipairs({ "1", "2", "3" }) do photos[#photos + 1] = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg" }) end
        photos[2].applyDevelopPreset = function() error("preset file vanished", 0) end
        local _, Handler = setup({ photos = photos, folders = { fakeFolder("User", { fakePreset("Vibrant") }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2", "3" }, preset_name = "Vibrant" })

        assert.are.equal(1, r.data.applied)
        assert.is_nil(r.failed)
        assert.are.equal(1, #r.unknown)
        assert.are.equal("2", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("preset file vanished", 1, true))
        assert.are.same({ "3" }, r.remaining)
    end)

    it("skips unresolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local folders = { fakeFolder("User", { fakePreset("Moody") }) }
        local _, Handler = setup({ photos = { p1 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "missing" }, preset_name = "Moody" })

        assert.are.equal(1, r.data.applied)
        assert.are.same({ "missing" }, r.not_found)
    end)

    it("passes the plugin object when applying a plugin-managed checkpoint", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Checkpoint", { uuid = "plugin-1" })
        local _, Handler = setup({ photos = { p1 }, pluginPresets = { preset } })

        local r = Handler.applyDevelopPreset({
            photo_ids = { "1" }, preset_uuid = "plugin-1", preset_scope = "plugin",
        })

        assert.is_nil(r.problem)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(_G._PLUGIN, p1.getRawMetadata(p1, "__appliedPresetPlugin"))
    end)

    it("applies the preset once to a photo named twice, by id and by path, and names a missing id once", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "404", "2", "/a.jpg", "1", "404" }, preset_name = "Subject" })

        assert.are.equal(2, r.data.applied)
        assert.are.equal(2, r.data.ai_updated)
        assert.are.equal(1, p1.getRawMetadata(p1, "__aiUpdateCalls"))
        assert.are.same({ "404" }, r.not_found)
    end)

    it("recomputes AI masks on each target after a preset with an AI mask", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

        assert.are.equal(2, r.data.ai_updated)
        assert.is_nil(r.unknown)
        assert.are.equal(1, p1.getRawMetadata(p1, "__aiUpdateCalls"))
        assert.are.equal(1, p2.getRawMetadata(p2, "__aiUpdateCalls"))
        assert.are.equal(4, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    local pendingText = "Lightroom has not finished computing the AI masks of photo 1 within "
        .. require("Contract").AI_MASK_COMPUTE_WAIT_SECONDS .. " s, so nothing more was"
        .. " written to it. Do not write to this photo until its masks show in Develop: a write while Lightroom still"
        .. " computes can freeze Lightroom."
    for _, case in ipairs({
        { aiUpdate = "fail", reason = "Lightroom could not compute the preset's AI masks: AI update failed; " .. pendingText },
        { aiUpdate = "nothing", reason = pendingText },
        { aiUpdate = "error", reason = "Lightroom found nothing for the preset's AI masks on photo 1 (an unnamed component)" },
    }) do
        it("answers unknown for a photo whose AI masks Lightroom did not compute (" .. case.aiUpdate .. ")", function()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = case.aiUpdate })
            local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
            local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
            local _, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })

            local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

            assert.are.equal(1, r.data.applied)
            assert.are.equal(1, r.data.ai_updated)
            assert.are.same({ { photo_id = "1", reason = case.reason .. "; check the photo's AI masks in Develop before"
                .. " writing to it; written before this stopped: applyDevelopPreset, Apply Develop Preset, updateAISettings, Update AI Settings" } }, r.unknown)
            assert.is_nil(r.warnings)
            assert.are.equal(1, p2.getRawMetadata(p2, "__aiUpdateCalls"))
        end)
    end

    it("answers unknown for a photo whose masks cannot be read after the preset and goes on with the next", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })
        local guarded = package.loaded.GuardedMaskWrite
        local readEntries = guarded.readEntries
        guarded.readEntries = function(catalog, photo)
            if photo.localIdentifier == "1" and photo:getRawMetadata("__aiUpdateCalls") then
                error("Lightroom returned mask data that is not a list")
            end
            return readEntries(catalog, photo)
        end

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

        assert.are.equal(1, r.data.applied)
        assert.are.same({ { photo_id = "1", reason = "Lightroom returned mask data that is not a list; check the photo's"
            .. " AI masks in Develop before writing to it; written before this stopped: applyDevelopPreset, Apply Develop Preset, updateAISettings, Update AI Settings" } },
            r.unknown)
        assert.is_nil(r.remaining)
    end)

    it("answers a photo whose masks cannot be read before the preset as failed and keeps the photos before it", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local p3 = helper.fakePhoto({ id = "3", path = "/c.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { p1, p2, p3 }, folders = { fakeFolder("User", { preset }) } })
        local guarded = package.loaded.GuardedMaskWrite
        local readEntries = guarded.readEntries
        guarded.readEntries = function(catalog, photo)
            if photo.localIdentifier == "2" then error("Lightroom returned mask data that is not a list", 0) end
            return readEntries(catalog, photo)
        end

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2", "3" }, preset_name = "Subject" })

        assert.are.equal(1, r.data.applied)
        assert.are.same({ { photo_id = "2", reason = "Lightroom returned mask data that is not a list" } }, r.failed)
        assert.is_nil(r.unknown)
        assert.are.same({ "3" }, r.remaining)
    end)

    it("says nothing about an existing AI mask the recompute left as it was", function()
        local held = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok", developSettings = {
            MaskGroupBasedCorrections = { { CorrectionID = "kept", CorrectionMasks = { { What = "Mask/Image", MaskDigest = "own" } } } },
        } })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { held }, folders = { fakeFolder("User", { preset }) } })
        local context = helper.requestContext()

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" }, context)

        assert.are.equal(1, r.data.applied)
        assert.are.same({}, context.warnings)
    end)

    it("does not warn about a recompute when the catalog stays busy for Update AI Settings", function()
        local held = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok", developSettings = {
            MaskGroupBasedCorrections = { { CorrectionMasks = { { What = "Mask/Image", MaskDigest = "own" } } } },
        } })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({
            photos = { held },
            folders = { fakeFolder("User", { preset }) },
            writeAccessAborts = function(name) return name == "Update AI Settings" end,
        })
        local context = helper.requestContext()

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" }, context)

        assert.are.equal(0, r.data.applied)
        assert.are.same({ { photo_id = "1", reason = "Lightroom could not compute the preset's AI masks: The catalog"
            .. " stayed busy with another write for 10 s, so Lightroom did not run Update AI Settings; check the photo's"
            .. " AI masks in Develop before writing to it; written before this stopped: applyDevelopPreset, Apply Develop Preset" } }, r.unknown)
        assert.is_nil(held:getRawMetadata("__aiUpdateCalls"))
        assert.are.same({}, context.warnings)
    end)

    it("names an AI mask that was already failed before the preset and does not let it decide", function()
        local held = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok", developSettings = {
            MaskGroupBasedCorrections = {
                { CorrectionID = "own-mask",
                    CorrectionMasks = { { What = "Mask/Image", MaskDigest = "own", ErrorReason = 1 } } },
            },
        } })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { held }, folders = { fakeFolder("User", { preset }) } })
        local context = helper.requestContext()

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" }, context)

        assert.are.equal(1, r.data.applied)
        assert.is_nil(r.unknown)
        assert.are.same({ "Photo 1: mask own-mask was already failed (ErrorReason 1, no result) before this call" }, context.warnings)
    end)

    it("names, and does not judge, an existing mask the recompute failed: the preset's own entries are new ids", function()
        local developSettings = {
            MaskGroupBasedCorrections = {
                { CorrectionID = "own-mask", CorrectionMasks = { { What = "Mask/Image", MaskDigest = "own" } } },
            },
        }
        local held = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok", developSettings = developSettings })
        held.updateAISettings = function()
            for _, correction in ipairs(developSettings.MaskGroupBasedCorrections) do
                local component = correction.CorrectionMasks[1]
                if correction.CorrectionID == "own-mask" then
                    component.MaskDigest, component.ErrorReason = "own-recomputed", 1
                else
                    component.MaskDigest = "digest-1"
                end
            end
        end
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { held }, folders = { fakeFolder("User", { preset }) } })
        local context = helper.requestContext()

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" }, context)

        assert.are.equal(1, r.data.applied)
        assert.is_nil(r.unknown)
        assert.are.same({ "Photo 1: Lightroom's photo-wide AI recompute changed mask own-mask; check it" }, context.warnings)
    end)

    it("does not touch AI settings for a preset without AI masks", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local gradient = { MaskGroupBasedCorrections = { { CorrectionMasks = { { What = "Mask/Gradient" } } } } }
        local preset = fakePreset("Plain", { settings = gradient })
        local catalog, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Plain" })

        assert.are.equal(0, r.data.ai_updated)
        assert.is_nil(p1.getRawMetadata(p1, "__aiUpdateCalls"))
        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("skips the AI update when no photo resolved", function()
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = {}, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "ghost" }, preset_name = "Subject" })

        assert.are.equal(0, r.data.applied)
        assert.are.equal(0, r.data.ai_updated)
        assert.are.same({ "ghost" }, r.not_found)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

end)

describe("HandlerDevelop numeric photo ids", function()
    it("accepts the numeric ids the catalog hands out", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local set = Handler.setDevelopSettings({
            photo_id = 10,
            settings = { Exposure2012 = 0.25 },
        })
        assert.is_nil(set.problem)

        local copied = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11 } })
        assert.are.equal(1, copied.data.copied)
    end)

    it("reports target ids that matched no photo", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg", developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11, "ghost" } })

        assert.are.equal(1, r.data.copied)
        assert.are.same({ "ghost" }, r.not_found)
        assert.is_nil(r.warnings and r.warnings[1])
    end)

end)

describe("HandlerDevelop.copyDevelopSettings guards", function()
    local function photos()
        return {
            helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
                Exposure2012 = 1, orientation = "BC", MaskGroupBasedCorrections = { { What = "Correction" } },
            } }),
            helper.fakePhoto({ id = "11", path = "/t.jpg", developSettings = { orientation = "DC" } }),
        }
    end

    it("refuses a full copy whose source masks the mask-write admission refuses", function()
        local Handler = select(2, setup({
            photos = photos(),
            maskWriteAdmission = { status = function() return {} end, requireAdmitted = function()
                error("Mask writes are not certified for this Lightroom build.", 0)
            end },
        }))
        local err = helper.failedOf(function() Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } }) end)
        assert.are.equal("The source's masks cannot be copied: Mask writes are not certified for this Lightroom build."
            .. " Name the settings to copy with settings to leave masks out.", err)
    end)

    it("does not preview or copy the source's orientation", function()
        local Handler = select(2, setup({ photos = photos() }))
        local preview = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" }, dry_run = true })
        assert.is_nil(preview.setting_totals.orientation)
    end)

    it("leaves the source's FilterList out of a full copy and its preview and names its filters", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, FilterList = { Filters = {
                { Name = "Enhance", CompressedSettings = "source" }, { Name = "Reflection", CompressedSettings = "r" },
            } },
        } })
        local own = { Filters = { { Name = "Enhance", CompressedSettings = "target" } } }
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg", developSettings = { Exposure2012 = 0, FilterList = own } })
        local Handler = select(2, setup({ photos = { source, target } }))

        local previewContext = helper.requestContext()
        local preview = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" }, dry_run = true },
            previewContext)
        local context = helper.requestContext()
        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } }, context)

        assert.is_nil(preview.setting_totals.FilterList)
        assert.are.equal(1, r.data.copied)
        assert.are.equal(1, target:getDevelopSettings().Exposure2012)
        assert.is_nil(target:getRawMetadata("__appliedSettings").FilterList)
        assert.are.same(own, target:getDevelopSettings().FilterList)
        for _, warnings in ipairs({ previewContext.warnings, context.warnings }) do
            assert.are.same({ "A full copy leaves out the source's FilterList (Enhance, Reflection): Lightroom computes"
                .. " those results for each image, so each target keeps its own" }, warnings)
        end
    end)

    it("does not warn about FilterList when the source has no filters", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, FilterList = { Filters = {} },
        } })
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg" })
        local Handler = select(2, setup({ photos = { source, target } }))
        local context = helper.requestContext()

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } }, context)

        assert.are.same({}, context.warnings)
    end)
end)

describe("HandlerDevelop.copyDevelopSettings", function()
    it("names the history step on every target", function()
        local source = helper.fakePhoto({ id = "10", developSettings = { Exposure2012 = 1 } })
        local first = helper.fakePhoto({ id = "11" })
        local second = helper.fakePhoto({ id = "12" })
        local _, Handler = setup({ photos = { source, first, second } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        for _, photo in ipairs({ first, second }) do
            assert.are.equal("Copy Develop Settings", photo:getRawMetadata("__appliedHistoryName"))
            assert.is_nil(photo:getRawMetadata("__appliedFlattenAutoNow"))
        end
        assert.is_nil(source:getRawMetadata("__appliedHistoryName"))
    end)

    it("resolves targets OUTSIDE the write-access gate", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("resolves the source OUTSIDE the read-access gate", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "/s.jpg", target_ids = { "11" } })

        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("fails a target whose saved settings Lightroom does not return, writes nothing to it and copies the others", function()
        local source = helper.fakePhoto({ id = "10", developSettings = { Exposure2012 = 1 } })
        local first = helper.fakePhoto({ id = "11" })
        local unread = helper.fakePhoto({ id = "12" })
        local last = helper.fakePhoto({ id = "13" })
        unread.getDevelopSettings = function() return nil end
        local _, Handler = setup({ photos = { source, first, unread, last } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12", "13" } })

        assert.are.equal(2, r.data.copied)
        assert.is_nil(unread:getRawMetadata("__appliedSettings"))
        assert.are.same({ { photo_id = "12", reason = "Lightroom returned no saved settings for photo 12" } }, r.failed)
    end)

    it("copies all settings from source to targets", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg" })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.is_nil(r.problem)
        assert.are.equal(2, r.data.copied)
        assert.is_nil(r.warnings and r.warnings[1])
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t1.getRawMetadata(t1, "__appliedSettings")
        )
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t2.getRawMetadata(t2, "__appliedSettings")
        )
    end)

    it("filters by settings whitelist", function()
        local source = helper.fakePhoto({
            id = "20", path = "/s.jpg",
            developSettings = { Exposure2012 = 0.5, Contrast2012 = 10, Saturation = 20 },
        })
        local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "20",
            target_ids = { "21" },
            settings = { "Exposure2012", "Saturation" },
        })

        local applied = target.getRawMetadata(target, "__appliedSettings")
        assert.are.equal(0.5, applied.Exposure2012)
        assert.are.equal(20, applied.Saturation)
        assert.is_nil(applied.Contrast2012)
    end)

    for _, case in ipairs({
        { what = "a named curve", settings = { "ToneCurvePV2012" } },
        { what = "the full copy", settings = nil },
    }) do
        it("copies the source's Extended curve into both fields of the target with " .. case.what, function()
            local source = helper.fakePhoto({ id = "20", path = "/s.jpg", developSettings = {
                ToneCurvePV2012 = { 0, 0, 128, 120, 255, 255 }, ExtendedToneCurvePV2012 = LONG_CURVE,
            } })
            local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
            local _, Handler = setup({ photos = { source, target } })

            Handler.copyDevelopSettings({ source_id = "20", target_ids = { "21" }, settings = case.settings })

            local applied = target.getRawMetadata(target, "__appliedSettings")
            assert.are.same(LONG_CURVE, applied.ToneCurvePV2012)
            assert.are.same(LONG_CURVE, applied.ExtendedToneCurvePV2012)
        end)
    end

    it("copies HSL settings by whitelist", function()
        local source = helper.fakePhoto({
            id = "22", path = "/s.jpg",
            developSettings = {
                Exposure2012 = 0.5,
                HueAdjustmentOrange = -12,
                SaturationAdjustmentOrange = 18,
                LuminanceAdjustmentOrange = 7,
            },
        })
        local target = helper.fakePhoto({ id = "23", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "22",
            target_ids = { "23" },
            settings = { "HueAdjustmentOrange", "SaturationAdjustmentOrange", "LuminanceAdjustmentOrange" },
        })

        assert.are.same({
            HueAdjustmentOrange = -12,
            SaturationAdjustmentOrange = 18,
            LuminanceAdjustmentOrange = 7,
        }, target.getRawMetadata(target, "__appliedSettings"))
    end)

    it("copies once to a target named twice, by id and by path, and names a missing id once", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local _, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "404", "/t1.jpg", "11", "404" } })

        assert.are.equal(1, r.data.copied)
        assert.are.same({ "11" }, r.data.computed)
        assert.are.equal(1, t1.getRawMetadata(t1, "__aiUpdateCalls"))
        assert.are.same({ "404" }, r.not_found)
    end)

    it("recomputes AI masks on each target when the copy carries them", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "ok" })
        local catalog, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.equal(2, r.data.copied)
        assert.are.same({ "11", "12" }, r.data.computed)
        assert.are.same({
            Exposure2012 = 1.0,
            MaskGroupBasedCorrections = {
                { CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1, MaskDigest = "digest-11" } } },
            },
        }, t1:getDevelopSettings())
        assert.are.equal(1, t2.getRawMetadata(t2, "__aiUpdateCalls"))
        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("answers unknown for a target still computing at the limit and writes nothing more to it", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "nothing", developSettings = { Exposure2012 = 0 } })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.same({ "11" }, r.data.computed)
        assert.is_nil(r.failed)
        assert.are.equal("12", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("has not finished computing the AI masks of photo 12", 1, true),
            r.unknown[1].reason)
        local kept = t2:getDevelopSettings()
        assert.are.equal(0, kept.Exposure2012)
        assert.are.equal(1, #kept.MaskGroupBasedCorrections)
    end)

    it("fails a target whose copied AI mask Lightroom could not compute, restoring its masks and writing none of the settings", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "error", developSettings = { Exposure2012 = 0 } })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.equal(1, r.data.copied)
        assert.are.equal("12", r.failed[1].photo_id)
        assert.truthy(r.failed[1].reason:find("Lightroom found nothing for the copied AI masks on photo 12", 1, true),
            r.failed[1].reason)
        local kept = t2:getDevelopSettings()
        assert.are.equal(0, kept.Exposure2012)
        assert.are.same({}, kept.MaskGroupBasedCorrections or {})
    end)

    it("drops what Lightroom computed for the source's AI masks, frame fields included, so each target gets its own", function()
        local sourceSettings = {
            Exposure2012 = 1.0,
            MaskGroupBasedCorrections = {
                {
                    CorrectionName = "Mask 1",
                    CorrectionMasks = {
                        {
                            What = "Mask/Image",
                            MaskSubType = 1,
                            Origin = "619,0",
                            MaskDigest = "mask-digest",
                            InputDigest = "input-digest",
                            LocalInputDigest = "local-digest",
                        },
                        { What = "Mask/Gradient", MaskDigest = "kept-on-geometry-masks" },
                    },
                },
            },
        }
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = sourceSettings })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local _, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        local applied = t1:getDevelopSettings()
        assert.are.equal(1.0, applied.Exposure2012)
        assert.are.same({
            { What = "Mask/Image", MaskSubType = 1, MaskDigest = "digest-11" },
            { What = "Mask/Gradient", MaskDigest = "kept-on-geometry-masks" },
        }, applied.MaskGroupBasedCorrections[1].CorrectionMasks)
        assert.are.equal("Mask 1", applied.MaskGroupBasedCorrections[1].CorrectionName)
        assert.are.equal("mask-digest", sourceSettings.MaskGroupBasedCorrections[1].CorrectionMasks[1].MaskDigest)
    end)

    it("answers unknown for a target whose AI mask recompute raises and leaves its masks uncomputed, removing nothing", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "fail" })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.same({ "11" }, r.data.computed)
        assert.is_nil(r.failed)
        assert.are.equal("12", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("AI update failed", 1, true), r.unknown[1].reason)
        assert.truthy(r.unknown[1].reason:find("has not finished computing", 1, true), r.unknown[1].reason)
        assert.are.equal(1, #t2:getDevelopSettings().MaskGroupBasedCorrections)
    end)

    it("judges masks a repeat full copy writes under ids the target already holds as its own", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1.0,
            MaskGroupBasedCorrections = { { CorrectionID = "S1", CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1 } } } },
        } })
        local held = { { CorrectionID = "S1", CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1, MaskDigest = "digest-old" } } } }
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg", aiUpdate = "error", developSettings = {
            Exposure2012 = 0, MaskGroupBasedCorrections = held,
        } })
        local before = { { CorrectionID = "S1", CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1, MaskDigest = "digest-old" } } } }
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal("11", r.failed[1].photo_id)
        assert.truthy(r.failed[1].reason:find("the new masks were removed", 1, true), r.failed[1].reason)
        assert.are.same(before, target:getDevelopSettings().MaskGroupBasedCorrections)
        assert.are.equal(0, target:getDevelopSettings().Exposure2012)
    end)

    it("withholds the restore and answers unknown when an own mask has one failed and one uncomputed component", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            MaskGroupBasedCorrections = { { CorrectionMasks = {
                { What = "Mask/Image", MaskSubType = 3, MaskSubCategoryID = 13 },
                { What = "Mask/Image", MaskSubType = 0, MaskSubCategoryID = 50001 },
            } } },
        } })
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg", aiUpdate = "mixed" })
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_nil(r.failed)
        assert.are.equal("11", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("has not finished computing the AI masks of photo 11", 1, true), r.unknown[1].reason)
        local kept = target:getDevelopSettings().MaskGroupBasedCorrections
        assert.are.equal(1, #kept)
        assert.are.equal(1, kept[1].CorrectionMasks[1].ErrorReason)
        assert.is_nil(kept[1].CorrectionMasks[2].MaskDigest)
    end)

    it("does not touch AI settings when the copy has no AI masks", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = { Exposure2012 = 1.0 } })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_nil(r.data.computed)
        assert.is_nil(t1.getRawMetadata(t1, "__aiUpdateCalls"))
        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("does not touch AI settings when the whitelist drops the masks", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local _, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({
            source_id = "10", target_ids = { "11" }, settings = { "Exposure2012" },
        })

        assert.is_nil(r.data.computed)
        assert.is_nil(t1.getRawMetadata(t1, "__aiUpdateCalls"))
    end)

    it("answers not_found when the source is missing", function()
        local _, Handler = setup({ photos = {} })
        assert.are.equal("missing", helper.notFoundOf(function() Handler.copyDevelopSettings({ source_id = "missing", target_ids = { "t" } }) end))
    end)
end)

describe("HandlerDevelop.setDevelopSettingsBatch", function()
    it("writes each photo its own settings, reads all back after one wait, and answers by photo in request order", function()
        local one = helper.fakePhoto({ id = "1", path = "/1.jpg" })
        local two = helper.fakePhoto({ id = "2", path = "/2.jpg" })
        local sleeps = 0
        local _, Handler = setup({ photos = { one, two }, tasks = { pcall = pcall, sleep = function() sleeps = sleeps + 1 end } })

        local reply = Handler.setDevelopSettingsBatch({ photos = {
            { photo_id = "2", settings = { Temperature = 5200 } },
            { photo_id = "1", settings = { Exposure2012 = 0.5 } },
        } }, helper.requestContext())

        assert.are.same({ Temperature = 5200 }, two:getRawMetadata("__appliedSettings"))
        assert.are.same({ Exposure2012 = 0.5 }, one:getRawMetadata("__appliedSettings"))
        assert.are.same({ { photo_id = "2", settings = { Temperature = 5200 } }, { photo_id = "1", settings = { Exposure2012 = 0.5 } } },
            reply.data.results)
        assert.are.equal(1, sleeps)
    end)

    it("never writes a photo the server refused, answering it with the server's reason", function()
        local one = helper.fakePhoto({ id = "1", path = "/1.jpg" })
        local two = helper.fakePhoto({ id = "2", path = "/2.jpg" })
        local _, Handler = setup({ photos = { one, two } })

        local reply = Handler.setDevelopSettingsBatch({ photos = {
            { photo_id = "1", refused = "Refused before writing: GlowStyle needs Glow above 0" },
            { photo_id = "2", settings = { Exposure2012 = 0.5 } },
        } }, helper.requestContext())

        assert.is_nil(one:getRawMetadata("__appliedSettings"))
        assert.are.same({ { photo_id = "1", reason = "Refused before writing: GlowStyle needs Glow above 0" } }, reply.failed)
        assert.are.same({ { photo_id = "2", settings = { Exposure2012 = 0.5 } } }, reply.data.results)
    end)

    it("starts a photo only while the time left covers its gate wait, the read-back and the reply", function()
        local clock = { now = 0 }
        local photos = {}
        for id = 1, 3 do
            local photo = helper.fakePhoto({ id = tostring(id), path = "/" .. id .. ".jpg" })
            local apply = photo.applyDevelopSettings
            photo.applyDevelopSettings = function(self, settings)
                clock.now = clock.now + 13
                return apply(self, settings)
            end
            photos[id] = photo
        end
        local _, Handler = setup({ photos = photos, date = { currentTime = function() return clock.now end } })

        local reply = Handler.setDevelopSettingsBatch({ photos = {
            { photo_id = "1", settings = { Exposure2012 = 0.1 } },
            { photo_id = "2", settings = { Exposure2012 = 0.2 } },
            { photo_id = "3", settings = { Exposure2012 = 0.3 } },
        } }, helper.requestContext(45))

        assert.are.same({ "1", "2" }, { reply.data.results[1].photo_id, reply.data.results[2].photo_id })
        assert.are.same({ "3" }, reply.remaining)
    end)

    it("keeps the other photos' read-back when one photo's read raises, answering that one unknown", function()
        local photos = {}
        for id = 1, 3 do photos[id] = helper.fakePhoto({ id = tostring(id), path = "/" .. id .. ".jpg" }) end
        local _, Handler = setup({ photos = photos })
        local get = photos[2].getDevelopSettings
        local reads = 0
        photos[2].getDevelopSettings = function(self)
            reads = reads + 1
            if reads > 1 then error("catalog read failed", 0) end
            return get(self)
        end

        local reply = Handler.setDevelopSettingsBatch({ photos = {
            { photo_id = "1", settings = { Exposure2012 = 0.1 } },
            { photo_id = "2", settings = { Exposure2012 = 0.2 } },
            { photo_id = "3", settings = { Exposure2012 = 0.3 } },
        } }, helper.requestContext())

        assert.are.same({ "1", "3" }, { reply.data.results[1].photo_id, reply.data.results[2].photo_id })
        assert.are.equal("2", reply.unknown[1].photo_id)
        assert.matches("the read%-back failed: catalog read failed", reply.unknown[1].reason)
    end)
end)

describe("HandlerDevelop.setDevelopSettings", function()
    it("names the history step", function()
        local photo = helper.fakePhoto({ id = "1" })
        local _, Handler = setup({ photos = { photo } })

        Handler.setDevelopSettings({ photo_id = "1", settings = { Exposure2012 = 0.5 } })

        assert.are.equal("Set Develop Settings", photo:getRawMetadata("__appliedHistoryName"))
        assert.is_nil(photo:getRawMetadata("__appliedFlattenAutoNow"))
    end)

    it("resolves the photo OUTSIDE the write-access gate", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        Handler.setDevelopSettings({ photo_id = "1", settings = { Exposure2012 = 0.5 } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("applies settings to the photo", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.75, Contrast2012 = 15 },
        })

        assert.is_nil(r.problem)
        assert.are.same(
            { Exposure2012 = 0.75, Contrast2012 = 15 },
            p.getRawMetadata(p, "__appliedSettings")
        )
    end)

    it("applies HSL settings to the photo", function()
        local p = helper.fakePhoto({ id = "2", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "2",
            settings = {
                HueAdjustmentRed = -5,
                SaturationAdjustmentOrange = -20,
                LuminanceAdjustmentYellow = 12,
            },
        })

        assert.is_nil(r.problem)
        assert.are.same({
            HueAdjustmentRed = -5,
            SaturationAdjustmentOrange = -20,
            LuminanceAdjustmentYellow = 12,
        }, p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("applies RGB composite and per-channel point curves", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local composite = { 0, 0, 64, 48, 192, 210, 255, 255 }
        local red = { 0, 4, 128, 132, 255, 250 }

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = {
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = composite,
                ToneCurvePV2012Red = red,
            },
        })

        assert.is_nil(r.problem)
        local applied = p.getRawMetadata(p, "__appliedSettings")
        assert.are.same(composite, applied.ToneCurvePV2012)
        assert.are.same(red, applied.ToneCurvePV2012Red)
    end)

    it("writes each point curve with its Extended companion holding the same points", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local composite = { 0, 0, 64, 48, 192, 210, 255, 255 }
        local blue = { 0, 4, 128, 132, 255, 250 }

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { ToneCurvePV2012 = composite, ToneCurvePV2012Blue = blue } })

        assert.is_nil(r.problem)
        assert.are.same({ ToneCurvePV2012 = composite, ExtendedToneCurvePV2012 = composite,
            ToneCurvePV2012Blue = blue, ExtendedToneCurvePV2012Blue = blue }, p.getRawMetadata(p, "__appliedSettings"))
        assert.are.same(composite, r.data.settings.ToneCurvePV2012)
    end)

    it("reads back a point curve from its Extended field first, so a curve Lightroom left in place is not reported done", function()
        local held = LONG_CURVE
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg", developSettings = { ToneCurvePV2012 = { 0, 0, 255, 255 }, ExtendedToneCurvePV2012 = held } })
        local apply = p.applyDevelopSettings
        p.applyDevelopSettings = function(self, settings, ...)
            local plain = {}
            for key, value in pairs(settings) do
                if not key:find("^Extended") then plain[key] = value end
            end
            return apply(self, plain, ...)
        end
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { ToneCurvePV2012 = { 0, 0, 128, 140, 255, 255 } } })

        assert.truthy(r.problem, "expected a read-back problem")
        assert.are.same(held, r.data.settings.ToneCurvePV2012)
    end)

    it("answers not_found when the photo is missing", function()
        local _, Handler = setup({ photos = {} })
        assert.are.equal("missing", helper.notFoundOf(function() Handler.setDevelopSettings({ photo_id = "missing", settings = { Exposure2012 = 1 } }) end))
    end)
end)

-- Develop module fake for applyDenoise: one active photo, an Enhance panel per photo.
-- Photo spec: id, denoise (current amount, or nil for none), enabled (false = Denoise
-- unavailable), panel (override the panel state, e.g. a stale one).
local function denoiseSetup(opts)
    local photos, panels, outside, unselectable, settingsOf = {}, {}, {}, {}, {}
    local clock = { now = 0 }
    local pendingSaves = {}
    local reads, pendingReset = {}, nil
    local active, calls
    local function landReset(photo)
        local settings = settingsOf[photo]
        if opts.reset == "voided" then return end
        if opts.reset == "derived" then
            settings.UprightCenterNormX, settings.UprightPreview = 0.4813, true
            local masks = {}
            for index, entry in ipairs(settings.MaskGroupBasedCorrections or {}) do
                masks[index] = deepCopy(entry)
                masks[index].CorrectionMasks[1].MaskDigest = "recomputed"
            end
            settings.MaskGroupBasedCorrections = masks
            return
        end
        for key in pairs(settings) do settings[key] = nil end
    end
    local function storeDenoise(photo, amount)
        settingsOf[photo].FilterList = { Filters = { { Name = "Enhance", CompressedSettings = "d" .. amount } } }
    end
    local function saveDenoise(photo, amount)
        if opts.notSaved then return end
        if opts.savedAfter then
            pendingSaves[#pendingSaves + 1] = { photo = photo, amount = amount, at = clock.now + opts.savedAfter }
            return
        end
        storeDenoise(photo, amount)
    end
    for _, spec in ipairs(opts.photos) do
        local settings = {}
        for key, value in pairs(spec.settings or {}) do settings[key] = deepCopy(value) end
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".rw2", developSettings = settings })
        settingsOf[p] = settings
        p.getDevelopSettings = function()
            reads[#reads + 1] = { kind = "read", id = spec.id, at = clock.now }
            if opts.onRead then
                local switched = opts.onRead(spec.id, photos)
                if switched then active = switched end
            end
            if opts.nilAfterReset and calls.resetAt and calls.resetAt[spec.id] then return nil end
            if opts.nilRead and opts.nilRead[spec.id] then return nil end
            return deepCopy(settings)
        end
        if spec.denoise then
            settings.FilterList = { Filters = { { Name = "Enhance", CompressedSettings = "d" .. spec.denoise } } }
        end
        photos[#photos + 1] = p
        panels[p] = spec.panel or {
            denoiseEnabled = spec.enabled ~= false,
            denoiseState = spec.denoise ~= nil,
            denoiseAmount = spec.denoise or 50,
        }
        outside[p] = spec.outsideSource
        unselectable[p] = spec.unselectable
    end
    active = not opts.nothingSelected and photos[1] or nil
    local module = "library"
    local sources = { "folder" }
    local dropNextSelection = false
    local autoSelectPending = false
    calls = {
        selections = {}, enhance = {}, amounts = {}, switched = 0, modules = {}, sources = {}, selectNone = 0,
    }
    local Handler
    local pendingAuto, pendingAutoWhiteBalance
    local controller = {
        resetAllDevelopAdjustments = function()
            if opts.resetError then error(opts.resetError) end
            calls.resets = calls.resets or {}
            calls.resets[#calls.resets + 1] = active.localIdentifier
            calls.resetAt = calls.resetAt or {}
            calls.resetAt[active.localIdentifier] = clock.now
            reads[#reads + 1] = { kind = "reset", id = active.localIdentifier, at = clock.now }
            pendingReset = { photo = active, at = clock.now + 2 }
            if opts.onReset then opts.onReset(clock) end
        end,
        getEnhancePanelState = function()
            if module ~= "develop" or opts.panelUnavailable then return nil end
            if not active then return { denoiseEnabled = false } end
            -- Lightroom returns a fresh copy of the panel state on every call.
            local copy = {}
            for k, v in pairs(panels[active]) do copy[k] = v end
            return copy
        end,
        setEnhance = function(name, on, amount)
            if opts.enhanceError then error(opts.enhanceError) end
            calls.enhance[#calls.enhance + 1] = { id = active.localIdentifier, name = name, on = on, amount = amount }
            if opts.onEnhance then opts.onEnhance(Handler, clock) end
            if opts.enhanceIgnored then return end
            panels[active].denoiseState, panels[active].denoiseAmount = on, amount
            saveDenoise(active, amount)
        end,
        changeDenoiseAmount = function(amount)
            calls.amounts[#calls.amounts + 1] = { id = active.localIdentifier, amount = amount }
            if opts.revertIgnored and #calls.amounts > 1 then return end
            panels[active].denoiseAmount = amount
            saveDenoise(active, amount)
        end,
    }
    controller.setAutoTone = function()
        if opts.autoError then error(opts.autoError) end
        if opts.onAuto then opts.onAuto(Handler, clock) end
        if opts.autoDelay then
            pendingAuto = { photo = active, at = clock.now + opts.autoDelay }
        elseif not opts.autoUnchanged then
            settingsOf[active].Exposure2012 = 1.25
        end
        calls.autoTone = (calls.autoTone or 0) + 1
    end
    controller.setAutoWhiteBalance = function()
        if opts.autoWhiteBalanceDelay then
            pendingAutoWhiteBalance = { photo = active, at = clock.now + opts.autoWhiteBalanceDelay }
        elseif not opts.autoUnchanged then
            settingsOf[active].Temperature = 5200
            settingsOf[active].Tint = 12
        end
        calls.autoWhiteBalance = (calls.autoWhiteBalance or 0) + 1
    end
    for _, name in ipairs(opts.without or {}) do controller[name] = nil end
    local view = {
        getCurrentModuleName = function() return module end,
        switchToModule = function(name)
            if opts.stuckInModule and module == opts.stuckInModule then return end
            module = name
            calls.switched = calls.switched + 1
            calls.modules[#calls.modules + 1] = name
        end,
    }
    local tasks = {
        pcall = pcall,
        sleep = function(seconds)
            clock.now = clock.now + seconds
            if pendingReset and clock.now >= pendingReset.at then
                landReset(pendingReset.photo)
                pendingReset = nil
            end
            for index = #pendingSaves, 1, -1 do
                if clock.now >= pendingSaves[index].at then
                    storeDenoise(pendingSaves[index].photo, pendingSaves[index].amount)
                    table.remove(pendingSaves, index)
                end
            end
            if pendingAuto and clock.now >= pendingAuto.at then
                settingsOf[pendingAuto.photo].Exposure2012 = 1.25
                pendingAuto = nil
            end
            if pendingAutoWhiteBalance and clock.now >= pendingAutoWhiteBalance.at then
                settingsOf[pendingAutoWhiteBalance.photo].Temperature = 5200
                settingsOf[pendingAutoWhiteBalance.photo].Tint = 12
                pendingAutoWhiteBalance = nil
            end
            if autoSelectPending then
                autoSelectPending = false
                active = photos[1]
            end
            if opts.onSleep then
                local photo = opts.onSleep(seconds, photos)
                if photo then active = photo end
            end
        end,
    }
    local selection = {
        selectNone = function()
            active = nil
            calls.selectNone = calls.selectNone + 1
        end,
    }
    local catalog
    catalog, Handler = setup({
        photos = photos,
        developController = controller,
        applicationView = view,
        tasks = tasks,
        date = { currentTime = function() return clock.now end },
        selection = selection,
    })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        if dropNextSelection then
            dropNextSelection = false
            return
        end
        if outside[photo] and sources[1] ~= catalog.kAllPhotos then return end
        if unselectable[photo] then return end
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, newSources)
        sources = newSources
        calls.sources[#calls.sources + 1] = newSources[1]
        dropNextSelection = opts.dropSelectionAfterSourceSwitch or false
        autoSelectPending = opts.autoSelectAfterSourceSwitch or false
    end
    calls.reads = reads
    return Handler, calls, photos, clock
end

local function statuses(reply)
    local found = {}
    for _, result in ipairs(reply.data and reply.data.results or {}) do
        found[#found + 1] = result.photo_id .. ":" .. result.status
    end
    return found
end

local function reasonsOf(items)
    local found = {}
    for _, item in ipairs(items or {}) do found[#found + 1] = item.photo_id .. ":" .. item.reason end
    return found
end

describe("HandlerDevelop.resetDevelopAdjustments", function()
    local EDITED = { Exposure2012 = 0.5 }
    local LANDING_SECONDS = 2.1
    local GRADIENT = { { CorrectionID = "G1", CorrectionMasks = { { What = "Mask/Gradient", MaskDigest = "a" } } } }
    local PREPARED = {
        CropLeft = 0.124764, CropAngle = 5, PerspectiveUpright = 1, UprightCenterNormX = 0.5, Contrast2012 = 20,
        Exposure2012 = 0.5, MaskGroupBasedCorrections = GRADIENT,
    }

    local function readsAfterReset(calls, id)
        local after, resetAt = {}, nil
        for _, event in ipairs(calls.reads) do
            if event.id == id and event.kind == "reset" then resetAt = event.at end
            if event.id == id and event.kind == "read" and resetAt then after[#after + 1] = event.at - resetAt end
        end
        return after
    end

    for _, case in ipairs({
        { "tone, crop, Upright and a mask", PREPARED },
        { "only an HSL slider", { SaturationAdjustmentBlue = -40 } },
        { "only masks", { MaskGroupBasedCorrections = GRADIENT } },
        { "only spots", { RetouchAreas = { { SpotType = "heal" } } } },
        { "only the camera profile", { CameraProfile = "Adobe Standard" } },
        { "only the profile Look", { Look = { Name = "Adobe Vivid", Amount = 1, UUID = "EA1DE074F188405965EEA2D7A5D3E3E9" } } },
        { "only an Enhance filter", { FilterList = { Filters = { { Name = "Enhance", CompressedSettings = "d50" } } } } },
    }) do
        it("answers reset once one read, after Lightroom lands a reset, shows a change to " .. case[1], function()
            local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = case[2] } } })
            local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } })
            assert.are.same({ "1:reset" }, statuses(reply))
            local after = readsAfterReset(calls, "1")
            assert.are.equal(1, #after)
            assert.is_true(after[1] > LANDING_SECONDS + 0.5, tostring(after[1]))
        end)
    end

    for _, case in ipairs({
        { "Lightroom never lands the reset", "voided", PREPARED },
        { "Lightroom changes only the Upright and mask data it derives", "derived", PREPARED },
        { "the photo has no edit a reset changes", nil, {} },
    }) do
        it("answers unknown, naming the reset as written, when " .. case[1], function()
            local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = case[3] } }, reset = case[2] })
            local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } })
            assert.is_nil(reply.data)
            assert.is_nil(reply.failed)
            assert.are.equal("1", reply.unknown[1].photo_id)
            for _, text in ipairs({ "no edit", "the photo may have had nothing to reset", "read the photo before retrying",
                "written before this stopped: resetAllDevelopAdjustments" }) do
                assert.truthy(reply.unknown[1].reason:find(text, 1, true), reply.unknown[1].reason)
            end
            assert.are.equal(1, #readsAfterReset(calls, "1"))
        end)
    end

    it("answers unknown when Lightroom returns no saved settings after the reset", function()
        local Handler = denoiseSetup({ photos = { { id = "1", settings = PREPARED } }, reset = "voided", nilAfterReset = true })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } })
        assert.is_nil(reply.data)
        assert.are.equal("1", reply.unknown[1].photo_id)
        assert.truthy(reply.unknown[1].reason:find("written before this stopped: resetAllDevelopAdjustments", 1, true),
            reply.unknown[1].reason)
    end)

    it("resets no photo when another photo becomes active while it reads the photo before the reset", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1", settings = EDITED }, { id = "2", settings = EDITED } },
            onRead = function(id, photos) if id == "1" then return photos[2] end end,
        })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } })
        assert.is_nil(calls.resets)
        assert.is_nil(reply.data)
        assert.is_nil(reply.unknown)
        assert.are.same({ "1:another photo became active before the reset; nothing was reset" }, reasonsOf(reply.failed))
    end)

    it("resets each photo once, whether named by id or path, and lists unknown inputs as not_found", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = EDITED }, { id = "2", settings = EDITED } } })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1", "404", "1", "/2.rw2", "2" } })
        assert.are.same({ "1", "2" }, calls.resets)
        assert.are.same({ "1:reset", "2:reset" }, statuses(reply))
        assert.are.same({ "404" }, reply.not_found)
        assert.is_nil(reply.failed)
        assert.is_nil(reply.remaining)
        assert.are.equal("library", calls.modules[#calls.modules])
        assert.are.equal("1", calls.selections[#calls.selections])
    end)

    it("lists the unprocessed inputs as remaining when the request's budget runs out", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1", settings = EDITED }, { id = "2", settings = EDITED }, { id = "3", settings = EDITED } },
            onReset = function(clock) clock.now = clock.now + 100 end,
        })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1", 2, "3" } },
            helper.requestContext(150))
        assert.are.same({ "1" }, calls.resets)
        assert.are.same({ "1:reset" }, statuses(reply))
        assert.are.same({ 2, "3" }, reply.remaining)
    end)

    it("lists every input as remaining when the budget is spent before the first photo", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = EDITED }, { id = "2", settings = EDITED } } })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1", "2" } },
            helper.requestContext(30))
        assert.is_nil(reply.data)
        assert.are.same({ "1", "2" }, reply.remaining)
        assert.is_nil(calls.resets)
        assert.are.equal(0, calls.switched)
    end)

    it("reports an error from the reset itself as an unknown outcome and restores the view", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = EDITED } }, resetError = "reset refused" })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } })
        assert.is_nil(reply.data)
        assert.are.equal("1", reply.unknown[1].photo_id)
        assert.matches("reset refused", reply.unknown[1].reason)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)

    it("reports a photo Develop cannot select as failed and carries on", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = EDITED }, { id = "2", unselectable = true, settings = EDITED }, { id = "3", settings = EDITED } } })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "2", "3" } })
        assert.are.same({ "3" }, calls.resets)
        assert.are.same({ "3:reset" }, statuses(reply))
        assert.are.same({ "2:Could not open photo 2 in Develop" }, reasonsOf(reply.failed))
    end)

    it("reports progress that never decreases", function()
        local reports = {}
        local Handler = denoiseSetup({ photos = { { id = "1", settings = EDITED }, { id = "2", settings = EDITED }, { id = "3", settings = EDITED } } })
        Handler.resetDevelopAdjustments({ photo_ids = { "1", "2", "3", "404" } },
            helper.requestContext(nil, { report = function(_, done, total) reports[#reports + 1] = { done, total } end }))
        assert.are.same({ { 0, 3 }, { 1, 3 }, { 2, 3 }, { 3, 3 } }, reports)
    end)

    it("warns when it cannot put the user's module back", function()
        local Handler = denoiseSetup({ photos = { { id = "1", settings = EDITED } }, stuckInModule = "develop" })
        local context = helper.requestContext(nil, { title = "reset_develop_adjustments" })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } }, context)
        assert.are.same({ "1:reset" }, statuses(reply))
        assert.are.same({ "reset_develop_adjustments could not restore the view: the library module was not reopened" },
            context.warnings)
    end)

    it("lists all inputs as remaining when canceled before opening Develop", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", settings = EDITED } } })
        local reply = Handler.resetDevelopAdjustments({ photo_ids = { "1" } },
            helper.requestContext(nil, { isCanceled = function() return true end }))
        assert.are.same({ "1" }, reply.remaining)
        assert.is_nil(calls.resets)
        assert.are.equal(0, calls.switched)
    end)
end)

describe("HandlerDevelop.applyDenoise", function()
    it("fails a photo whose saved settings Lightroom does not return, before any Denoise, and goes on", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } }, nilRead = { ["2"] = true } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 45 }, helper.requestContext())

        assert.are.same({ "1:applied" }, statuses(r))
        assert.are.same({ "2:Lightroom returned no saved settings for photo 2" }, reasonsOf(r.failed))
        assert.are.same({ { id = "1", name = "denoise", on = true, amount = 45 } }, calls.enhance)
    end)

    it("cancel keeps completed denoise and restores the module and selection", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" }, { id = "3" } } })
        local context = helper.requestContext(nil, { isCanceled = function() return #calls.enhance >= 1 end })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2", "3" }, amount = 45 }, context)

        assert.are.same({ "1:applied" }, statuses(r))
        assert.are.same({ "2", "3" }, r.remaining)
        assert.are.same({ { id = "1", name = "denoise", on = true, amount = 45 } }, calls.enhance)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("switches to Develop and applies Denoise one active photo at a time", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        local context = helper.requestContext()

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 45 }, context)

        assert.are.same({ "1:applied", "2:applied" }, statuses(r))
        assert.truthy(context.warnings[1]:find("Activity Center", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({
            { id = "1", name = "denoise", on = true, amount = 45 },
            { id = "2", name = "denoise", on = true, amount = 45 },
        }, calls.enhance)
        assert.is_nil(r.remaining)
    end)

    it("rejects a second call while one is running and accepts calls afterwards", function()
        local nested
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2" } },
            onEnhance = function(handler)
                if nested == nil then
                    nested = helper.failedOf(function() handler.applyDenoise({ photo_ids = { "2" }, amount = 70 }) end)
                end
            end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.are.same({ "1:applied" }, statuses(r))
        assert.truthy(nested:find("already running", 1, true))
        assert.are.same({ { id = "1", name = "denoise", on = true, amount = 30 } }, calls.enhance)
        assert.are.same({ "2:applied" }, statuses(Handler.applyDenoise({ photo_ids = { "2" }, amount = 70 })))
    end)

    it("does not apply Denoise when another photo became active while the panel settled", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2" } },
            onSleep = function(seconds, photos)
                if seconds == 0.5 then return photos[2] end
            end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.is_nil(r.data)
        assert.truthy(r.failed[1].reason:find("another photo became active", 1, true))
        assert.are.same({}, calls.enhance)
    end)

    it("reports an apply the panel never shows as an unknown outcome", function()
        local Handler = denoiseSetup({ photos = { { id = "1" } }, enhanceIgnored = true })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.is_nil(r.data)
        assert.truthy(r.unknown[1].reason:find("did not show the new amount", 1, true))
    end)

    it("answers unknown for a change Lightroom shows but never saves, naming the amount writes even once the panel"
        .. " shows the previous amount again", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2", denoise = 40 } }, notSaved = true })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 60 })

        assert.is_nil(r.data)
        assert.is_nil(r.failed)
        assert.are.equal("1", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("Denoise state", 1, true))
        assert.are.equal("2", r.unknown[2].photo_id)
        for _, text in ipairs({ "the panel shows the previous amount 40 again", "Denoise state",
            "written before this stopped: changeDenoiseAmount" }) do
            assert.truthy(r.unknown[2].reason:find(text, 1, true), r.unknown[2].reason)
        end
        assert.are.same({ { id = "2", amount = 60 }, { id = "2", amount = 40 } }, calls.amounts)
    end)

    it("reports a Denoise change whose save lands after the timeout as unknown, not failed", function()
        local Handler = denoiseSetup({ photos = { { id = "2", denoise = 40 } }, savedAfter = 6 })

        local r = Handler.applyDenoise({ photo_ids = { "2" }, amount = 60 })

        assert.is_nil(r.failed)
        assert.are.equal("2", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("Denoise state", 1, true))
    end)

    it("reports an unsaved change whose revert the panel does not show as unknown", function()
        local Handler = denoiseSetup({ photos = { { id = "2", denoise = 40 } }, notSaved = true, revertIgnored = true })

        local r = Handler.applyDenoise({ photo_ids = { "2" }, amount = 60 })

        assert.is_nil(r.failed)
        assert.are.equal("2", r.unknown[1].photo_id)
    end)

    it("stops when the request's budget runs out and lists the inputs it did not reach", function()
        local Handler = denoiseSetup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" } },
            onEnhance = function(_, clock) clock.now = clock.now + 100 end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2", "3", "4", "404" }, amount = 30 },
            helper.requestContext(300))

        assert.are.same({ "1:applied", "2:applied", "3:applied" }, statuses(r))
        assert.are.same({ "4" }, r.remaining)
        assert.are.same({ "404" }, r.not_found)
    end)

    it("selects a photo outside the current source through All Photographs, then restores the view", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2", outsideSource = true }, { id = "3", outsideSource = true } },
            dropSelectionAfterSourceSwitch = true,
        })

        local r = Handler.applyDenoise({ photo_ids = { "2", "3" }, amount = 30 })

        assert.are.same({ "2:applied", "3:applied" }, statuses(r))
        assert.are.same({ "all photographs", "folder" }, calls.sources)
        assert.are.same({ "2", "3", "1" }, calls.selections)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("clears the selection again when nothing was selected", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, nothingSelected = true })

        assert.are.same({ "1:applied" }, statuses(Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })))
        assert.are.equal(1, calls.selectNone)
    end)

    it("clears the selection again after Lightroom auto-selects a photo in the restored source", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2", outsideSource = true } },
            nothingSelected = true,
            autoSelectAfterSourceSwitch = true,
        })

        assert.are.same({ "2:applied" }, statuses(Handler.applyDenoise({ photo_ids = { "2" }, amount = 30 })))
        assert.are.same({ "all photographs", "folder" }, calls.sources)
        assert.are.equal(2, calls.selectNone)
    end)

    it("refuses without effect, restores the view and releases the run when Develop fails to open", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, panelUnavailable = true })

        local refusal = helper.failedOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)

        assert.are.equal("Develop module did not open", refusal)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_nil(helper.failedOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)
            :find("already running", 1, true))
    end)

    it("refuses on a Lightroom without the Enhance panel calls before touching Develop", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, without = { "changeDenoiseAmount" } })

        local err = helper.failedOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)

        assert.truthy(err:find("needs LrDevelopController.changeDenoiseAmount", 1, true))
        assert.are.equal(0, calls.switched)
    end)

    it("puts the user's selection back unless restore_selection is false", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        Handler.applyDenoise({ photo_ids = { "2" }, amount = 30 })
        assert.are.same({ "2", "1" }, calls.selections)

        local Handler2, calls2 = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        Handler2.applyDenoise({ photo_ids = { "2" }, amount = 30, restore_selection = false })
        assert.are.same({ "2" }, calls2.selections)
    end)

    it("leaves photos at the amount alone and changes a different amount", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", denoise = 30 }, { id = "2", denoise = 50 } } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 30 })

        assert.are.same({ "1:unchanged", "2:amount_changed" }, statuses(r))
        assert.are.equal(50, r.data.results[2].previous_amount)
        assert.are.same({ { id = "2", amount = 30 } }, calls.amounts)
        assert.are.same({}, calls.enhance)
    end)

    it("trusts the photo's own settings over a panel still showing the previous photo", function()
        local stale = { denoiseEnabled = true, denoiseState = true, denoiseAmount = 30 }
        local Handler, calls = denoiseSetup({ photos = { { id = "1", panel = stale } } })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.are.same({ "1:applied" }, statuses(r))
        assert.are.equal(1, #calls.enhance)
    end)

    it("refuses photos Denoise does not support and lists missing photos as not_found", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", enabled = false } } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "404" }, amount = 40 })

        assert.are.same({ "1:Denoise is not available for this photo" }, reasonsOf(r.failed))
        assert.are.same({ "404" }, r.not_found)
        assert.are.same({}, calls.enhance)
    end)

    it("reports a Develop error per photo as an unknown outcome and carries on", function()
        local Handler = denoiseSetup({ photos = { { id = "1" }, { id = "2" } }, enhanceError = "panel busy" })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 45 })

        assert.are.equal(2, #r.unknown)
        assert.truthy(r.unknown[1].reason:find("panel busy", 1, true))
    end)

end)

local function processVersionSetup(opts)
    opts = opts or {}
    local photos = {
        helper.fakePhoto({ id = "1", path = "/1.raw", developSettings = opts.settings1 }),
        helper.fakePhoto({ id = "2", path = "/2.raw", developSettings = opts.settings2 }),
    }
    local active, selected, module, sources = photos[1], { photos[1] }, "library", { "folder" }
    local versions, calls, now = { [photos[1]] = "Version 5", [photos[2]] = "Version 6" }, {}, 0
    local catalog, Handler = setup({
        photos = photos,
        applicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name) module = name end,
        },
        developController = {
            getProcessVersion = not opts.withoutSetter and function() return versions[active] end or nil,
            setProcessVersion = not opts.withoutSetter and function(version)
                calls[#calls + 1] = active.localIdentifier
                if not opts.ignored then versions[active] = version end
                now = now + (opts.cost or 0)
            end or nil,
        },
        date = { currentTime = function() return now end },
        tasks = { pcall = pcall, sleep = function(seconds) now = now + seconds end },
    })
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, value) sources = value end
    catalog.setSelectedPhotos = function(_, photo, selection) active, selected = photo, selection end
    return Handler, calls, function() return module, active.localIdentifier, sources[1] end
end

describe("HandlerDevelop.applyDenoise on a Lightroom without the Denoise functions", function()
    it("refuses, naming the missing function as outside the SDK", function()
        local Handler = denoiseSetup({ photos = { { id = "1" } }, without = { "getEnhancePanelState" } })

        assert.are.equal("apply_denoise needs LrDevelopController.getEnhancePanelState, a function outside the Lightroom SDK"
            .. " that this Lightroom does not offer",
            helper.failedOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end))
    end)
end)

describe("HandlerDevelop.setProcessVersion", function()
    it("reports previous and actual versions and leaves unchanged photos alone", function()
        local Handler, calls, view = processVersionSetup()
        local reply = Handler.setProcessVersion({ photo_ids = { "1", "2", "/1.raw", "missing" }, version = "Version 6" })
        assert.are.same({ "1" }, calls)
        assert.are.same({ "1:changed", "2:unchanged" }, statuses(reply))
        assert.are.equal("Version 5", reply.data.results[1].previous_version)
        assert.are.equal("Version 6", reply.data.results[1].new_version)
        assert.are.same({ "missing" }, reply.not_found)
        assert.is_nil(reply.failed)
        local module, active, source = view()
        assert.are.equal("library", module)
        assert.are.equal("1", active)
        assert.are.equal("folder", source)
    end)

    it("refuses masked-photo downgrades as failed before any setter call", function()
        local Handler, calls, view = processVersionSetup({ settings2 = { MaskGroupBasedCorrections = { { CorrectionMasks = {} } } } })
        local reply = Handler.setProcessVersion({ photo_ids = { "2" }, version = "Version 5" })
        assert.is_nil(reply.data)
        assert.are.equal("2", reply.failed[1].photo_id)
        assert.truthy(reply.failed[1].reason:find("downgrades are refused", 1, true))
        assert.are.equal(0, #calls)
        assert.are.equal("library", view())
    end)

    it("still upgrades masked photos and downgrades photos without masks", function()
        local Handler, calls = processVersionSetup({ settings1 = { MaskGroupBasedCorrections = { {} } } })
        assert.are.same({ "1:changed" },
            statuses(Handler.setProcessVersion({ photo_ids = { "1" }, version = "Version 6" })))
        assert.are.same({ "2:changed" },
            statuses(Handler.setProcessVersion({ photo_ids = { "2" }, version = "Version 4" })))
        assert.are.same({ "1", "2" }, calls)
    end)

    it("continues an unmasked batch after refusing a masked downgrade", function()
        local Handler, calls = processVersionSetup({ settings2 = { MaskGroupBasedCorrections = { {} } } })
        local reply = Handler.setProcessVersion({ photo_ids = { "2", "1" }, version = "Version 4" })
        assert.are.equal(1, #reply.failed)
        assert.are.same({ "1:changed" }, statuses(reply))
        assert.are.same({ "1" }, calls)
    end)

    it("retains completed changes and lists remaining inputs when the request's budget runs out", function()
        local Handler = processVersionSetup({ cost = 100 })
        local reply = Handler.setProcessVersion({ photo_ids = { "1", "2" }, version = "Version 6" },
            helper.requestContext(120))
        assert.are.same({ "1:changed" }, statuses(reply))
        assert.are.same({ "2" }, reply.remaining)
    end)

    it("cancellation lists all unvisited inputs as remaining", function()
        local Handler, calls = processVersionSetup()
        local reply = Handler.setProcessVersion({ photo_ids = { "1", "2" }, version = "Version 6" },
            helper.requestContext(nil, { isCanceled = function() return true end }))
        assert.are.same({ "1", "2" }, reply.remaining)
        assert.are.equal(0, #calls)
    end)

    it("reports an unconfirmed change as an unknown outcome naming the version read back, and restores the view", function()
        local Handler, _, view = processVersionSetup({ ignored = true })
        local reply = Handler.setProcessVersion({ photo_ids = { "1" }, version = "Version 6" })
        assert.is_nil(reply.data)
        assert.are.equal("1", reply.unknown[1].photo_id)
        assert.truthy(reply.unknown[1].reason:find("did not confirm", 1, true))
        assert.truthy(reply.unknown[1].reason:find("Version 5", 1, true))
        assert.are.equal("library", view())
    end)
end)

describe("HandlerDevelop.applyAutoAdjustments", function()
    it("applies requested operations and restores the module and selected photo", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        local reply = Handler.applyAutoAdjustments({ photo_ids = { "2", "1" }, tone = true, white_balance = true })
        assert.are.same({ "2:applied", "1:applied" }, statuses(reply))
        assert.are.equal(2, calls.autoTone)
        assert.are.equal(2, calls.autoWhiteBalance)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.equal("1", calls.selections[#calls.selections])
    end)

    it("does not apply white balance when only tone is requested", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        assert.are.same({ "1:applied" }, statuses(Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })))
        assert.is_nil(calls.autoWhiteBalance)
    end)

    it("does not apply tone when only white balance is requested", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        assert.are.same({ "1:applied" },
            statuses(Handler.applyAutoAdjustments({ photo_ids = { "1" }, white_balance = true })))
        assert.is_nil(calls.autoTone)
    end)

    it("waits for a delayed Auto result before selecting another photo", function()
        local Handler = denoiseSetup({ photos = { { id = "1" }, { id = "2" } }, autoDelay = 3 })
        local reply = Handler.applyAutoAdjustments({ photo_ids = { "1", "2" }, tone = true })
        assert.are.same({ "1:applied", "2:applied" }, statuses(reply))
    end)

    for _, delay in ipairs({ "autoDelay", "autoWhiteBalanceDelay" }) do
        it("settles both operations before moving on with " .. delay, function()
            local opts = { photos = { { id = "1" }, { id = "2" } } }
            opts[delay] = 3
            local Handler, _, photos = denoiseSetup(opts)
            local reply = Handler.applyAutoAdjustments({ photo_ids = { "1", "2" }, tone = true, white_balance = true })
            assert.are.same({ "1:applied", "2:applied" }, statuses(reply))
            for _, photo in ipairs(photos) do
                local settings = photo:getDevelopSettings()
                assert.are.equal(1.25, settings.Exposure2012)
                assert.are.equal(5200, settings.Temperature)
            end
        end)
    end

    for _, case in ipairs({
        { args = { tone = true }, names = "Auto Tone" },
        { args = { white_balance = true }, names = "Auto White Balance" },
    }) do
        it("answers unknown when " .. case.names .. " shows no change within the wait, and lists missing photos",
            function()
            local Handler = denoiseSetup({ photos = { { id = "1" } }, autoUnchanged = true })
            local args = { photo_ids = { "1", "404", "1" } }
            for key, value in pairs(case.args) do args[key] = value end
            local reply = Handler.applyAutoAdjustments(args)
            assert.are.same({}, statuses(reply))
            assert.are.equal("1", reply.unknown[1].photo_id)
            assert.are.equal(case.names .. " was requested but no change was observed within 8 s; it may still be"
                .. " applied, so read this photo's settings before writing to it; written before this stopped: "
                .. (case.args.tone and "setAutoTone" or "setAutoWhiteBalance"), reply.unknown[1].reason)
            assert.are.same({ "404" }, reply.not_found)
        end)
    end

    it("lists the unreached inputs as remaining when the request's budget runs out after the first photo", function()
        local Handler = denoiseSetup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" } },
            onAuto = function(_, clock) clock.now = clock.now + 100 end,
        })
        local reply = Handler.applyAutoAdjustments({ photo_ids = { "1", "2", "3" }, tone = true },
            helper.requestContext(150))
        assert.are.same({ "1:applied" }, statuses(reply))
        assert.are.same({ "2", "3" }, reply.remaining)
    end)

    it("stops at the next photo when the request is cancelled", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" }, { id = "3" } } })
        local cancelled = false
        local reply = Handler.applyAutoAdjustments({ photo_ids = { "1", "2", "3" }, tone = true },
            helper.requestContext(nil, { isCanceled = function()
                local now = cancelled
                cancelled = true
                return now
            end }))
        assert.are.same({ "1:applied" }, statuses(reply))
        assert.are.same({ "2", "3" }, reply.remaining)
        assert.are.equal(1, calls.autoTone)
    end)

    it("rejects overlap through the shared Develop session lock", function()
        local nested
        local Handler = denoiseSetup({ photos = { { id = "1" } }, onAuto = function(handler)
            nested = helper.failedOf(function()
                handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })
            end)
        end })
        assert.are.same({ "1:applied" }, statuses(Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })))
        assert.truthy(nested:find("is already running", 1, true))
    end)

    it("reports an SDK failure as an unknown outcome and restores the view, releasing the lock", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, autoError = "Auto failed" })
        local reply = Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })
        assert.are.equal("1", reply.unknown[1].photo_id)
        assert.truthy(reply.unknown[1].reason:find("Auto failed", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "1:applied" },
            statuses(Handler.applyAutoAdjustments({ photo_ids = { "1" }, white_balance = true })))
    end)

end)

describe("HandlerDevelop batch dry runs", function()
    it("previews changed values, unchanged targets and missing ids without writes", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5, Contrast2012 = 10 } })
        local target = helper.fakePhoto({ id = "1002", developSettings = { Exposure2012 = 0, Contrast2012 = 10 } })
        local identical = helper.fakePhoto({ id = "1003", developSettings = { Exposure2012 = 0.5 } })
        local catalog, Handler = setup({ photos = { source, target, identical } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.applyDevelopSettings = function() error("dry run applied") end
        local r = Handler.copyDevelopSettings({
            source_id = "1001", target_ids = { "1002", "1003", "missing" }, settings = { "Exposure2012" }, dry_run = true,
        })
        assert.are.same({ { key = "Exposure2012", before = 0, after = 0.5,
            before_present = true, after_present = true } }, r.details[1].changes)
        assert.are.same({}, r.details[2].changes)
        assert.are.same({ Exposure2012 = 1 }, r.setting_totals)
        assert.are.same({ "missing" }, r.missing)
        assert.are.equal(2, r.targets)
        assert.are.equal(1, r.changed_targets)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("previews preset keys only and never applies or recomputes AI masks", function()
        local target = helper.fakePhoto({ id = "1002", developSettings = { Exposure2012 = 0, Contrast2012 = 10 } })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.applyDevelopPreset = function() error("dry run applied") end
        target.updateAISettings = function() error("dry run recomputed") end
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002", "missing" }, preset_name = "Subject", dry_run = true })
        assert.are.equal(1, r.setting_totals.Exposure2012)
        assert.is_nil(r.setting_totals.Contrast2012)
        assert.are.same({ "missing" }, r.missing)
    end)

    it("omits equal preset scalars and curves", function()
        local settings = { Exposure2012 = 0.5, ToneCurvePV2012 = { 0, 0, 255, 255 } }
        local target = helper.fakePhoto({ id = "1002", developSettings = settings })
        local preset = fakePreset("Equal", { settings = settings })
        local _, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002" }, preset_name = "Equal", dry_run = true })
        assert.are.same({}, r.details[1].changes)
        assert.are.same({}, r.setting_totals)
        assert.are.equal(0, r.changed_targets)
    end)

    it("limits preset diffs to readable declared keys and reports unknown effects", function()
        local preset = fakePreset("Heavy", { settings = {
            GrainAmount = 92, GrainFrequency = 40, GrainSize = 39, Glow = 0, Version = "18.7",
        } })
        local first = helper.fakePhoto({ id = "1002", developSettings = {
            GrainAmount = 0, GrainFrequency = 50, GrainSize = 25,
        } })
        local second = helper.fakePhoto({ id = "1003", developSettings = {
            GrainAmount = 92, GrainFrequency = 40, GrainSize = 39, Glow = 0,
        } })
        local catalog, Handler = setup({ photos = { first, second }, folders = { fakeFolder("Grain", { preset }) } })
        catalog.withWriteAccessDo = function() error("preset preview wrote") end
        first.applyDevelopPreset = function() error("preset preview applied") end
        first.updateAISettings = function() error("preset preview recomputed") end
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002", "1003" }, preset_name = "Heavy", dry_run = true })
        assert.are.equal("readable_declared_preset_settings", r.preview_scope)
        assert.are.same({ Glow = 1, Version = 2 }, r.unknown_current_totals)
        assert.are.same({ GrainAmount = 1, GrainFrequency = 1, GrainSize = 1 }, r.setting_totals)
        assert.are.equal(3, #r.details[1].changes)
        assert.are.same({}, r.details[2].changes)
        assert.are.equal(1, r.changed_targets)
        assert.are.same({ "SDK-generated values, including GrainSeed", "Preset bookkeeping" }, r.unknown_effects)
        assert.is_nil(r.setting_totals.GrainSeed)
        assert.is_nil(r.setting_totals.Preset)
    end)

    it("keeps unknown preset values separate from unchanged values on all targets", function()
        local preset = fakePreset("Unknown", { settings = { Glow = 0 } })
        local target = helper.fakePhoto({ id = "1002" })
        local _, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002" }, preset_name = "Unknown", dry_run = true })
        assert.are.same({}, r.details[1].changes)
        assert.are.same({ Glow = 1 }, r.unknown_current_totals)
        assert.are.equal(0, r.changed_targets)
    end)

    it("still previews copied settings whose current value is absent", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5 } })
        local target = helper.fakePhoto({ id = "1002" })
        local _, Handler = setup({ photos = { source, target } })
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })
        assert.are.equal(1, r.setting_totals.Exposure2012)
        assert.is_false(r.details[1].changes[1].before_present)
        assert.is_nil(r.preview_scope)
        assert.is_nil(r.unknown_current_totals)
        assert.is_nil(r.unknown_effects)
    end)

    it("lists the process version a full copy carries when source and target differ", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { ProcessVersion = "15.4", Exposure2012 = 0.5 } })
        local target = helper.fakePhoto({ id = "1002", developSettings = { ProcessVersion = "11.0", Exposure2012 = 0.5 } })
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })

        assert.are.same({ ProcessVersion = 1 }, r.setting_totals)
        assert.are.same({ key = "ProcessVersion", before_present = true, after_present = true, before = "11.0", after = "15.4" },
            r.details[1].changes[1])
    end)

    it("does not recompute or write copied AI masks", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = AI_MASK_SETTINGS })
        local target = helper.fakePhoto({ id = "1002" })
        local catalog, Handler = setup({ photos = { source, target } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.updateAISettings = function() error("dry run recomputed") end
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })
        assert.are.equal(1, r.setting_totals.MaskGroupBasedCorrections)
    end)

    it("previews the mask replacement and removal a full copy writes, per target", function()
        local masked = { MaskGroupBasedCorrections = { { CorrectionMasks = { { What = "Mask/Gradient" } } } } }
        local cases = {
            { name = "a source without masks removes a target's", source = {}, target = masked, before = 1, after = 0 },
            { name = "a source's masks replace a target without", source = masked, target = {}, before = 0, after = 1 },
            { name = "neither side has masks", source = {}, target = {} },
        }
        for _, case in ipairs(cases) do
            local source = helper.fakePhoto({ id = "1001", developSettings = case.source })
            local target = helper.fakePhoto({ id = "1002", developSettings = case.target })
            local _, Handler = setup({ photos = { source, target } })

            local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })

            local change = r.details[1].changes[1]
            if case.before then
                assert.are.equal(1, r.setting_totals.MaskGroupBasedCorrections, case.name)
                assert.are.equal("MaskGroupBasedCorrections", change.key, case.name)
                assert.are.same({ type = "table", entries = case.before }, change.before, case.name)
                assert.are.same({ type = "table", entries = case.after }, change.after, case.name)
            else
                assert.is_nil(change, case.name)
                assert.are.equal(0, r.changed_targets, case.name)
            end
        end
    end)

    it("refuses an unknown preset in both modes", function()
        local source = helper.fakePhoto({ id = "1001" })
        local _, Handler = setup({ photos = { source } })
        for _, dryRun in ipairs({ false, true }) do
            assert.are.equal("Preset not found", helper.failedOf(function()
                Handler.applyDevelopPreset({ photo_ids = { "1001" }, preset_name = "Unknown", dry_run = dryRun })
            end))
        end
    end)

    it("bounds missing paths while retaining every missing input index", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5 } })
        local _, Handler = setup({ photos = { source } })
        local ids = {}
        for i = 1, 200 do ids[i] = "/missing/" .. string.rep("a", 200) .. tostring(i) .. ".jpg" end
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = ids, dry_run = true })
        assert.is_true(#require('JSON'):encode(r) <= 20000)
        assert.are.equal(200, r.missing_count)
        assert.are.equal(200, #r.missing_indices)
        assert.is_true(r.missing_truncated)
        assert.is_true(#r.missing < 200)
        for i, id in ipairs(r.missing) do assert.are.equal(ids[i], id) end
        for i, index in ipairs(r.missing_indices) do assert.are.equal(i, index) end
    end)

    it("bounds 200-target detail and totals every target", function()
        local settings = { Exposure2012 = 0.5, ToneCurvePV2012 = { 0, 0, 255, 255 } }
        local source = helper.fakePhoto({ id = "1001", developSettings = settings })
        local photos, ids = { source }, {}
        for i = 1, 200 do
            ids[i] = tostring(i)
            photos[#photos + 1] = helper.fakePhoto({ id = ids[i], developSettings = { Exposure2012 = 0 } })
        end
        local _, Handler = setup({ photos = photos })
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = ids, dry_run = true })
        assert.is_true(#require('JSON'):encode(r) <= 20000)
        assert.are.equal(5, #r.details)
        assert.is_true(r.detail_truncated)
        assert.are.equal(200, r.setting_totals.Exposure2012)
        assert.are.equal(200, r.setting_totals.ToneCurvePV2012)
        assert.are.same({ type = "table", entries = 4 }, r.details[1].changes[2].after)
    end)
end)

describe("develop writes read back after Lightroom normalises them", function()
    local function storingPhoto(id, stored, normalise)
        local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg", developSettings = stored })
        photo.applyDevelopSettings = function(_, settings)
            if normalise and normalise.throws and not normalise.storesFirst then error(normalise.throws) end
            for key, value in pairs(settings) do
                if normalise and normalise[key] ~= nil then value = normalise[key] end
                if normalise and (normalise.drops == key or type(normalise.drops) == "table" and normalise.drops[key]) then
                    value = nil
                end
                if key:find("^Extended") then value = nil end
                stored[key] = value
            end
            if normalise and normalise.throws then error(normalise.throws) end
        end
        return photo
    end

    local function sleeps()
        local slept = {}
        return { sleep = function(seconds) slept[#slept + 1] = seconds end, pcall = pcall }, slept
    end

    it("answers done with the stored values when Lightroom kept what was written, after waiting for it", function()
        local tasks, slept = sleeps()
        local _, Handler = setup({ photos = { storingPhoto("1", {}) }, tasks = tasks })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { Exposure2012 = 0.33, Contrast2012 = 10 } })

        assert.are.same({ photo_id = "1", settings = { Exposure2012 = 0.33, Contrast2012 = 10 } }, r.data)
        assert.is_nil(r.problem)
        assert.is_nil(r.unknown)
        assert.are.same({ 1 }, slept)
    end)

    it("reports a value Lightroom stored differently as adjusted, which makes the outcome partial", function()
        local _, Handler = setup({ photos = { storingPhoto("1", {}, { Contrast2012 = 0 }) }, tasks = sleeps() })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { Contrast2012 = 100, Exposure2012 = 1 } })

        assert.are.same({ { photo_id = "1", key = "Contrast2012", requested = 100, stored = 0 } }, r.data.adjusted)
        assert.truthy(r.problem:find("Contrast2012", 1, true))
    end)

    it("names a table value Lightroom stored differently by its contents", function()
        local _, Handler = setup({ photos = { storingPhoto("1", {}, { ToneCurvePV2012 = { 0, 0, 255, 255 } }) }, tasks = sleeps() })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { ToneCurvePV2012 = { 0, 0, 128, 140, 255, 255 } } })

        assert.truthy(r.problem:find("ToneCurvePV2012 [0,0,255,255] on photo 1 (written [0,0,128,140,255,255])", 1, true), r.problem)
    end)

    it("reports a key the photo held before and Lightroom does not show after the write as unknown", function()
        local _, Handler = setup({ photos = { storingPhoto("1", { Temperature = 5000 }, { drops = "Temperature" }) },
            tasks = sleeps() })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { Temperature = 200 } })

        assert.are.equal("1", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("Temperature", 1, true))
        assert.is_nil(r.data.not_stored)
    end)

    local JPEG_DROPS = { drops = { Temperature = true, Tint = true } }

    it("answers done and names the keys a photo stores neither before nor after the write", function()
        local _, Handler = setup({ photos = { storingPhoto("1", { Exposure2012 = 0 }, JPEG_DROPS) }, tasks = sleeps() })

        local r = Handler.setDevelopSettings({ photo_id = "1", settings = { Temperature = 5500, Tint = 10, Exposure2012 = 0.5 } })

        assert.is_nil(r.unknown)
        assert.is_nil(r.problem)
        assert.are.same({ { photo_id = "1", keys = { "Temperature", "Tint" } } }, r.data.not_stored)
        assert.are.same({ "Lightroom stores no Temperature, Tint for photo 1" }, r.warnings)
    end)

    it("copies a raw's look onto a JPEG whole and names the white balance the JPEG does not store", function()
        local raw = storingPhoto("10", { Exposure2012 = 1, Temperature = 5200, Tint = 8 })
        local jpeg = storingPhoto("11", { Exposure2012 = 0 }, JPEG_DROPS)
        local _, Handler = setup({ photos = { raw, jpeg }, tasks = sleeps() })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal(1, r.data.copied)
        assert.is_nil(r.unknown)
        assert.are.same({ { photo_id = "11", keys = { "Temperature", "Tint" } } }, r.data.not_stored)
        assert.are.same({ "Lightroom stores no Temperature, Tint for photo 11" }, r.warnings)
    end)

    it("fails a copy target that throws before Lightroom stored anything, proven by the read-back", function()
        local source = storingPhoto("10", { Exposure2012 = 1, Contrast2012 = 20 })
        local kept = storingPhoto("11", { Exposure2012 = 0 })
        local broken = storingPhoto("12", { Exposure2012 = 0 }, { throws = "cannot write this photo" })
        local _, Handler = setup({ photos = { source, kept, broken }, tasks = sleeps() })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" }, settings = { "Exposure2012" } })

        assert.are.equal(1, r.data.copied)
        assert.are.equal("12", r.failed[1].photo_id)
        assert.truthy(r.failed[1].reason:find("cannot write this photo", 1, true))
        assert.is_nil(r.unknown)
        assert.is_nil(r.data.adjusted)
    end)

    it("answers unknown for a copy target that throws after Lightroom stored part of the settings", function()
        local source = storingPhoto("10", { Exposure2012 = 1, Contrast2012 = 20 })
        local broken = storingPhoto("12", { Exposure2012 = 0, Contrast2012 = 0 },
            { throws = "cannot finish this photo", storesFirst = true })
        local _, Handler = setup({ photos = { source, broken }, tasks = sleeps() })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "12" }, settings = { "Exposure2012", "Contrast2012" } })

        assert.is_nil(r.failed)
        assert.are.equal("12", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("cannot finish this photo", 1, true))
    end)

    it("reads a preset's keys back on every photo it was applied to", function()
        local preset = fakePreset("Bright", { settings = { Exposure2012 = 0.5 } })
        local photo = storingPhoto("1", {}, { Exposure2012 = 0.4 })
        photo.applyDevelopPreset = function() photo:applyDevelopSettings({ Exposure2012 = 0.5 }) end
        local _, Handler = setup({ photos = { photo }, folders = { fakeFolder("User", { preset }) }, tasks = sleeps() })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Bright" })

        assert.are.same({ { photo_id = "1", key = "Exposure2012", requested = 0.5, stored = 0.4 } }, r.data.adjusted)
    end)
end)

describe("copy replies carry data only for the copies their read-back confirmed", function()
    local JSON = require 'JSON'
    local Reply = require 'Reply'

    local function storingPhoto(id, stored, normalise)
        local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg", developSettings = stored })
        photo.applyDevelopSettings = function(_, settings)
            if normalise and normalise.throws then error(normalise.throws, 0) end
            for key, value in pairs(settings) do
                if normalise and normalise[key] ~= nil then value = normalise[key] end
                if normalise and normalise.drops and normalise.drops[key] then value = nil end
                stored[key] = value
            end
        end
        return photo
    end

    local function source()
        return storingPhoto("10", { Exposure2012 = 1, Contrast2012 = 20 })
    end

    local function wire(photos, args, opts)
        opts = opts or {}
        local _, Handler = setup({ photos = photos, writeAccessAborts = opts.aborts,
            tasks = { sleep = function() end, pcall = pcall } })
        local asked = 0
        local context = helper.requestContext(nil, opts.stopAfter and { stopping = function()
            asked = asked + 1
            return asked > opts.stopAfter
        end } or nil)
        local ok, value = pcall(Handler.copyDevelopSettings, args, context)
        local reply = Reply.outcome(ok, value, context)
        return JSON:decode(JSON:encode(reply))
    end

    local named = { "Exposure2012", "Contrast2012" }
    local cases = {
        ["all refused"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0 }) }, { source_id = "10", target_ids = { "11" }, settings = named },
                { aborts = function(name) return name == "Copy Develop Settings" end })
        end,
        ["mixed"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0 }), storingPhoto("12", { Exposure2012 = 0 }, { throws = "cannot write this photo" }) },
                { source_id = "10", target_ids = { "11", "12" }, settings = named })
        end,
        ["unknown read-back"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0, Contrast2012 = 0 }, { drops = { Contrast2012 = true } }) },
                { source_id = "10", target_ids = { "11" }, settings = named })
        end,
        ["unknown and adjusted on one target"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0, Contrast2012 = 0 }, { drops = { Contrast2012 = true }, Exposure2012 = 0.95 }) },
                { source_id = "10", target_ids = { "11" }, settings = named })
        end,
        ["all not found"] = function()
            return wire({ source() }, { source_id = "10", target_ids = { "404", "/missing.jpg" }, settings = named })
        end,
        ["budget exhausted"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0 }) }, { source_id = "10", target_ids = { "11" }, settings = named },
                { stopAfter = 0 })
        end,
        ["confirmed and remaining"] = function()
            return wire({ source(), storingPhoto("11", { Exposure2012 = 0 }), storingPhoto("12", { Exposure2012 = 0 }) },
                { source_id = "10", target_ids = { "11", "12" }, settings = named }, { stopAfter = 1 })
        end,
    }

    local file = assert(io.open("server/tests/fixtures/copy-replies.json", "r"))
    local fixture = JSON:decode(file:read("*a"))
    file:close()

    for _, expected in ipairs(fixture) do
        it("answers the shared fixture's " .. expected.case .. " reply", function()
            assert.are.same(expected.reply, cases[expected.case]())
        end)
    end

    it("names every adjusted value in the error when no copy was confirmed", function()
        local photos, ids = { source() }, {}
        for index = 11, 21 do
            photos[#photos + 1] = storingPhoto(tostring(index), { Exposure2012 = 0, Contrast2012 = 0 },
                { drops = { Contrast2012 = true }, Exposure2012 = 0.95 })
            ids[#ids + 1] = tostring(index)
        end

        local reply = wire(photos, { source_id = "10", target_ids = ids, settings = named })

        assert.is_nil(reply.result.data)
        assert.truthy(reply.result.problem:find("Exposure2012 0.95 on photo 21 (written 1)", 1, true), reply.result.problem)
        assert.is_nil(reply.result.problem:find("more in adjusted", 1, true))
    end)

    it("covers every case of the shared fixture", function()
        local names = {}
        for _, expected in ipairs(fixture) do names[#names + 1] = expected.case end
        table.sort(names)
        assert.are.same({ "all not found", "all refused", "budget exhausted", "confirmed and remaining", "mixed",
            "unknown and adjusted on one target", "unknown read-back" }, names)
    end)
end)

describe("a copy target the catalog stayed busy for before anything was written", function()
    it("is failed, in a named and in a full copy", function()
        for _, settings in ipairs({ { "Exposure2012" }, false }) do
            local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = { Exposure2012 = 1 } })
            local target = helper.fakePhoto({ id = "11", path = "/t.jpg", developSettings = { Exposure2012 = 0 } })
            local _, Handler = setup({
                photos = { source, target },
                writeAccessAborts = function(name) return name == "Copy Develop Settings" end,
            })
            local label = settings and "named copy" or "full copy"

            local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" }, settings = settings or nil })

            assert.are.same({ { photo_id = "11", reason = helper.catalogBusy("Copy Develop Settings") } }, r.failed, label)
            assert.is_nil(r.unknown, label)
            assert.is_nil(r.data, label)
        end
    end)
end)

describe("develop settings batches stop within their budget", function()
    local function stoppingAfter(count)
        local asked = 0
        return helper.requestContext(nil, { stopping = function() asked = asked + 1; return asked > count end })
    end

    it("copies to the targets that fit and lists the rest as remaining", function()
        local photos = {
            helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = { Exposure2012 = 1 } }),
            helper.fakePhoto({ id = "11", path = "/a.jpg", developSettings = {} }),
            helper.fakePhoto({ id = "12", path = "/b.jpg", developSettings = {} }),
        }
        local _, Handler = setup({ photos = photos })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" }, settings = { "Exposure2012" } },
            stoppingAfter(1))

        assert.are.equal(1, r.data.copied)
        assert.are.same({ "12" }, r.remaining)
    end)

    it("starts an item only with time for its work, one catalog wait per gate it can open and the AI compute", function()
        local function copy(names)
            return function(Handler, context)
                return Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" }, settings = names }, context)
            end
        end
        local function preset(name)
            return function(Handler, context)
                return Handler.applyDevelopPreset({ photo_ids = { "11" }, preset_name = name }, context)
            end
        end
        local function match(Handler, context)
            return Handler.matchPhotoStyle({ reference_id = "10", target_ids = { "11" } }, context)
        end
        local cases = {
            { name = "named copy", reserve = 20, source = { Exposure2012 = 1 }, run = copy({ "Exposure2012" }) },
            { name = "full copy", reserve = 40, source = { Exposure2012 = 1 }, run = copy(nil) },
            { name = "full copy with AI masks", reserve = 80, source = AI_MASK_SETTINGS, run = copy(nil) },
            { name = "preset", reserve = 20, source = {}, run = preset("Plain") },
            { name = "preset with AI masks", reserve = 60, source = {}, run = preset("Subject") },
            { name = "style match", reserve = 30, source = { Exposure2012 = 1 }, run = match },
        }
        package.loaded.HandlerSnapshots = { create = function() return { snapshot = { name = "s" } } end }
        for _, case in ipairs(cases) do
            for _, budget in ipairs({ case.reserve - 0.5, case.reserve + 0.5 }) do
                local target = helper.fakePhoto({ id = "11", path = "/t.jpg", aiUpdate = "ok", developSettings = {} })
                local _, Handler = setup({
                    photos = { helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = case.source }), target },
                    folders = { fakeFolder("User", {
                        fakePreset("Plain", { settings = { Exposure2012 = 1 } }),
                        fakePreset("Subject", { settings = AI_MASK_SETTINGS }),
                    }) },
                })

                local r = case.run(Handler, helper.requestContext(budget))

                local label = case.name .. " with " .. budget .. " s left"
                if budget < case.reserve then
                    assert.are.same({ "11" }, r.remaining, label)
                    assert.is_nil(target:getRawMetadata("__appliedSettings"), label)
                    assert.is_nil(target:getRawMetadata("__appliedPreset"), label)
                    assert.is_nil(target:getRawMetadata("__aiUpdateCalls"), label)
                else
                    assert.is_nil(r.remaining, label)
                end
            end
        end
        package.loaded.HandlerSnapshots = nil
    end)

    it("reads a target's settings once before writing it, and not at all when it is remaining", function()
        local runs = {
            match = function(Handler, context)
                return Handler.matchPhotoStyle({ reference_id = "10", target_ids = { "11", "12" } }, context)
            end,
            ["named copy"] = function(Handler, context)
                return Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" }, settings = { "Exposure2012" } },
                    context)
            end,
            ["full copy"] = function(Handler, context)
                return Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } }, context)
            end,
        }
        package.loaded.HandlerSnapshots = { create = function() return { snapshot = { name = "s" } } end }
        for name, run in pairs(runs) do
            local reference = helper.fakePhoto({ id = "10", path = "/r.jpg", developSettings = { Exposure2012 = 1 } })
            local reads = { ["11"] = 0, ["12"] = 0 }
            local readsBeforeWrite
            local targets = {}
            for _, id in ipairs({ "11", "12" }) do
                local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg", developSettings = { Exposure2012 = 0 } })
                local get, apply = photo.getDevelopSettings, photo.applyDevelopSettings
                photo.getDevelopSettings = function(...) reads[id] = reads[id] + 1; return get(...) end
                photo.applyDevelopSettings = function(...)
                    readsBeforeWrite = readsBeforeWrite or reads[id]
                    return apply(...)
                end
                targets[#targets + 1] = photo
            end
            local _, Handler = setup({ photos = { reference, targets[1], targets[2] } })

            local r = run(Handler, stoppingAfter(1))

            assert.are.same({ "12" }, r.remaining, name)
            assert.are.equal(1, readsBeforeWrite, name)
            assert.are.equal(0, reads["12"], name)
        end
        package.loaded.HandlerSnapshots = nil
    end)

    it("computes each photo's AI masks before applying the preset to the next photo", function()
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local order = {}
        local photos = {}
        for _, id in ipairs({ "1", "2" }) do
            local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg", aiUpdate = "ok" })
            local apply, update = photo.applyDevelopPreset, photo.updateAISettings
            photo.applyDevelopPreset = function(...) order[#order + 1] = "apply " .. id; return apply(...) end
            photo.updateAISettings = function(...) order[#order + 1] = "compute " .. id; return update(...) end
            photos[#photos + 1] = photo
        end
        local _, Handler = setup({ photos = photos, folders = { fakeFolder("User", { preset }) } })

        Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

        assert.are.same({ "apply 1", "compute 1", "apply 2", "compute 2" }, order)
    end)

    it("applies a preset to the photos that fit and lists the rest as remaining", function()
        local preset = fakePreset("Bright", { settings = { Exposure2012 = 0.5 } })
        local photos = { helper.fakePhoto({ id = "1", path = "/a.jpg" }), helper.fakePhoto({ id = "2", path = "/b.jpg" }) }
        local _, Handler = setup({ photos = photos, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Bright" }, stoppingAfter(1))

        assert.are.equal(1, r.data.applied)
        assert.are.same({ "2" }, r.remaining)
    end)
end)

describe("a full copy writes masks only through the guarded mask write", function()
    it("copies each target whole through the guarded write, or not at all when the guarded write refuses", function()
        local masks = { { What = "Correction", CorrectionID = "C1", CorrectionMasks = {} } }
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, MaskGroupBasedCorrections = masks,
        } })
        local accepted = helper.fakePhoto({ id = "11", path = "/a.jpg", developSettings = { Exposure2012 = 0 } })
        local refused = helper.fakePhoto({ id = "12", path = "/b.jpg", developSettings = { Exposure2012 = 0 } })
        local guarded = {}
        local Reply = require 'Reply'
        local _, Handler = setup({
            photos = { source, accepted, refused },
            guardedMaskWrite = {
                apply = function(context, _, photo, spec)
                    guarded[#guarded + 1] = tostring(photo.localIdentifier)
                    if photo == refused then Reply.refuse("Mask writes are not certified for process version 11.0") end
                    context.ledger:record(spec.description)
                    photo:getDevelopSettings().MaskGroupBasedCorrections = spec.build({})
                    return { entries = photo:getDevelopSettings().MaskGroupBasedCorrections }
                end,
            },
        })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.same({ "11", "12" }, guarded)
        assert.is_nil(accepted:getRawMetadata("__appliedSettings").MaskGroupBasedCorrections)
        assert.are.equal(1, accepted:getDevelopSettings().Exposure2012)
        assert.are.same(masks, accepted:getDevelopSettings().MaskGroupBasedCorrections)
        assert.are.equal(0, refused:getDevelopSettings().Exposure2012)
        assert.are.equal("12", r.failed[1].photo_id)
        assert.truthy(r.failed[1].reason:find("not certified for process version 11.0", 1, true), r.failed[1].reason)
        assert.are.equal(1, r.data.copied)
    end)

    it("answers unknown, without the rest, for a target whose guarded mask write raised a plain error", function()
        local masks = { { What = "Correction", CorrectionID = "C1", CorrectionMasks = {} } }
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, MaskGroupBasedCorrections = masks,
        } })
        local stored = { Exposure2012 = 0, MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "OLD" } } }
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg", developSettings = stored })
        local _, Handler = setup({
            photos = { source, target },
            tasks = { sleep = function() end, pcall = pcall },
            guardedMaskWrite = {
                apply = function(context, _, _, spec)
                    context.ledger:record(spec.description)
                    stored.MaskGroupBasedCorrections = spec.build({})
                    error("Lightroom did not keep the mask data that was written, and the previous masks could not be"
                        .. " confirmed restored", 0)
                end,
            },
        })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_nil(r.failed)
        assert.are.equal("11", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("the masks could not be copied", 1, true), r.unknown[1].reason)
        assert.are.equal(0, stored.Exposure2012)
    end)

    it("answers unknown, not failed, for a target whose masks were replaced before the rest of the copy raised or met a busy catalog", function()
        local cases = {
            { name = "rest raised", reason = "cannot write the rest", restRaises = true },
            { name = "rest gate busy", reason = helper.catalogBusy("Copy Develop Settings"), busy = true },
        }
        for _, case in ipairs(cases) do
            local masks = { { What = "Correction", CorrectionID = "C1", CorrectionMasks = {} } }
            local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
                Exposure2012 = 1, MaskGroupBasedCorrections = masks,
            } })
            local stored = { Exposure2012 = 0, MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "OLD" } } }
            local target = helper.fakePhoto({ id = "11", path = "/t.jpg", developSettings = stored })
            if case.restRaises then target.applyDevelopSettings = function() error("cannot write the rest") end end
            local _, Handler = setup({
                photos = { source, target },
                tasks = { sleep = function() end, pcall = pcall },
                writeAccessAborts = case.busy and function(name) return name == "Copy Develop Settings" end or nil,
                guardedMaskWrite = {
                        apply = function(context, _, _, spec)
                        local previous = stored.MaskGroupBasedCorrections
                        context.ledger:record(spec.description)
                        stored.MaskGroupBasedCorrections = spec.build({})
                        return { previous = previous }
                    end,
                },
            })

            local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

            assert.are.same(masks, stored.MaskGroupBasedCorrections, case.name)
            assert.are.equal(0, stored.Exposure2012, case.name)
            assert.is_nil(r.failed, case.name)
            assert.are.equal("11", r.unknown[1].photo_id, case.name)
            assert.truthy(r.unknown[1].reason:find("; written before this stopped: Copy Develop Settings", 1, true),
                r.unknown[1].reason)
            assert.truthy(r.unknown[1].reason:find(case.reason, 1, true), r.unknown[1].reason)
        end
    end)
end)

describe("apply_develop_preset refuses a preset whose settings cannot be read", function()
    it("refuses before writing, for a dry run and for the apply, when the settings are missing or too deeply nested", function()
        local deep = {}
        local level = deep
        for _ = 1, 40 do level.next = {}; level = level.next end
        for _, settings in ipairs({ "unreadable", deep }) do
            local preset = fakePreset("Odd")
            preset.getSetting = function() if settings == "unreadable" then return nil end return settings end
            local photo = helper.fakePhoto({ id = "1", path = "/a.jpg" })
            local catalog, Handler = setup({ photos = { photo }, folders = { fakeFolder("User", { preset }) } })

            for _, dryRun in ipairs({ true, false }) do
                local err = helper.failedOf(function()
                    Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Odd", dry_run = dryRun })
                end)
                assert.truthy(err:find("Preset settings", 1, true))
            end
            assert.are.equal(0, catalog:getWriteAccessCount())
        end
    end)
end)

describe("a full copy replaces the target's masks and admits them under the process version it writes", function()
    local Reply = require 'Reply'

    local function recordingAdmission(log, refusal)
        local admissions = 0
        return {
            status = function() return {} end,
            requireAdmitted = function(_, processVersion)
                admissions = admissions + 1
                log[#log + 1] = "admit " .. tostring(processVersion)
                if refusal and admissions > 1 then Reply.refuse(refusal) end
            end,
        }
    end

    local function recordingGuard(log, opts)
        opts = opts or {}
        return {
            precheck = function(catalog, photo, _, processVersion)
                local Admission = require 'MaskWriteAdmission'
                Admission.requireAdmitted(Admission.status(catalog), processVersion)
                log[#log + 1] = "ids " .. tostring(photo.localIdentifier)
                if opts.unnamed then Reply.refuse('mask 1 ("A") has no id yet') end
            end,
            apply = function(context, _, photo, spec)
                local settings = photo:getDevelopSettings()
                log[#log + 1] = "masks " .. tostring(photo.localIdentifier) .. " at " .. tostring(settings.ProcessVersion)
                if opts.refuseApply then Reply.refuse(opts.refuseApply) end
                local previous = settings.MaskGroupBasedCorrections or {}
                context.ledger:record(spec.description)
                settings.MaskGroupBasedCorrections = spec.build({})
                return { previous = previous }
            end,
        }
    end

    local function target(id, settings, log, opts)
        opts = opts or {}
        local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".jpg", developSettings = settings })
        local apply = photo.applyDevelopSettings
        photo.applyDevelopSettings = function(self, written, ...)
            local keys = {}
            for key in pairs(written) do keys[#keys + 1] = key end
            table.sort(keys)
            log[#log + 1] = "write " .. id .. " " .. table.concat(keys, ",")
            if opts.restThrows and written.Exposure2012 ~= nil then error(opts.restThrows) end
            return apply(self, written, ...)
        end
        return photo
    end

    local function oldMasks()
        return { { What = "Correction", CorrectionID = "A" }, { What = "Correction", CorrectionID = "B" } }
    end

    it("removes the target's masks through the guarded write when the source has none, and says how many", function()
        for _, sourceMasks in ipairs({ false, {} }) do
            local log = {}
            local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
                Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = sourceMasks or nil,
            } })
            local masked = target("11", { Exposure2012 = 0, ProcessVersion = "15.4", MaskGroupBasedCorrections = oldMasks() }, log)
            local _, Handler = setup({ photos = { source, masked }, guardedMaskWrite = recordingGuard(log) })

            local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

            assert.are.same({}, masked:getDevelopSettings().MaskGroupBasedCorrections)
            assert.are.equal(1, masked:getDevelopSettings().Exposure2012)
            assert.are.same({ { photo_id = "11", count = 2 } }, r.data.masks_removed)
            assert.are.same({ "masks 11 at 15.4", "write 11 Exposure2012,ProcessVersion" }, log)
        end
    end)

    it("does not touch the masks of a maskless target when the source has none", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = { Exposure2012 = 1, ProcessVersion = "15.4" } })
        local plain = target("11", { Exposure2012 = 0, ProcessVersion = "15.4" }, log)
        local _, Handler = setup({ photos = { source, plain }, guardedMaskWrite = recordingGuard(log) })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal(1, r.data.copied)
        assert.is_nil(r.data.masks_removed)
        assert.are.same({ "write 11 Exposure2012,ProcessVersion" }, log)
    end)

    it("writes the source's process version first and admits the masks under it", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "S" } },
        } })
        local older = target("11", { Exposure2012 = 0, ProcessVersion = "11.0", MaskGroupBasedCorrections = oldMasks() }, log)
        local _, Handler = setup({ photos = { source, older }, guardedMaskWrite = recordingGuard(log),
            maskWriteAdmission = recordingAdmission(log) })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal(1, r.data.copied)
        assert.are.same({ "admit 15.4", "admit 15.4", "ids 11", "write 11 ProcessVersion", "masks 11 at 15.4",
            "write 11 Exposure2012,ProcessVersion" }, log)
    end)

    it("fails a target with nothing written when it holds a mask Lightroom has not named, before the process version", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "S" } },
        } })
        local older = target("11", { Exposure2012 = 0, ProcessVersion = "11.0", MaskGroupBasedCorrections = oldMasks() }, log)
        local _, Handler = setup({ photos = { source, older }, guardedMaskWrite = recordingGuard(log, { unnamed = true }),
            maskWriteAdmission = recordingAdmission(log) })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal("11", r.failed[1].photo_id)
        assert.truthy(r.failed[1].reason:find("has no id yet", 1, true), r.failed[1].reason)
        assert.are.same({ "admit 15.4", "admit 15.4", "ids 11" }, log)
        assert.are.equal("11.0", older:getDevelopSettings().ProcessVersion)
    end)

    it("fails a target with nothing written when the planned process version is not admitted", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "S" } },
        } })
        local older = target("11", { Exposure2012 = 0, ProcessVersion = "11.0", MaskGroupBasedCorrections = oldMasks() }, log)
        local _, Handler = setup({
            photos = { source, older },
            guardedMaskWrite = recordingGuard(log),
            maskWriteAdmission = recordingAdmission(log, "The photo's process version (15.4) was not exercised"),
        })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal("11", r.failed[1].photo_id)
        assert.are.same({ "admit 15.4", "admit 15.4" }, log)
        assert.are.equal("11.0", older:getDevelopSettings().ProcessVersion)
    end)

    it("answers unknown and names the process version when the masks are refused after it was written", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "S" } },
        } })
        local older = target("11", { Exposure2012 = 0, ProcessVersion = "11.0", MaskGroupBasedCorrections = oldMasks() }, log)
        local _, Handler = setup({
            photos = { source, older },
            guardedMaskWrite = recordingGuard(log, { refuseApply = "Lightroom did not keep the mask data" }),
        })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_nil(r.failed)
        assert.are.equal("11", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("written before this stopped: Set Process Version 15.4", 1, true),
            r.unknown[1].reason)
        assert.truthy(r.unknown[1].reason:find("did not keep the mask data", 1, true), r.unknown[1].reason)
    end)

    it("answers unknown and names what was written when the rest raises after the process version and masks", function()
        local log = {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = { { What = "Correction", CorrectionID = "S" } },
        } })
        local older = target("11", { Exposure2012 = 0, ProcessVersion = "11.0", MaskGroupBasedCorrections = oldMasks() }, log,
            { restThrows = "cannot write the rest" })
        local _, Handler = setup({ photos = { source, older }, guardedMaskWrite = recordingGuard(log), tasks = { sleep = function() end, pcall = pcall } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_nil(r.failed)
        assert.are.equal("11", r.unknown[1].photo_id)
        assert.truthy(r.unknown[1].reason:find("written before this stopped: Set Process Version 15.4", 1, true),
            r.unknown[1].reason)
        assert.truthy(r.unknown[1].reason:find("cannot write the rest", 1, true), r.unknown[1].reason)
    end)
end)

describe("a full copy refuses, before its first write to a target, what the guarded mask write would refuse", function()
    local Reply = require 'Reply'
    local Store = require 'fake_mask_store'

    local function colorRange(points)
        return Store.correction("R", { { What = "Mask/RangeMask", MaskActive = true,
            CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = points } } })
    end

    local function copyOnto(sourceMasks, targetEntries, opts)
        opts = opts or {}
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = {
            Exposure2012 = 1, ProcessVersion = "15.4", MaskGroupBasedCorrections = sourceMasks,
        } })
        local target = helper.fakePhoto({ id = "11", path = "/t.jpg" })
        local store = Store.attach(target, { entries = targetEntries, processVersion = "11.0", settings = { Exposure2012 = 0 } })
        if opts.unnamed then store.entries[1].CorrectionID, store.entries[1].CorrectionSyncID = nil, nil end
        local _, Handler = setup({ photos = { source, target }, realGuard = true, maskWriteAdmission = opts.admission })
        return Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } }), store, target
    end

    local function onlyFailure(r)
        assert.is_nil(r.unknown)
        assert.are.equal(1, #r.failed)
        assert.are.equal("11", r.failed[1].photo_id)
        return r.failed[1].reason
    end

    it("refuses a source colour range Lightroom sampled twice, leaving the target's process version unwritten", function()
        local r, store, target = copyOnto({ colorRange({ "0.1 0.4 0.5 0.2 0.3 0", "0.6 0.5 0.4 0.7 0.8 0" }) }, {})

        assert.truthy(onlyFailure(r):find("exactly one PointModels entry", 1, true))
        assert.are.equal(0, store.attempts)
        assert.are.equal("11.0", target:getDevelopSettings().ProcessVersion)
    end)

    it("refuses a target holding a mask Lightroom has not named yet, leaving its process version unwritten", function()
        local r, store, target = copyOnto({ Store.correction("S", { Store.linearComponent() }) },
            { Store.correction("A", { Store.linearComponent() }) }, { unnamed = true })

        assert.truthy(onlyFailure(r):find('mask 1 ("A") has no id yet', 1, true))
        assert.are.equal(0, store.attempts)
        assert.are.equal("11.0", target:getDevelopSettings().ProcessVersion)
    end)

    it("answers the admission refusal before the id refusal when a maskless source meets an unnamed masked target", function()
        local r, store = copyOnto({}, { Store.correction("A", { Store.linearComponent() }) }, {
            unnamed = true,
            admission = { status = function() return {} end, requireAdmitted = function(_, processVersion)
                Reply.refuse("process version " .. tostring(processVersion) .. " is not admitted")
            end },
        })

        assert.truthy(onlyFailure(r):find("process version 15.4 is not admitted", 1, true))
        assert.are.equal(0, store.attempts)
    end)
end)
