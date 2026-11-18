local helper = require 'spec_helper'

local Store = require 'fake_mask_store'

local linearComponent = Store.linearComponent
local radialComponent = Store.radialComponent
local correction = Store.correction

local HOME = "/Users/tester"
local CERTIFICATION_FILE = HOME .. "/.config/lightroom-agent/mask-certification.json"
local THROWAWAY_CATALOG = HOME .. "/Pictures/lragent-live-1/lragent-live-1.lrcat"
local THROWAWAY_MARKER = HOME .. "/Pictures/lragent-live-1/lragent-live-catalog.json"
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
    helper.installImport({
        LrApplicationView = { getCurrentModuleName = function() return "library" end },
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

describe("GuardedMaskWrite.apply admission", function()
    it("writes when the certification names the running build and the photo's process version", function()
        local Guard, catalog, photo, state = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
            entries = { correction("A", { linearComponent() }) },
        })

        Guard.apply(helper.requestContext(), catalog, photo, { description = "x", build = appendGradient(radialComponent()) })

        assert.are.equal(1, #state.writes)
    end)

    it("reads the catalog path and the certification files before the write gate, not inside it", function()
        local Guard, catalog, photo, state = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
        })
        local insideGate = {}
        local getPath = catalog.getPath
        catalog.getPath = function(...)
            insideGate[#insideGate + 1] = state.insideWrite == true
            return getPath(...)
        end

        Guard.apply(helper.requestContext(), catalog, photo, { description = "x", build = appendGradient(radialComponent()) })

        assert.are.same({ false }, insideGate)
        assert.are.equal(1, #state.writes)
    end)

    it("refuses, writing nothing, a photo whose process version the certification did not exercise", function()
        local Guard, catalog, photo, state = setup({
            catalogPath = PERSONAL_CATALOG,
            files = { [CERTIFICATION_FILE] = certification(RUNNING_BUILD) },
            processVersion = "11.0",
        })

        local message = helper.failedOf(function()
            Guard.apply(helper.requestContext(), catalog, photo, { description = "x", build = appendGradient(radialComponent()) })
        end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
        assert.is_nil(message:find("othing was", 1, true))
        assert.are.equal(0, #state.writes)
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
    }) do
        it("admits a constructing write beside an entry with " .. case.held .. " and leaves that entry byte-identical", function()
            local Guard, catalog, photo, state = setup({ entries = { case.entry } })
            local held = Store.clone(state.entries[1])

            Guard.apply(helper.requestContext(), catalog, photo, { description = "Create gradient mask", build = appendGradient(radialComponent()) })

            assert.are.equal(1, #state.writes)
            assert.are.equal(2, #state.entries)
            assert.are.same(held, state.entries[1])
        end)
    end

    for _, case in ipairs({
        { unnamed = "a mask", strip = function(entry) entry.CorrectionID, entry.CorrectionSyncID = nil, nil end,
            text = 'mask 1 ("X") has no id yet' },
        { unnamed = "a tool of a mask", strip = function(entry)
            entry.CorrectionMasks[1].MaskID, entry.CorrectionMasks[1].MaskSyncID = nil, nil
        end, text = 'a tool of mask 1 ("X") has no id yet' },
    }) do
        it("refuses a constructing write while " .. case.unnamed .. " on the photo has no id, writing nothing", function()
            local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent() }) } })
            case.strip(state.entries[1])
            local held = Store.clone(state.entries[1])

            local message = helper.failedOf(function()
                Guard.apply(helper.requestContext(), catalog, photo, { description = "Create gradient mask", build = appendGradient(radialComponent()) })
            end)

            assert.is_truthy(message:find(case.text .. "; Lightroom names a mask a few seconds after it is written; call again", 1, true))
            assert.are.equal(0, #state.writes)
            assert.are.same({ held }, state.entries)
        end)
    end

    it("validates an existing entry a build changed in place", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X" }) } })

        local message = helper.failedOf(function()
            Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to mask", build = function(entries)
                entries[1].CorrectionMasks[2] = { What = "Mask/RangeMask", MaskActive = true,
                    CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { "a", "b" } } }
                return entries
            end })
        end)

        assert.is_truthy(message:find("exactly one PointModels entry", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("checks only what the call changed in an existing entry, admitting its Lightroom-only fields", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X", ExtendedMainCurve = { "0,0", "40,30", "255,255" } }) } })

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to mask", build = function(entries)
            entries[1].CorrectionMasks[2] = radialComponent()
            return entries
        end })

        assert.are.equal(2, #state.entries[1].CorrectionMasks)
        assert.are.same({ "0,0", "40,30", "255,255" }, state.entries[1].ExtendedMainCurve)
    end)

    local twoSamples = { Type = 1, ColorAmount = 0.5, PointModels = { "0.1 0.4 0.5 0.2 0.3 0", "0.6 0.5 0.4 0.7 0.8 0" } }

    it("finds a held entry by its CorrectionID when the build moved it to another position", function()
        local held = correction("X", { rangeComponent(twoSamples) }, { CorrectionID = "X" })
        local Guard, catalog, photo, state = setup({ entries = {
            correction("A", { linearComponent({ MaskID = "AT1", MaskSyncID = "SAT1" }) }, { CorrectionID = "A" }), held,
        } })
        local stored = Store.clone(state.entries[2])

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Replace mask", build = function(entries)
            table.remove(entries, 1)
            entries[#entries + 1] = correction("New", { radialComponent() })
            return entries
        end })

        assert.are.equal(1, #state.writes)
        assert.are.same(stored, state.entries[1])
    end)

    it("leaves a held Lightroom-made component unvalidated when a component is appended beside it", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { rangeComponent(twoSamples) },
            { CorrectionID = "X" }) } })
        local stored = Store.clone(state.entries[1].CorrectionMasks[1])

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to mask", build = function(entries)
            entries[1].CorrectionMasks[2] = radialComponent()
            return entries
        end })

        assert.are.equal(1, #state.writes)
        assert.are.same(stored, state.entries[1].CorrectionMasks[1])
    end)

    it("refuses a change to an existing entry that breaks the pinned format, writing nothing", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("X", { linearComponent({ MaskID = "XT1", MaskSyncID = "SXT1" }) },
            { CorrectionID = "X" }) } })

        local message = helper.failedOf(function()
            Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to mask", build = function(entries)
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

            local message = helper.failedOf(function()
                Guard.apply(helper.requestContext(), catalog, photo, { description = "Create gradient mask", build = appendGradient(linearComponent()) })
            end)

            assert.is_truthy(message:find("previous masks were restored", 1, true), message)
            assert.are.equal(2, #state.writes)
            assert.are.same({ held }, state.entries)
        end)
    end
end)

describe("GuardedMaskWrite.apply", function()
    local function applyAppend(Guard, catalog, photo, component, extra, context)
        local spec = {
            description = "Test write",
            build = appendGradient(component),
        }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return Guard.apply(context or helper.requestContext(), catalog, photo, spec)
    end

    it("writes the whole array, reads it back and returns the stored entries", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(1, #state.writes)
        assert.are.equal(2, #state.writes[1])
        assert.are.equal("OLD", state.writes[1][1].CorrectionID)
        assert.are.equal("OLDT1", state.writes[1][1].CorrectionMasks[1].MaskID)
        assert.are.equal(2, #result.entries)
        assert.are.equal(state.writes[1][2].CorrectionID, result.entries[2].CorrectionID)
        assert.are.equal(state.writes[1][2].CorrectionMasks[1].MaskID, result.entries[2].CorrectionMasks[1].MaskID)
        assert.are.equal(1, #result.previous)
        assert.are.equal(0, state.writesOutsideGate)
        assert.are.equal(0, state.readsOutsideGate)
    end)

    it("accepts a clear that Lightroom stores as no mask key at all, without a rollback", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        local result = Guard.apply(helper.requestContext(), catalog, photo, { description = "Clear", build = function() return {} end })

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

        local message = helper.failedOf(function()
            Guard.apply(helper.requestContext(), catalog, photo, {
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

    it("records no write for a build that changes nothing, so a refusal after it in the same call is failed", function()
        local Guard, catalog, photo, state = setup()
        local context = helper.requestContext()

        local message = helper.failedOf(function()
            Guard.submit(context, catalog, photo, { description = "Nothing to change", build = function() return nil end })
            require('Reply').refuse("stopped after an unchanged build")
        end)

        assert.are.equal("stopped after an unchanged build", message)
        assert.are.equal(0, #state.writes)
    end)

    it("waits for a read-back that lags behind the write", function()
        local Guard, catalog, photo, state = setup({ lagReadsAfterWrite = 3 })

        applyAppend(Guard, catalog, photo, linearComponent())

        assert.is_true(state.sleeps >= 3)
        assert.are.equal(1, #state.writes)
    end)

    it("refuses an uncertified Lightroom before writing masks", function()
        local Guard, catalog, photo, state = setup({ catalogPath = PERSONAL_CATALOG, files = {} })

        helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.are.equal(0, #state.writes)
    end)

    it("refuses a new component with a string where a number belongs, writing nothing", function()
        local Guard, catalog, photo, state = setup()

        local message = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ FullY = "0.2" }))
        end)

        assert.is_truthy(message:find("FullY must be a number", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a boolean where a number belongs and a NaN", function()
        local Guard, catalog, photo, state = setup()

        local booleanMessage = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ ZeroX = true }))
        end)
        local nanMessage = helper.failedOf(function()
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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, component) end)

        assert.is_truthy(message:find("missing FullY", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a component with an unknown or absent type", function()
        local Guard, catalog, photo, state = setup()
        local absent = linearComponent()
        absent.What = nil

        local unknown = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ What = "Mask/Nope" }))
        end)
        local missing = helper.failedOf(function() applyAppend(Guard, catalog, photo, absent) end)

        assert.is_truthy(unknown:find("unknown mask type Mask/Nope", 1, true))
        assert.is_truthy(missing:find("unknown mask type nil", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a color range with two samples and one with an unsupported type", function()
        local Guard, catalog, photo, state = setup()
        local function range(rangeTable)
            return { What = "Mask/RangeMask", MaskActive = true, CorrectionRangeMask = rangeTable }
        end

        local two = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 1, ColorAmount = 0.4, PointModels = { "a", "b" } }))
        end)
        local unsupported = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 3, DepthRange = "0 0 1 1" }))
        end)

        assert.is_truthy(two:find("exactly one PointModels entry", 1, true))
        assert.is_truthy(unsupported:find("unsupported range Type 3", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("fails without a rollback write when the catalog stays busy with another write", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
        })
        catalog.withWriteAccessDo = function(_, _, _, timeoutParams)
            if timeoutParams then return "aborted" end
        end

        local class, message = helper.outcomeOf(function(context)
            applyAppend(Guard, catalog, photo, linearComponent(), nil, context)
        end)

        assert.are.same({ "failed", helper.catalogBusy("Test write") }, { class, message })
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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("Lightroom rejected the write", 1, true))
        assert.are.equal(1, #state.writes)
        assert.are.same({}, state.writes[1])
    end)

    it("rolls back when the check of the saved read-back reports a problem", function()
        local Guard, catalog, photo, state = setup()

        local message = helper.failedOf(function()
            applyAppend(Guard, catalog, photo, linearComponent(), {
                readBackProblem = function() return "no depth map" end,
            })
        end)

        assert.is_truthy(message:find("no depth map", 1, true))
        assert.are.equal(2, #state.writes)
        assert.are.same({}, state.writes[2])
    end)

    it("names each entry and top-level component it adds in Lightroom's id form and keeps the ids already there", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Test write", build = function(entries)
            entries[1].CorrectionMasks[2] = linearComponent()
            entries[2] = correction("Brush", { Store.brushComponent() })
            return entries
        end })

        local written = state.writes[1]
        local GUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
        assert.are.equal("OLD", written[1].CorrectionID)
        assert.are.equal("OLDT1", written[1].CorrectionMasks[1].MaskID)
        local added = { written[1].CorrectionMasks[2].MaskID, written[2].CorrectionID, written[2].CorrectionMasks[1].MaskID }
        for index = 1, 3 do
            assert.is_string(added[index])
            assert.matches(GUID, added[index])
            assert.are.equal(added[index]:upper(), added[index])
        end
        assert.is_nil(written[2].CorrectionMasks[1].Masks[1].MaskID)
    end)

    it("hands the check of the saved read-back the stored entries", function()
        local Guard, catalog, photo = setup()
        local seen

        applyAppend(Guard, catalog, photo, linearComponent(), {
            readBackProblem = function(entries) seen = entries end,
        })

        assert.is_string(seen[1].CorrectionID)
        assert.is_string(seen[1].CorrectionMasks[1].MaskID)
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

        local message = helper.failedOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("masks[1], left alone by this call, changed at CorrectionMasks.1.What", 1, true), message)
        assert.are.equal(2, #state.writes)
    end)
end)

describe("GuardedMaskWrite.apply reading back a constructed AI component", function()
    local function intersect()
        return { What = "Mask/Image", MaskVersion = 1, MaskSubType = 1, MaskName = "Subject 1", MaskActive = true,
            MaskBlendMode = 1, MaskValue = 1, MaskInverted = true }
    end

    for _, case in ipairs({
        { field = "MaskInverted", stored = nil },
        { field = "MaskBlendMode", stored = 0 },
        { field = "MaskValue", stored = 0.5 },
        { field = "MaskSubType", stored = 2 },
    }) do
        it("restores the photo when Lightroom stores its " .. case.field .. " otherwise", function()
            local Guard, catalog, photo, state = setup({
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[#stored].CorrectionMasks[1][case.field] = case.stored end
                    return stored
                end,
            })

            local message = helper.failedOf(function()
                Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to Mask",
                    build = appendGradient(intersect()) })
            end)

            assert.is_truthy(message:find(case.field, 1, true), message)
            assert.are.equal(2, #state.writes)
        end)
    end

    it("does not compare the fields Lightroom computes for the photo", function()
        local Guard, catalog, photo, state = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then
                    local component = stored[#stored].CorrectionMasks[1]
                    component.FullMaskSize, component.Origin = "1200,800", "0,0"
                    component.WholeImageArea, component.ReferencePoint = "0 0 1200 800", "0.4 0.6"
                end
                return stored
            end,
        })
        local sent = intersect()
        sent.FullMaskSize, sent.Origin, sent.WholeImageArea, sent.ReferencePoint = "6000,4000", "10,20", "0 0 6000 4000", "0.5 0.5"

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to Mask", build = appendGradient(sent) })

        assert.are.equal(1, #state.writes)
    end)

    it("accepts the component when Lightroom keeps every field it was written with", function()
        local Guard, catalog, photo, state = setup()

        Guard.apply(helper.requestContext(), catalog, photo, { description = "Add to Mask", build = appendGradient(intersect()) })

        assert.are.equal(1, #state.writes)
    end)
end)

describe("GuardedMaskWrite read-back of a constructed mask", function()
    local function named(entries)
        for entryIndex, entry in ipairs(entries) do
            entry.CorrectionID = entry.CorrectionID or ("A" .. entryIndex)
            for index, component in ipairs(entry.CorrectionMasks or {}) do
                component.MaskID = component.MaskID or (entry.CorrectionID .. "T" .. index)
            end
        end
        return entries
    end

    local function readBackProblems(expected, actual)
        expected, actual = named(Store.clone(expected)), named(Store.clone(actual))
        local guard, catalog, photo = setup({ transformWrite = function(stored, writeNumber)
            if writeNumber == 1 then return Store.clone(actual) end
            return stored
        end })
        local ok, err = pcall(guard.apply, helper.requestContext(), catalog, photo,
            { description = "Read-back", build = function() return Store.clone(expected) end })
        if ok then return {} end
        local message = require('Reply').messageOf(err)
        local summary = assert(message:match("previous masks were restored: (.*)$"), message)
        local problems = {}
        for problem in (summary .. "; "):gmatch("(.-); ") do problems[#problems + 1] = problem end
        return problems
    end

    local function oneEntry(component, overrides)
        return { correction("A", { component }, overrides) }
    end

    it("accepts numbers within 1e-5 and rejects 1e-4", function()
        local expected = oneEntry(linearComponent({ FullY = 0.2 }))

        assert.are.same({}, readBackProblems(expected, oneEntry(linearComponent({ FullY = 0.200009 }))))
        assert.are_not.same({}, readBackProblems(expected, oneEntry(linearComponent({ FullY = 0.2001 }))))
    end)

    it("does not compare the fields Lightroom fills, Flipped included", function()
        local expected = oneEntry(radialComponent({ Flipped = false }))
        local actual = oneEntry(radialComponent({ Flipped = true, MaskSyncID = "S" }), {
            CorrectionSyncID = "CS",
            CorrectionReferenceX = 0.9,
            LocalCurveRefineSaturation = 100,
        })

        assert.are.same({}, readBackProblems(expected, actual))
    end)

    it("requires the written mask and component ids back", function()
        local expected = oneEntry(radialComponent({ MaskID = "AT1" }), { CorrectionID = "A" })

        assert.are.same({
            "masks[1].CorrectionID: wrote A, read back Z",
            "masks[1].CorrectionMasks[1].MaskID: wrote AT1, read back x",
        }, readBackProblems(expected, oneEntry(radialComponent({ MaskID = "x" }), { CorrectionID = "Z" })))
    end)

    it("catches a changed local slider and a changed name", function()
        local expected = oneEntry(linearComponent())

        local slider = readBackProblems(expected, oneEntry(linearComponent(), { LocalExposure2012 = 0 }))
        local name = readBackProblems(expected, oneEntry(linearComponent(), { CorrectionName = "B" }))

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

        assert.are.same({}, readBackProblems(expected, actual))
    end)

    it("treats each of the 16 local sliders at zero as equal when omitted", function()
        local expected = oneEntry(linearComponent(), fieldsAt(0, { LocalGlow = 0 }))

        assert.are.same({}, readBackProblems(expected, entryWithout({}, LOCAL_SLIDER_FIELDS)))
        for _, name in ipairs(LOCAL_SLIDER_FIELDS) do
            assert.are.same({}, readBackProblems(expected, entryWithout(fieldsAt(0, { LocalGlow = 0 }), { name })))
        end
    end)

    it("rejects each of the 16 local sliders at a non-zero value when omitted", function()
        local expected = oneEntry(linearComponent(), fieldsAt(0.25))

        for _, name in ipairs(LOCAL_SLIDER_FIELDS) do
            local problems = readBackProblems(expected, entryWithout(fieldsAt(0.25), { name }))

            assert.are.equal(1, #problems)
            assert.is_truthy(problems[1]:find(name .. ": wrote 0.25, read back nil", 1, true))
        end
    end)

    it("rejects a non-zero local adjustment that reads back missing or different", function()
        local expected = oneEntry(linearComponent(), { LocalGlow = 12 })

        local omitted = readBackProblems(expected, entryWithout({}, { "LocalGlow" }))
        local changed = readBackProblems(expected, oneEntry(linearComponent(), { LocalGlow = 0 }))

        assert.are.equal(1, #omitted)
        assert.is_truthy(omitted[1]:find("LocalGlow: wrote 12, read back nil", 1, true))
        assert.are.equal(1, #changed)
    end)

    it("compares an omitted local adjustment with the slider's own neutral value", function()
        local atNeutral = readBackProblems(oneEntry(linearComponent(), { LocalColorGradeBlending = 50 }),
            entryWithout({}, { "LocalColorGradeBlending" }))
        local atZero = readBackProblems(oneEntry(linearComponent(), { LocalColorGradeBlending = 0 }),
            entryWithout({}, { "LocalColorGradeBlending" }))

        assert.are.same({}, atNeutral)
        assert.are.equal(1, #atZero)
        assert.is_truthy(atZero[1]:find("LocalColorGradeBlending: wrote 0, read back nil", 1, true))
    end)

    it("still rejects an omitted zero outside the local adjustments", function()
        local expected = oneEntry(linearComponent(), { CorrectionAmount = 0 })
        local actual = entryWithout({}, { "CorrectionAmount" })

        assert.are.equal(1, #readBackProblems(expected, actual))
    end)

    it("treats a false boolean that Lightroom omits as equal", function()
        local actualComponent = linearComponent()
        actualComponent.MaskInverted = nil

        assert.are.same({}, readBackProblems(oneEntry(linearComponent()), oneEntry(actualComponent)))
    end)

    it("compares number lists as numbers and plain strings exactly", function()
        local range = function(lum, name)
            return {
                What = "Mask/RangeMask",
                MaskName = name,
                CorrectionRangeMask = { Type = 2, LumRange = lum },
            }
        end

        assert.are.same({}, readBackProblems(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.300000 0.400000 0.500000 0.600000", "Lum 1"))))
        assert.are_not.same({}, readBackProblems(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.7", "Lum 1"))))
        assert.are_not.same({}, readBackProblems(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.6", "Lum 2"))))
    end)

    it("compares dab positions and tolerates a dropped third value", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 1, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, readBackProblems(oneEntry(brush({ "d 0.1 0.2 0.5" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are_not.same({}, readBackProblems(oneEntry(brush({ "d 0.1 0.2" })), oneEntry(brush({ "d 0.1 0.3" }))))
        assert.are_not.same({}, readBackProblems(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.1 0.2", "d 0.3 0.3" }))))
    end)

    it("ignores a flow token one side lacks but compares it when both have it", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 0.3, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, readBackProblems(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are.same({}, readBackProblems(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.100000 0.200000" }))))
        assert.are.same({}, readBackProblems(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.299998", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, readBackProblems(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.5000", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, readBackProblems(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.1 0.3" }))))
    end)

    it("treats a center weight token like a flow token and compares it when both sides have it", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 1, CenterWeight = 0.4194 } },
            }
        end

        assert.are.same({}, readBackProblems(oneEntry(brush({ "h 0.4194", "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are.same({}, readBackProblems(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "h 0.4194", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, readBackProblems(oneEntry(brush({ "h 0.4194", "d 0.1 0.2" })),
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

        assert.are.same({}, readBackProblems(oneEntry(brush(0.3)), oneEntry(brush(0.300001))))
        local mismatches = readBackProblems(oneEntry(brush(0.3)), oneEntry(brush(1)))
        assert.are.equal(1, #mismatches)
        assert.is_truthy(mismatches[1]:find("MaskValue: wrote 0.3, read back 1", 1, true))
        assert.are_not.same({}, readBackProblems(oneEntry(brush(0)), oneEntry(brush(1))))

        local gradient = linearComponent({ MaskValue = 1 })
        local readBack = linearComponent({ MaskValue = 0 })
        assert.are.same({}, readBackProblems(oneEntry(gradient), oneEntry(readBack)))
    end)

    it("reports a lost table", function()
        local actual = oneEntry(linearComponent())
        actual[1].CorrectionMasks = nil

        local problems = readBackProblems(oneEntry(linearComponent()), actual)

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
