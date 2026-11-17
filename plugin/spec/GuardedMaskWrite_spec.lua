local helper = require 'spec_helper'

local Store = require 'fake_mask_store'

local linearComponent = Store.linearComponent
local radialComponent = Store.radialComponent
local correction = Store.correction

local HOME = "/Users/tester"
local CERTIFICATION_FILE = HOME .. "/.config/lightroom-mcp/mask-certification.json"
local THROWAWAY_CATALOG = HOME .. "/Pictures/lrmcp-live-1/lrmcp-live-1.lrcat"
local THROWAWAY_MARKER = HOME .. "/Pictures/lrmcp-live-1/lrmcp-live-catalog.json"
local PERSONAL_CATALOG = HOME .. "/Pictures/Lightroom/Lightroom Catalog.lrcat"
local RUNNING_BUILD = "16.0.0 build 1234567"

local function certification(build)
    return string.format(
        '{"lightroom":{"version":"16.0","build":"%s"},"process_versions":["15.4"],"certified_at":"2026-11-12T10:00:00Z","checks":["linear create"]}',
        build)
end

local function setup(opts)
    opts = opts or {}
    local photo = {}
    local state = Store.attach(photo, opts)
    state.sleeps = 0
    local files = opts.files or { [THROWAWAY_MARKER] = "{}" }
    local catalog = {
        getPath = function() return opts.catalogPath or THROWAWAY_CATALOG end,
        withReadAccessDo = function(_, fn) fn() end,
        withWriteAccessDo = function(_, _, fn) fn() end,
    }
    Store.trackGates(state, catalog)
    catalog.getTargetPhoto = function() return photo end
    state.flushes = {}
    helper.installImport({
        LrApplicationView = { getCurrentModuleName = function() return opts.module or "library" end },
        LrDevelopController = {
            stopTracking = function(committed) state.flushes[#state.flushes + 1] = { committed = committed, attempts = state.attempts } end,
        },
        LrSelection = {},
        LrApplication = {
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
            getStandardFilePath = function(name)
                assert.are.equal("home", name)
                return HOME
            end,
        },
        LrTasks = {
            pcall = pcall,
            sleep = function() state.sleeps = state.sleeps + 1 end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "GuardedMaskWrite", "MaskWriteAdmission", "RunningLightroom", "PluginFiles", "Log", "DevelopSession" }) do
        package.loaded[name] = nil
    end
    local Guard = require 'GuardedMaskWrite'
    return Guard, catalog, photo, state
end

local function appendGradient(component)
    return function(entries)
        entries[#entries + 1] = correction("New", { component })
        return entries
    end
end

describe("GuardedMaskWrite.apply on the photo shown in Develop", function()
    for _, case in ipairs({ { module = "develop", flushes = { { committed = true, attempts = 0 } } }, { module = "library", flushes = {} } }) do
        it("commits Develop's pending edits before its gate only in Develop (" .. case.module .. ")", function()
            local Guard, catalog, photo, state = setup({ module = case.module, entries = { correction("A", { linearComponent() }) } })

            Guard.apply(catalog, photo, { description = "Create gradient mask", build = appendGradient(radialComponent()) })

            assert.are.same(case.flushes, state.flushes)
            assert.are.equal(2, #state.entries)
        end)
    end
end)

describe("GuardedMaskWrite.preflight", function()
    it("returns the existing entries of a photo admitted for mask writes", function()
        local Guard, catalog, photo = setup({ entries = { correction("A", { linearComponent() }) } })

        local entries = Guard.preflight(catalog, photo)

        assert.are.equal(1, #entries)
        assert.are.equal("A", entries[1].CorrectionName)
    end)

    it("returns an empty list for a photo without masks", function()
        local Guard, catalog, photo = setup()

        assert.are.same({}, Guard.preflight(catalog, photo))
    end)

    it("reads settings inside the read gate", function()
        local Guard, catalog, photo, state = setup()

        Guard.preflight(catalog, photo)

        assert.are.equal(0, state.readsOutsideGate)
        assert.are.equal(1, state.reads)
    end)

    it("admits a write when the certification names the running build and the photo's process version", function()
        local Guard, catalog, photo = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
            entries = { correction("A", { linearComponent() }) },
        })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("refuses a photo whose process version the certification did not exercise", function()
        local Guard, catalog, photo = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
            processVersion = "11.0",
        })

        local message = helper.refusalOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
        assert.is_truthy(message:find("Nothing was changed", 1, true))
    end)

    it("refuses under the planned process version even when the photo's own is certified", function()
        local Guard, catalog, photo = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
        })

        local message = helper.refusalOf(function() Guard.preflight(catalog, photo, "11.0") end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
    end)

    it("accepts any Local adjustment slider on an existing entry", function()
        local entry = correction("A", { linearComponent() }, { LocalShadows2012 = 0.1, LocalTexture = 0.2 })
        local Guard, catalog, photo = setup({ entries = { entry } })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("accepts the local tone curve of every channel on an existing entry", function()
        local curves = {
            MainCurve = { "0,0", "64,30", "192,225", "255,255" },
            RedCurve = { "0,0", "255,255" },
            GreenCurve = { "0,0", "255,255" },
            BlueCurve = { "0,0", "255,255" },
        }
        local Guard, catalog, photo = setup({ entries = { correction("A", { linearComponent() }, curves) } })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("treats an AI mask component as opaque", function()
        local ai = { What = "Mask/Image", MaskActive = true, SomethingOpaque = { 1, 2, 3 }, Whatever = "x" }
        local Guard, catalog, photo = setup({ entries = { correction("AI", { ai }) } })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("refuses, writing nothing, when an existing mask holds a value it cannot copy", function()
        local ai = { What = "Mask/Image", MaskActive = true, Opaque = io.stdout }
        local Guard, catalog, photo, state = setup({ entries = { correction("AI", { ai }) } })

        local message = helper.refusalOf(function() Guard.apply(catalog, photo, { description = "x", build = appendGradient(linearComponent()) }) end)

        assert.is_truthy(message:find("userdata", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("accepts existing brush and luminance range masks", function()
        local brush = {
            What = "Mask/Aggregate",
            MaskActive = true,
            Masks = {
                { What = "Mask/Paint", Dabs = { "d 0.1 0.2" }, Radius = 0.1, Flow = 1, CenterWeight = 0 },
            },
        }
        local range = {
            What = "Mask/RangeMask",
            MaskActive = true,
            CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = "0.1 0.2 0.3 0.4" },
        }
        local Guard, catalog, photo = setup({ entries = { correction("B", { brush }), correction("R", { range }) } })

        assert.are.equal(2, #Guard.preflight(catalog, photo))
    end)

end)

describe("GuardedMaskWrite.apply beside entries the call leaves alone", function()
    local function rangeComponent(rangeTable)
        return { What = "Mask/RangeMask", MaskActive = true, MaskID = "XT1", MaskSyncID = "SXT1", CorrectionRangeMask = rangeTable }
    end
    local renamed = linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" })
    renamed.FullY, renamed.FullYY = nil, 0.2

    for _, case in ipairs({
        { held = "no components", entry = correction("X", {}, { CorrectionID = "X" }) },
        { held = "an Extended curve field", entry = correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X", ExtendedMainCurve = { "0,0", "40,30", "255,255" } }) },
        { held = "an unknown entry field", entry = correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X", CorrectionSomethingNew = 1 }) },
        { held = "a component field the pinned format does not know", entry = correction("X", { renamed }, { CorrectionID = "X" }) },
        { held = "an unknown mask type", entry = correction("X", { { What = "Mask/Teleport", MaskActive = true, MaskID = "XT1", MaskSyncID = "SXT1" } },
            { CorrectionID = "X" }) },
        { held = "an unsupported range type", entry = correction("X", { rangeComponent({ Type = 3, DepthRange = "0 0 1 1" }) },
            { CorrectionID = "X" }) },
        { held = "a curve that is not a table", entry = correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X", MainCurve = "0,0 255,255" }) },
        { held = "a color range with two samples", entry = correction("X", { rangeComponent({ Type = 1, ColorAmount = 0.5,
            PointModels = { "0.1 0.4 0.5 0.2 0.3 0", "0.6 0.5 0.4 0.7 0.8 0" } }) }, { CorrectionID = "X" }) },
        { held = "a color range with two samples inside a group", entry = correction("X", { { What = "Mask/Aggregate", MaskID = "XT1",
            MaskSyncID = "SXT1", Masks = { { What = "Mask/RangeMask", CorrectionRangeMask = { Type = 1, ColorAmount = 0.5,
            PointModels = { "0.1 0.4 0.5 0.2 0.3 0", "0.6 0.5 0.4 0.7 0.8 0" } } } } } }, { CorrectionID = "X" }) },
    }) do
        it("admits a constructing write beside an entry with " .. case.held .. " and leaves that entry byte-identical", function()
            local Guard, catalog, photo, state = setup({ entries = { case.entry } })
            local held = Store.clone(state.entries[1])

            Guard.preflight(catalog, photo)
            Guard.apply(catalog, photo, { description = "Create gradient mask", build = appendGradient(radialComponent()) })

            assert.are.equal(1, #state.writes)
            assert.are.equal(2, #state.entries)
            assert.are.same(held, state.entries[1])
        end)
    end

    it("checks only what the call changed in an existing entry, admitting its Lightroom-only fields", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X", ExtendedMainCurve = { "0,0", "40,30", "255,255" } }) } })

        Guard.apply(catalog, photo, { description = "Add to mask", build = function(entries)
            entries[1].CorrectionMasks[2] = radialComponent()
            return entries
        end })

        assert.are.equal(2, #state.entries[1].CorrectionMasks)
        assert.are.same({ "0,0", "40,30", "255,255" }, state.entries[1].ExtendedMainCurve)
    end)

    it("refuses a change to an existing entry that breaks the pinned format, writing nothing", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X" }) } })

        local message = helper.refusalOf(function()
            Guard.apply(catalog, photo, { description = "Add to mask", build = function(entries)
                entries[1].CorrectionMasks[2] = { What = "Mask/RangeMask", CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { "a", "b" } } }
                return entries
            end })
        end)

        assert.is_truthy(message:find("exactly one PointModels entry", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    for _, case in ipairs({
        { what = "a number moved by less than the constructed tolerance", change = function(entry) entry.CorrectionMasks[1].Feather = 50.0000001 end },
        { what = "a derived field changed", change = function(entry) entry.CorrectionMasks[1].MaskSyncID = "OTHER" end },
        { what = "a zero local adjustment dropped", change = function(entry) entry.LocalGlow = nil end },
    }) do
        it("restores the photo when a preserved entry comes back with " .. case.what, function()
            local Guard, catalog, photo, state = setup({
                entries = { correction("Old", { radialComponent({ MaskID = "OLDT1", MaskSyncID = "SOLDT1" }) }, { CorrectionID = "OLD", LocalGlow = 0 }) },
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then case.change(stored[1]) end
                    return stored
                end,
            })
            local held = Store.clone(state.entries[1])

            local message = helper.refusalOf(function()
                Guard.apply(catalog, photo, { description = "Create gradient mask", build = appendGradient(linearComponent()) })
            end)

            assert.is_truthy(message:find("previous masks were restored", 1, true), message)
            assert.are.equal(2, #state.writes)
            assert.are.same({ held }, state.entries)
        end)
    end
end)

describe("GuardedMaskWrite.apply", function()
    local function applyAppend(Guard, catalog, photo, component, extra)
        local spec = {
            description = "Test write",
            build = appendGradient(component),
        }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return Guard.apply(catalog, photo, spec)
    end

    it("writes the whole array, reads it back and returns the stored entries", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(1, #state.writes)
        assert.are.equal(2, #state.writes[1])
        assert.are.equal("OLD", state.writes[1][1].CorrectionID)
        assert.is_nil(state.writes[1][2].CorrectionID)
        assert.are.equal(2, #result.entries)
        assert.are.equal("C1", result.entries[2].CorrectionID)
        assert.are.equal("C1T1", result.entries[2].CorrectionMasks[1].MaskID)
        assert.are.equal(1, #result.previous)
        assert.are.equal(0, state.writesOutsideGate)
        assert.are.equal(0, state.readsOutsideGate)
    end)

    it("accepts a clear that Lightroom stores as no mask key at all, without a rollback", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        local result = Guard.apply(catalog, photo, { description = "Clear", build = function() return {} end })

        assert.are.equal(1, #state.writes)
        assert.are.same({}, state.writes[1])
        assert.is_nil(photo:getDevelopSettings().MaskGroupBasedCorrections)
        assert.are.same({}, result.entries)
        assert.are.equal(1, #result.previous)
    end)

    it("writes past an existing mask that holds a local tone curve and keeps the curve", function()
        local curved = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, {
            CorrectionID = "OLD",
            MainCurve = { "0,0", "64,30", "192,225", "255,255" },
            RedCurve = { "0,0", "128,170", "255,255" },
        })
        local Guard, catalog, photo, state = setup({ entries = { curved } })

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(2, #result.entries)
        assert.are.same({ "0,0", "64,30", "192,225", "255,255" }, state.writes[1][1].MainCurve)
        assert.are.same({ "0,0", "128,170", "255,255" }, result.entries[1].RedCurve)
    end)

    it("writes into a photo that has no masks yet", function()
        local Guard, catalog, photo, state = setup()

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(1, #state.writes[1])
        assert.are.equal(1, #result.entries)
    end)

    it("hands build a copy so a failed build leaves the previous list intact", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("A", { linearComponent() }) } })

        local message = helper.unknownOf(function()
            Guard.apply(catalog, photo, {
                description = "x",
                build = function(entries)
                    entries[1].CorrectionName = "changed"
                    error("build failed", 0)
                end,
            })
        end)

        assert.are.equal("build failed", message)
        assert.are.equal(0, #state.writes)
        assert.are.equal("A", state.entries[1].CorrectionName)
    end)

    it("accepts values Lightroom normalizes to six decimals and fills derived fields", function()
        local Guard, catalog, photo = setup({
            transformWrite = function(stored)
                for _, entry in ipairs(stored) do
                    for _, component in ipairs(entry.CorrectionMasks) do
                        if component.FullY then component.FullY = math.floor(component.FullY * 1e6 + 0.5) / 1e6 end
                        component.MaskSyncID = "filled-by-lightroom"
                    end
                end
                return stored
            end,
        })

        local result = applyAppend(Guard, catalog, photo, linearComponent({ FullY = 0.2000004 }))

        assert.are.equal(1, #result.entries)
    end)

    it("waits for a read-back that lags behind the write", function()
        local Guard, catalog, photo, state = setup({ lagReadsAfterWrite = 3 })

        applyAppend(Guard, catalog, photo, linearComponent())

        assert.is_true(state.sleeps >= 3)
        assert.are.equal(1, #state.writes)
    end)

    it("refuses an uncertified Lightroom before writing masks", function()
        local Guard, catalog, photo, state = setup({ catalogPath = PERSONAL_CATALOG, files = {} })

        helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.are.equal(0, #state.writes)
    end)

    it("refuses a new component with a string where a number belongs, writing nothing", function()
        local Guard, catalog, photo, state = setup()

        local message = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ FullY = "0.2" }))
        end)

        assert.is_truthy(message:find("FullY must be a number", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a boolean where a number belongs and a NaN", function()
        local Guard, catalog, photo, state = setup()

        local booleanMessage = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ ZeroX = true }))
        end)
        local nanMessage = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ ZeroX = 0 / 0 }))
        end)

        assert.is_truthy(booleanMessage:find("ZeroX must be a number", 1, true))
        assert.is_truthy(nanMessage:find("ZeroX must be a number", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a component missing a defining field", function()
        local Guard, catalog, photo, state = setup()
        local component = linearComponent()
        component.FullY = nil

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, component) end)

        assert.is_truthy(message:find("missing FullY", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a component with an unknown or absent type", function()
        local Guard, catalog, photo, state = setup()
        local absent = linearComponent()
        absent.What = nil

        local unknown = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ What = "Mask/Nope" }))
        end)
        local missing = helper.refusalOf(function() applyAppend(Guard, catalog, photo, absent) end)

        assert.is_truthy(unknown:find("unknown mask type Mask/Nope", 1, true))
        assert.is_truthy(missing:find("unknown mask type nil", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a color range with two samples and one with an unsupported type", function()
        local Guard, catalog, photo, state = setup()
        local function range(rangeTable)
            return { What = "Mask/RangeMask", MaskActive = true, CorrectionRangeMask = rangeTable }
        end

        local two = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 1, ColorAmount = 0.4, PointModels = { "a", "b" } }))
        end)
        local unsupported = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 3, DepthRange = "0 0 1 1" }))
        end)

        assert.is_truthy(two:find("exactly one PointModels entry", 1, true))
        assert.is_truthy(unsupported:find("unsupported range Type 3", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses without a rollback write when the catalog stays busy with another write", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
        })
        catalog.withWriteAccessDo = function(_, _, _, timeoutParams)
            if timeoutParams then return "aborted" end
        end

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.are.equal(helper.catalogBusy("Test write"), message)
        assert.are.equal(0, #state.writes)
    end)

    it("rolls back when Lightroom silently drops the component", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[2].CorrectionMasks = {} end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.is_truthy(message:find("count changed from 1 to 0", 1, true))
        assert.are.equal(2, #state.writes)
        assert.are.equal(1, #state.writes[2])
        assert.are.equal("OLD", state.writes[2][1].CorrectionID)
        assert.are.equal(1, #state.entries)
    end)

    it("rolls back when Lightroom reads back different geometry", function()
        local Guard, catalog, photo, state = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].FullY = 0.9 end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("FullY: wrote 0.2, read back 0.9", 1, true))
        assert.are.same({}, state.writes[2])
        assert.are.equal(0, #state.entries)
    end)

    it("rolls back when an untouched existing mask changes under the write", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].Feather = 0 end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("masks[1], left alone by this call, changed at CorrectionMasks.1.Feather", 1, true), message)
        assert.are.equal(2, #state.writes)
    end)

    it("rolls back when the entry count changes", function()
        local Guard, catalog, photo, state = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then return {} end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("mask count changed: wrote 1, read back 0", 1, true))
        assert.are.equal(2, #state.writes)
    end)

    local function copiedMaskEntries()
        return {
            correction("Copy", { linearComponent({ MaskID = "COPYT1", MaskInverted = true }) }, {
                CorrectionID = "COPY",
                LocalGlow = 0,
                LocalHue = 0,
                LocalSaturation = 0,
            }),
        }
    end

    it("rolls back when a non-zero local adjustment of an existing mask is dropped", function()
        local entries = copiedMaskEntries()
        entries[1].LocalGlow = 12
        local Guard, catalog, photo, state = setup({
            entries = entries,
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].LocalGlow = nil end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("masks[1], left alone by this call, changed at LocalGlow", 1, true), message)
        assert.are.equal(2, #state.writes)
        assert.are.equal(12, state.writes[2][1].LocalGlow)
    end)

    it("answers unknown when the rollback reads back different, or its gate stays busy after the write", function()
        local cases = {
            { name = "restore read back different", writes = 2, transformWrite = function(stored)
                stored[1].CorrectionMasks = {}
                return stored
            end },
            { name = "restore gate busy", writes = 1, busyGate = 2, transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks = {} end
                return stored
            end },
        }
        for _, case in ipairs(cases) do
            local Guard, catalog, photo, state = setup({
                entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
                transformWrite = case.transformWrite,
            })
            local write, gates = catalog.withWriteAccessDo, 0
            catalog.withWriteAccessDo = function(self, description, fn, timeoutParams)
                gates = gates + 1
                if gates == case.busyGate then return "aborted" end
                return write(self, description, fn, timeoutParams)
            end

            local message = helper.unknownOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

            assert.is_truthy(message:find("could not be confirmed restored", 1, true), case.name)
            assert.are.equal(case.writes, #state.writes, case.name)
        end
    end)

    it("attempts a restore when the write call itself throws", function()
        local Guard, catalog, photo, state = setup({
            rejectWrite = function(writeNumber) return writeNumber == 1 end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("Lightroom rejected the write", 1, true))
        assert.are.equal(1, #state.writes)
        assert.are.same({}, state.writes[1])
    end)

    it("rolls back when the cross-check reports a problem", function()
        local Guard, catalog, photo, state = setup()

        local message = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent(), {
                crossCheck = function() return "mask list does not show the tool" end,
            })
        end)

        assert.is_truthy(message:find("mask list does not show the tool", 1, true))
        assert.are.equal(2, #state.writes)
        assert.are.same({}, state.writes[2])
    end)

    it("rolls back when the cross-check throws", function()
        local Guard, catalog, photo, state = setup()

        local message = helper.refusalOf(function()
            applyAppend(Guard, catalog, photo, linearComponent(), {
                crossCheck = function() error("getAllMasks failed", 0) end,
            })
        end)

        assert.is_truthy(message:find("getAllMasks failed", 1, true))
        assert.are.equal(2, #state.writes)
    end)

    it("hands the cross-check the stored entries", function()
        local Guard, catalog, photo = setup()
        local seen

        applyAppend(Guard, catalog, photo, linearComponent(), {
            crossCheck = function(entries) seen = entries end,
        })

        assert.are.equal("C1", seen[1].CorrectionID)
    end)

    it("leaves an AI mask entry verbatim in the written array", function()
        local ai = { What = "Mask/Image", MaskActive = true, MaskID = "AIT1", Payload = "abc" }
        local Guard, catalog, photo, state = setup({ entries = { correction("AI", { ai }, { CorrectionID = "AI1" }) } })

        applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal("abc", state.writes[1][1].CorrectionMasks[1].Payload)
        assert.are.equal(1, #state.writes)
    end)

    it("rolls back when an AI mask component changes type", function()
        local ai = { What = "Mask/Image", MaskActive = true, MaskID = "AIT1" }
        local Guard, catalog, photo, state = setup({
            entries = { correction("AI", { ai }, { CorrectionID = "AI1" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].What = "Mask/Gradient" end
                return stored
            end,
        })

        local message = helper.refusalOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("masks[1], left alone by this call, changed at CorrectionMasks.1.What", 1, true), message)
        assert.are.equal(2, #state.writes)
    end)
end)

describe("GuardedMaskWrite.compareEntries", function()
    local Guard = setup()

    local function oneEntry(component, overrides)
        return { correction("A", { component }, overrides) }
    end

    it("accepts numbers within 1e-5 and rejects 1e-4", function()
        local expected = oneEntry(linearComponent({ FullY = 0.2 }))

        assert.are.same({}, Guard.compareEntries(expected, oneEntry(linearComponent({ FullY = 0.200009 }))))
        assert.are_not.same({}, Guard.compareEntries(expected, oneEntry(linearComponent({ FullY = 0.2001 }))))
    end)

    it("does not compare derived fields, Flipped included", function()
        local expected = oneEntry(radialComponent({ Flipped = false }))
        local actual = oneEntry(radialComponent({ Flipped = true, MaskID = "x" }), {
            CorrectionID = "Z",
            CorrectionReferenceX = 0.9,
            LocalCurveRefineSaturation = 100,
        })

        assert.are.same({}, Guard.compareEntries(expected, actual))
    end)

    it("catches a changed local slider and a changed name", function()
        local expected = oneEntry(linearComponent())

        local slider = Guard.compareEntries(expected, oneEntry(linearComponent(), { LocalExposure2012 = 0 }))
        local name = Guard.compareEntries(expected, oneEntry(linearComponent(), { CorrectionName = "B" }))

        assert.are.equal(1, #slider)
        assert.are.equal(1, #name)
    end)

    local LOCAL_SLIDER_FIELDS = {
        "LocalExposure2012", "LocalContrast2012", "LocalHighlights2012", "LocalShadows2012",
        "LocalWhites2012", "LocalBlacks2012", "LocalTexture", "LocalClarity2012", "LocalDehaze",
        "LocalTemperature", "LocalTint", "LocalSaturation", "LocalSharpness", "LocalLuminanceNoise",
        "LocalMoire", "LocalDefringe",
    }

    local function fieldsAt(value, extra)
        local fields = {}
        for _, name in ipairs(LOCAL_SLIDER_FIELDS) do fields[name] = value end
        for name, item in pairs(extra or {}) do fields[name] = item end
        return fields
    end

    local function entryWithout(overrides, omitted)
        local entry = correction("A", { linearComponent() }, overrides)
        for _, name in ipairs(omitted) do entry[name] = nil end
        return { entry }
    end

    it("treats a zero local adjustment that Lightroom omits as equal", function()
        local expected = oneEntry(linearComponent(), { LocalGlow = 0 })
        local actual = entryWithout({}, { "LocalGlow" })

        assert.are.same({}, Guard.compareEntries(expected, actual))
    end)

    it("treats each of the 16 local sliders at zero as equal when omitted", function()
        local expected = oneEntry(linearComponent(), fieldsAt(0, { LocalGlow = 0 }))

        assert.are.same({}, Guard.compareEntries(expected, entryWithout({}, LOCAL_SLIDER_FIELDS)))
        for _, name in ipairs(LOCAL_SLIDER_FIELDS) do
            assert.are.same({}, Guard.compareEntries(expected, entryWithout(fieldsAt(0, { LocalGlow = 0 }), { name })))
        end
    end)

    it("rejects each of the 16 local sliders at a non-zero value when omitted", function()
        local expected = oneEntry(linearComponent(), fieldsAt(0.25))

        for _, name in ipairs(LOCAL_SLIDER_FIELDS) do
            local problems = Guard.compareEntries(expected, entryWithout(fieldsAt(0.25), { name }))

            assert.are.equal(1, #problems)
            assert.is_truthy(problems[1]:find(name .. ": wrote 0.25, read back nil", 1, true))
        end
    end)

    it("rejects a non-zero local adjustment that reads back missing or different", function()
        local expected = oneEntry(linearComponent(), { LocalGlow = 12 })

        local omitted = Guard.compareEntries(expected, entryWithout({}, { "LocalGlow" }))
        local changed = Guard.compareEntries(expected, oneEntry(linearComponent(), { LocalGlow = 0 }))

        assert.are.equal(1, #omitted)
        assert.is_truthy(omitted[1]:find("LocalGlow: wrote 12, read back nil", 1, true))
        assert.are.equal(1, #changed)
    end)

    it("compares an omitted local adjustment with the slider's own neutral value", function()
        local atNeutral = Guard.compareEntries(oneEntry(linearComponent(), { LocalColorGradeBlending = 50 }),
            entryWithout({}, { "LocalColorGradeBlending" }))
        local atZero = Guard.compareEntries(oneEntry(linearComponent(), { LocalColorGradeBlending = 0 }),
            entryWithout({}, { "LocalColorGradeBlending" }))

        assert.are.same({}, atNeutral)
        assert.are.equal(1, #atZero)
        assert.is_truthy(atZero[1]:find("LocalColorGradeBlending: wrote 0, read back nil", 1, true))
    end)

    it("still rejects an omitted zero outside the local adjustments", function()
        local expected = oneEntry(linearComponent(), { CorrectionAmount = 0 })
        local actual = entryWithout({}, { "CorrectionAmount" })

        assert.are.equal(1, #Guard.compareEntries(expected, actual))
    end)

    it("treats a false boolean that Lightroom omits as equal", function()
        local actualComponent = linearComponent()
        actualComponent.MaskInverted = nil

        assert.are.same({}, Guard.compareEntries(oneEntry(linearComponent()), oneEntry(actualComponent)))
    end)

    it("compares number lists as numbers and plain strings exactly", function()
        local range = function(lum, name)
            return {
                What = "Mask/RangeMask",
                MaskName = name,
                CorrectionRangeMask = { Type = 2, LumRange = lum },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.300000 0.400000 0.500000 0.600000", "Lum 1"))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.7", "Lum 1"))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.6", "Lum 2"))))
    end)

    it("compares dab positions and tolerates a dropped third value", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 1, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2 0.5" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })), oneEntry(brush({ "d 0.1 0.3" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.1 0.2", "d 0.3 0.3" }))))
    end)

    it("ignores a flow token one side lacks but compares it when both have it", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 0.3, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.100000 0.200000" }))))
        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.299998", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.5000", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.1 0.3" }))))
    end)

    it("treats a center weight token like a flow token and compares it when both sides have it", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 1, CenterWeight = 0.4194 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "h 0.4194", "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "h 0.4194", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "h 0.4194", "d 0.1 0.2" })),
            oneEntry(brush({ "h 0.1621", "d 0.100000 0.200000" }))))
    end)

    it("compares the value of a paint and leaves it uncompared on other components", function()
        local brush = function(value)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", MaskValue = value, Dabs = { "d 0.1 0.2" }, Radius = 0.1, Flow = 1,
                    CenterWeight = 0 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush(0.3)), oneEntry(brush(0.300001))))
        local mismatches = Guard.compareEntries(oneEntry(brush(0.3)), oneEntry(brush(1)))
        assert.are.equal(1, #mismatches)
        assert.is_truthy(mismatches[1]:find("MaskValue: wrote 0.3, read back 1", 1, true))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush(0)), oneEntry(brush(1))))

        local gradient = linearComponent({ MaskValue = 1 })
        local readBack = linearComponent({ MaskValue = 0 })
        assert.are.same({}, Guard.compareEntries(oneEntry(gradient), oneEntry(readBack)))
    end)

    it("reports a lost table", function()
        local actual = oneEntry(linearComponent())
        actual[1].CorrectionMasks = nil

        local problems = Guard.compareEntries(oneEntry(linearComponent()), actual)

        assert.are.same({ "masks[1].CorrectionMasks: lost after the write" }, problems)
    end)
end)

describe("GuardedMaskWrite lookups", function()
    local Guard = setup()
    local entries = {
        correction("A", { linearComponent({ MaskID = "T1" }), radialComponent({ MaskID = "T2" }) }, { CorrectionID = "C1" }),
        correction("B", { linearComponent({ MaskID = "T3" }) }, { CorrectionID = "C2" }),
    }

    it("finds a correction by mask id", function()
        local index, entry = Guard.findCorrection(entries, "C2")

        assert.are.equal(2, index)
        assert.are.equal("B", entry.CorrectionName)
        assert.is_nil(Guard.findCorrection(entries, "C9"))
    end)

    it("finds a component by tool id and reports where it is", function()
        local entryIndex, componentIndex, component = Guard.findComponent(entries, "T2")

        assert.are.equal(1, entryIndex)
        assert.are.equal(2, componentIndex)
        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_nil(Guard.findComponent(entries, "T9"))
    end)

    it("builds a new correction with the fields Lightroom needs", function()
        local entry = Guard.newCorrection("Sky", { linearComponent() })

        assert.are.equal("Correction", entry.What)
        assert.are.equal("Sky", entry.CorrectionName)
        assert.is_true(entry.CorrectionActive)
        assert.are.equal(1, entry.CorrectionAmount)
    end)
end)
