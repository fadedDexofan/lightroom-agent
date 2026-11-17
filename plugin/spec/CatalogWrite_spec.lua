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

local function load(imports)
    helper.installImport(imports or {})
    package.loaded.CatalogWrite = nil
    package.loaded.Ledger = nil
    return require 'CatalogWrite', helper.requestContext()
end

describe("CatalogWrite.developSettings", function()
    local function developing(module, target)
        local events = {}
        local photo = {
            applyDevelopSettings = function(_, settings, historyName)
                events[#events + 1] = { apply = settings, history = historyName }
            end,
        }
        local CatalogWrite, context = load({
            LrApplicationView = { getCurrentModuleName = function() return module end },
            LrDevelopController = { stopTracking = function(committed) events[#events + 1] = { flushed = committed } end },
        })
        local catalog = catalogAnswering("executed")
        catalog.getTargetPhoto = function() return target or photo end
        return CatalogWrite, context, catalog, photo, events
    end

    it("commits Develop's pending edits on the photo, then applies the settings under the gate's title", function()
        package.loaded.DevelopSession = nil
        local CatalogWrite, context, catalog, photo, events = developing("develop")

        CatalogWrite.developSettings(context, catalog, photo, "Set Develop Settings", function() return { Exposure2012 = 1 } end)

        assert.are.same({ { flushed = true }, { apply = { Exposure2012 = 1 }, history = "Set Develop Settings" } }, events)
        assert.are.same({ "Set Develop Settings" }, context.ledger:live())
    end)

    it("commits nothing in Library or on another photo, and records no gate when there is nothing to apply", function()
        for _, case in ipairs({ { "library" }, { "develop", {} } }) do
            package.loaded.DevelopSession = nil
            local CatalogWrite, context, catalog, photo, events = developing(case[1], case[2])

            CatalogWrite.developSettings(context, catalog, photo, "Set Mask", function() return nil end)

            assert.are.same({}, events)
            assert.are.same({}, context.ledger:live())
        end
    end)
end)

describe("CatalogWrite.run", function()
    it("waits for write access for WAIT_SECONDS, runs the write and records the gate", function()
        local CatalogWrite, context = load()
        local catalog, calls = catalogAnswering("executed")
        local ran = false

        CatalogWrite.run(context, catalog, "Set Rating", function() ran = true end)

        assert.is_true(ran)
        assert.are.same({ { title = "Set Rating", timeoutParams = { timeout = CatalogWrite.WAIT_SECONDS } } }, calls)
        assert.are.same({ "Set Rating" }, context.ledger:live())
    end)

    it("records nothing for a gate whose function raised", function()
        local CatalogWrite, context = load()
        local catalog = catalogAnswering("executed")

        assert.is_false(pcall(CatalogWrite.run, context, catalog, "Set Rating", function() error("raised", 0) end))
        assert.are.same({}, context.ledger:live())
    end)

    it("records nothing for a gate that wrote nothing", function()
        local CatalogWrite, context = load()
        local catalog = catalogAnswering("executed")

        CatalogWrite.run(context, catalog, "Set Mask", function() return CatalogWrite.NOTHING end)

        assert.are.same({}, context.ledger:live())
    end)

    it("stops with the busy text and records nothing when the catalog stays busy", function()
        local CatalogWrite, context = load()
        local catalog = catalogAnswering("aborted")

        local message = helper.failedOf(function()
            CatalogWrite.run(context, catalog, "Set Rating", function() end)
        end)

        assert.are.equal("The catalog stayed busy with another write for " .. CatalogWrite.WAIT_SECONDS
            .. " s, so Lightroom did not run Set Rating", message)
        assert.are.equal(helper.catalogBusy("Set Rating"), message)
        assert.are.same({}, context.ledger:live())
    end)
end)

describe("CatalogWrite.call", function()
    local function target(log)
        local object = {}
        setmetatable(object, { __index = function(_, method)
            return function(self, ...)
                assert.are.equal(object, self)
                log[#log + 1] = { method, ... }
                return method .. " done"
            end
        end })
        return object
    end

    for _, case in ipairs({
        { method = "applyDevelopSettings", recorded = {} },
        { method = "setRawMetadata", recorded = {} },
        { method = "createCollectionSet", recorded = {} },
        { method = "addPhotos", recorded = {} },
        { method = "createKeyword", recorded = {} },
        { method = "createDevelopSnapshot", recorded = {} },
        { method = "addPhoto", recorded = { "addPhoto" } },
        { method = "applyDevelopPreset", recorded = { "applyDevelopPreset" } },
        { method = "deleteAllEmptyMasks", recorded = { "deleteAllEmptyMasks" } },
        { method = "removeKeyword", recorded = {} },
        { method = "setAttributes", recorded = {} },
        { method = "createCollection", recorded = {} },
        { method = "createSmartCollection", recorded = {} },
        { method = "removePhotos", recorded = {} },
        { method = "addKeyword", recorded = {} },
        { method = "setPropertyForPlugin", recorded = {} },
        { method = "applyDevelopSnapshot", recorded = { "applyDevelopSnapshot" } },
        { method = "deleteDevelopSnapshot", recorded = { "deleteDevelopSnapshot" } },
        { method = "updateAISettings", recorded = { "updateAISettings" } },
        { method = "delete", recorded = { "delete" } },
    }) do
        local how = #case.recorded == 0 and "leaves " .. case.method .. " to its gate's record"
            or "records " .. case.method .. " before it is made"
        it(how, function()
            local CatalogWrite, context = load()
            local log = {}

            assert.are.equal(case.method .. " done", CatalogWrite.call(context, target(log), case.method, 1, "two"))

            assert.are.same({ { case.method, 1, "two" } }, log)
            assert.are.same(case.recorded, context.ledger:live())
        end)
    end

    it("keeps the record of a call the transaction does not cover when the call raises", function()
        local CatalogWrite, context = load()
        local photo = { addPhoto = function() error("raised", 0) end }

        assert.is_false(pcall(CatalogWrite.call, context, photo, "addPhoto"))
        assert.are.same({ "addPhoto" }, context.ledger:live())
    end)
end)

describe("CatalogWrite.invoke and CatalogWrite.develop", function()
    it("records what a call outside a gate writes before making it, and keeps the record when it raises", function()
        local CatalogWrite, context = load()

        assert.are.equal(3, CatalogWrite.invoke(context, "Undo", function(a, b) return a + b end, 1, 2))
        assert.is_false(pcall(CatalogWrite.invoke, context, "copy to /out/a.jpg", function() error("disk full", 0) end))

        assert.are.same({ "Undo", "copy to /out/a.jpg" }, context.ledger:live())
        assert.is_false(context.ledger:controllerWroteSince(0))
    end)

    it("records a controller write as one before calling Develop's controller", function()
        local calls = {}
        local CatalogWrite, context = load({ LrDevelopController = {
            setValue = function(key, value)
                calls[#calls + 1] = { key, value }
                return "set"
            end,
        } })
        local mark = context.ledger:mark()

        assert.are.equal("set", CatalogWrite.develop(context, "setValue", "Exposure", 1))

        assert.are.same({ { "Exposure", 1 } }, calls)
        assert.are.same({ "setValue" }, context.ledger:live())
        assert.is_true(context.ledger:controllerWroteSince(mark))
    end)
end)

describe("CatalogWrite.createFolder", function()
    local function folders(present, refused)
        local created = {}
        return {
            LrFileUtils = {
                exists = function(path) return present[path] or false end,
                createAllDirectories = function(path)
                    created[#created + 1] = path
                    local folder = path
                    while folder and not present[folder] do
                        if not refused[folder] then present[folder] = "directory" end
                        folder = folder:match("^(.+)/[^/]+$")
                    end
                end,
            },
            LrPathUtils = { parent = function(path) return path:match("^(.+)/[^/]+$") end },
        }, created
    end

    it("records a folder it creates, and nothing for a path that already exists or a folder still missing after", function()
        local imports, created = folders({ ["/out"] = "directory", ["/file"] = "file" }, { ["/readonly"] = true, ["/readonly/new"] = true })
        local CatalogWrite, context = load(imports)

        for _, path in ipairs({ "/out", "/file", "/out/new", "/readonly/new" }) do
            CatalogWrite.createFolder(context, path)
        end

        assert.are.same({ "/out/new", "/readonly/new" }, created)
        assert.are.same({ "/out/new" }, context.ledger:live())
    end)

    it("keeps the record of a folder still missing after it created a missing parent, and answers the topmost folder"
        .. " it created", function()
        local imports = folders({ ["/out"] = "directory" }, { ["/out/set/day"] = true })
        local CatalogWrite, context = load(imports)

        local topmost = CatalogWrite.createFolder(context, "/out/set/day")

        assert.are.same({ "/out/set/day" }, context.ledger:live())
        assert.are.equal("/out/set", topmost)
    end)
end)

describe("Develop controller writes", function()
    local READS_AND_VIEW = { stopTracking = true, setSelectedSpotIndex = true }

    local function isReadOrView(name)
        return READS_AND_VIEW[name] or name:match("^get") or name:match("^select") or name:match("^goTo")
    end

    it("go only through CatalogWrite.develop", function()
        local directory = "plugin/LightroomMCP.lrplugin/"
        local direct = {}
        for file in io.popen('ls "' .. directory .. '"'):lines() do
            if file:match("%.lua$") and file ~= "CatalogWrite.lua" then
                local source = assert(io.open(directory .. file)):read("a"):gsub("%-%-[^\n]*", "")
                for name in source:gmatch("LrDevelopController%.([%w_]+)") do
                    if not isReadOrView(name) then direct[#direct + 1] = file .. ": " .. name end
                end
                for before in source:gmatch("(.?.?.?.?.?)LrDevelopController%[") do
                    if before ~= "type(" then direct[#direct + 1] = file .. ": LrDevelopController[...]" end
                end
            end
        end
        assert.are.same({}, direct)
    end)
end)
