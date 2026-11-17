local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local COMPUTED_KEYS = { "MaskDigest", "InputDigest", "LocalInputDigest" }

local function gradientCorrection(id)
    return Store.correction("Sky", {
        Store.linearComponent({ MaskID = id .. "T1" }),
    }, { CorrectionID = id })
end

local function aiComponentOf(entry)
    for _, component in ipairs(entry.CorrectionMasks) do
        if component.What == "Mask/Image" then return component end
    end
    return nil
end

local function newAIEntry(photoId)
    return {
        What = "Correction",
        CorrectionName = "Mask",
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionID = "mask-" .. photoId,
        CorrectionSyncID = "sync-" .. photoId,
        LocalExposure2012 = 0,
        CorrectionMasks = {
            {
                What = "Mask/Image",
                MaskActive = true,
                MaskInverted = false,
                MaskBlendMode = 0,
                MaskID = "tool-" .. photoId,
                MaskSyncID = "tool-sync-" .. photoId,
                MaskDigest = "mask-digest-" .. photoId,
                InputDigest = "input-digest-" .. photoId,
                LocalInputDigest = "local-input-digest-" .. photoId,
                Origin = "origin-" .. photoId,
            },
        },
    }
end

local function setup(opts)
    opts = opts or {}
    local specs = opts.photos or { { id = "1" }, { id = "2" }, { id = "3" } }
    local photos, stores, storeOf, specOf = {}, {}, {}, {}
    local clock = { now = 0 }
    local calls = {
        modules = {},
        created = {},
        updates = {},
        updateSawDigests = {},
        setValue = {},
        deleted = {},
        writeDescriptions = {},
    }

    for _, spec in ipairs(specs) do
        local photo = helper.fakePhoto({
            id = spec.id,
            path = "/" .. spec.id .. ".jpg",
        })
        local store = Store.attach(photo, spec)
        stores[spec.id] = store
        storeOf[photo] = store
        specOf[photo] = spec
        photos[#photos + 1] = photo
        if opts.withoutUpdateApi then
            photo.updateAISettings = nil
        else
            photo.updateAISettings = function()
                local mode = spec.aiMode or "ok"
                local components = {}
                for _, entry in ipairs(store.entries) do
                    components[#components + 1] = aiComponentOf(entry)
                end
                local newest = components[#components]
                calls.updates[#calls.updates + 1] = spec.id
                if opts.onUpdate then opts.onUpdate() end
                calls.updateSawDigests[spec.id] = newest ~= nil and newest.MaskDigest ~= nil
                clock.now = clock.now + (opts.secondsPerUpdate or 0)
                if mode == "fail" then error("AI update failed") end
                if mode == "ok" then
                    for _, component in ipairs(components) do
                        if component.MaskDigest == nil then
                            for _, key in ipairs(COMPUTED_KEYS) do component[key] = key .. "-" .. spec.id end
                            component.Origin = "origin-" .. spec.id
                        end
                    end
                end
            end
        end
    end

    local active = photos[opts.startIndex or #photos]
    local startPhoto = active
    local module = "library"

    local catalog = helper.fakeCatalog({ photos = photos })
    for _, spec in ipairs(specs) do
        Store.trackGates(stores[spec.id], catalog)
    end
    catalog.getTargetPhoto = function() return active end
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        active = photo
    end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    local function addDevelopMask(photo, subtype)
        local spec = specOf[photo]
        local behavior = spec.createBehavior or "append"
        calls.created[#calls.created + 1] = { photo = spec.id, subtype = subtype }
        if behavior == "nothing" then return end
        local store = storeOf[photo]
        store.entries[#store.entries + 1] = newAIEntry(spec.id)
        if behavior == "double" then
            local second = newAIEntry(spec.id .. "b")
            store.entries[#store.entries + 1] = second
        end
    end

    local values = {}
    local selectedMask
    local selectedTool = "loupe"
    local controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            return Store.maskListOf(storeOf[active].entries)
        end,
        selectMask = function(id) selectedMask = id end,
        getSelectedMask = function() return selectedMask end,
        goToMasking = function() end,
        selectMaskTool = function() end,
        selectTool = function(name) selectedTool = name end,
        getSelectedTool = function() return selectedTool end,
        createNewMask = function(_, subtype)
            if module ~= "develop" then error("Develop module is not active") end
            addDevelopMask(active, subtype)
        end,
        deleteMask = function(id)
            calls.deleted[#calls.deleted + 1] = id
            local store = storeOf[active]
            for index = #store.entries, 1, -1 do
                if store.entries[index].CorrectionID == id then table.remove(store.entries, index) end
            end
        end,
        setValue = function(param, value)
            calls.setValue[#calls.setValue + 1] = { photo = specOf[active].id, param = param, value = value }
            local entries = storeOf[active].entries
            local last = entries[#entries]
            if last then last["Local" .. param] = value end
            values[param] = value
        end,
        getValue = function(param) return values[param] or 0 end,
        stopTracking = function() end,
        setTrackingDelay = function() end,
        setMultipleAdjustmentThreshold = function() end,
    }
    if opts.withoutCreateApi then controller.createNewMask = nil end

    if opts.unsavedTemplate then
        for _, photo in ipairs(photos) do
            local original = photo.getDevelopSettings
            photo.getDevelopSettings = function(self)
                local settings = original(self)
                local kept = {}
                for _, entry in ipairs(settings.MaskGroupBasedCorrections or {}) do
                    if tostring(entry.CorrectionID):sub(1, 5) ~= "mask-" then kept[#kept + 1] = entry end
                end
                settings.MaskGroupBasedCorrections = #kept > 0 and kept or nil
                return settings
            end
        end
    end

    helper.admitMaskWrites(opts.maskWrites)

    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                calls.modules[#calls.modules + 1] = name
            end,
        },
        LrDate = { currentTime = function() return clock.now end },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({
        "HandlerMaskBatch", "HandlerMaskCreate", "GuardedMaskWrite", "AIMaskCompute", "DevelopSession", "DevelopBatch", "AIMaskData", "Log",
        "MaskSelection", "MaskCreationAdjustments",
    }) do
        package.loaded[name] = nil
    end
    local Handler = require 'HandlerMaskBatch'
    return Handler, {
        calls = calls,
        stores = stores,
        catalog = catalog,
        activeIs = function(photo) return active == photo end,
        startPhoto = startPhoto,
        module = function() return module end,
        clock = clock,
    }
end

local function resultFor(response, photoId)
    for _, result in ipairs(response.data and response.data.results or {}) do
        if result.photo_id == photoId then return result end
    end
    return nil
end

local function itemFor(items, photoId)
    for _, item in ipairs(items or {}) do
        if item.photo_id == photoId then return item end
    end
    return nil
end

local function entriesOf(world, photoId)
    return world.stores[photoId].entries
end

describe("HandlerMaskBatch.createMaskBatch", function()
    it("keeps other Develop-driving calls out until the targets are done", function()
        local blocked = {}
        local Handler = setup({
            onUpdate = function()
                blocked[#blocked + 1] = helper.refusalOf(function()
                    require('DevelopSession').run(helper.requestContext(nil, { title = "create_gradient_mask" }), {}, false, function() end)
                end)
            end,
        })

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal(2, #blocked)
        assert.truthy(blocked[1]:find("create_mask_batch is already running", 1, true))
    end)

    it("cancel keeps the source mask and leaves the later photos untouched", function()
        local Handler, world = setup({})
        local progress = {}
        local context = helper.requestContext(nil, {
            isCanceled = function() return #world.calls.created >= 1 end,
            report = function(_, completed, total, message)
                progress[#progress + 1] = { completed, total, message }
            end,
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" }, context)

        assert.are.same({ { 0, 3, "1" }, { 1, 3, "Done" } }, progress)
        assert.are.same({ "created" }, { r.data.results[1].status })
        assert.are.equal(1, #r.data.results)
        assert.are.same({ "2", "3" }, r.remaining)
        assert.are.equal(1, #entriesOf(world, "1"))
        assert.are.equal(0, #entriesOf(world, "2"))
        assert.are.equal(0, #entriesOf(world, "3"))
        assert.are.same({}, world.calls.updates)
        assert.are.same({ "develop", "library" }, world.calls.modules)
    end)

    it("creates the mask in Develop on the first photo and reports the others as computed, content not verified", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.is_nil(r.failed)
        assert.is_nil(r.unknown)
        assert.is_nil(r.remaining)
        assert.is_nil(r.not_found)
        assert.are.same({ { photo = "1", subtype = "sky" } }, world.calls.created)
        assert.are.same({ "created", "computed", "computed" },
            { resultFor(r, "1").status, resultFor(r, "2").status, resultFor(r, "3").status })
        for _, id in ipairs({ "1", "2", "3" }) do
            assert.is_not_nil(resultFor(r, id).mask_id)
            assert.is_nil(resultFor(r, id).created)
        end
        assert.are.equal("mask-1", resultFor(r, "1").mask_id)
    end)

    it("strips the computed digests before writing to a target and recomputes it afterwards", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        for _, id in ipairs({ "2", "3" }) do
            local written = world.stores[id].writes[1]
            local component = aiComponentOf(written[#written])
            for _, key in ipairs(COMPUTED_KEYS) do
                assert.is_nil(component[key], id .. " was written with " .. key)
            end
            assert.is_false(world.calls.updateSawDigests[id])
        end
    end)

    it("calls updateAISettings once per target and never on the source photo", function()
        local Handler, world = setup({ photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" } } })

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3", "4" }, type = "background" })

        assert.are.same({ "2", "3", "4" }, world.calls.updates)
    end)

    it("gives each target its own computed mask data, not the source's", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        assert.are.equal("origin-1", aiComponentOf(entriesOf(world, "1")[1]).Origin)
        for _, id in ipairs({ "2", "3" }) do
            local component = aiComponentOf(entriesOf(world, id)[1])
            assert.are.equal("origin-" .. id, component.Origin)
            assert.are.equal("MaskDigest-" .. id, component.MaskDigest)
            assert.are.equal("InputDigest-" .. id, component.InputDigest)
        end
    end)

    it("gives targets fresh ids instead of the source mask ids", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local written = world.stores["2"].writes[1][1]
        assert.is_nil(written.CorrectionID)
        assert.is_nil(written.CorrectionMasks[1].MaskID)
        assert.are.equal("C1", entriesOf(world, "2")[1].CorrectionID)
        assert.are.equal("C1", resultFor(r, "2").mask_id)
    end)

    it("carries the same local adjustments to every photo", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({
            photo_ids = { "1", "2", "3" },
            type = "sky",
            adjustments = { local_Exposure = -1.5, local_Contrast = 20 },
        })

        assert.is_nil(r.adjustments)
        for _, id in ipairs({ "1", "2", "3" }) do
            assert.are.equal(-1.5, entriesOf(world, id)[1]["Locallocal_Exposure"])
            assert.are.equal(20, entriesOf(world, id)[1]["Locallocal_Contrast"])
            assert.are.equal(0, entriesOf(world, id)[1]["Locallocal_Shadows"])
        end
    end)

    it("keeps the masks already on a target", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", entries = { gradientCorrection("C1") } } },
        })

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local entries = entriesOf(world, "2")
        assert.are.equal(2, #entries)
        assert.are.equal("C1", entries[1].CorrectionID)
        assert.are.equal("Mask/Gradient", entries[1].CorrectionMasks[1].What)
        assert.are.equal("Mask/Image", entries[2].CorrectionMasks[1].What)
        assert.are.equal("C2", entries[2].CorrectionID)
    end)

    it("restores the module and the user's selection", function()
        local Handler, world = setup({ startIndex = 3 })

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.same({ "develop", "library" }, world.calls.modules)
        assert.are.equal("library", world.module())
        assert.is_true(world.activeIs(world.startPhoto))
    end)

    it("reports a target Lightroom did not finish computing as failed, removes its mask and finishes the batch", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "nothing" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.is_nil(r.remaining)
        assert.is_nil(resultFor(r, "2"))
        local failed = itemFor(r.failed, "2")
        assert.truthy(failed.reason:find("did not finish computing the sky mask", 1, true), failed.reason)
        assert.are.same({}, entriesOf(world, "2"))
        assert.are.equal("computed", resultFor(r, "3").status)
        assert.are.equal(1, #entriesOf(world, "3"))
        assert.are.same({ "2", "3" }, world.calls.updates)
    end)

    it("reports a target whose recompute raises as failed and removes its mask", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "fail" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        local failed = itemFor(r.failed, "2")
        assert.truthy(failed.reason:find("AI update failed", 1, true))
        assert.are.same({}, entriesOf(world, "2"))
        assert.are.equal("computed", resultFor(r, "3").status)
        assert.are.equal(2, #r.data.results)
    end)

    it("reports a target whose added mask could not be removed as unknown, not failed, and finishes the batch", function()
        local Handler, world = setup({
            photos = {
                { id = "1" },
                { id = "2", aiMode = "fail", rejectWrite = function(attempt) return attempt >= 2 end },
                { id = "3" },
            },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        assert.is_nil(itemFor(r.failed, "2"))
        assert.truthy(itemFor(r.unknown, "2"))
        assert.are.equal(1, #entriesOf(world, "2"))
        assert.are.equal("computed", resultFor(r, "3").status)
    end)

    it("answers unknown for a failed target that already had AI masks, which the recompute may have changed", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "nothing", entries = { newAIEntry("old") } } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.is_nil(itemFor(r.failed, "2"))
        local unknown = itemFor(r.unknown, "2")
        assert.truthy(unknown.reason:find("did not finish computing the sky mask", 1, true), unknown.reason)
        assert.truthy(unknown.reason:find("its existing AI masks may have changed", 1, true), unknown.reason)
        local entries = entriesOf(world, "2")
        assert.are.equal(1, #entries)
        assert.are.equal("mask-old", entries[1].CorrectionID)
    end)

    it("warns for a computed target that already had AI masks, which the recompute may have changed", function()
        local computedBefore = newAIEntry("old")
        for _, key in ipairs(COMPUTED_KEYS) do aiComponentOf(computedBefore)[key] = key .. "-old" end
        local Handler = setup({
            photos = { { id = "1" }, { id = "2", entries = { computedBefore } }, { id = "3" } },
        })
        local context = helper.requestContext(nil, { title = "create_mask_batch" })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" }, context)

        assert.are.equal("computed", resultFor(r, "2").status)
        assert.are.same({ "Photo 2: Lightroom recomputed AI settings for the whole photo, so its existing AI masks may have changed" },
            context.warnings)
    end)

    it("restores the previous masks of a failed target exactly", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "nothing", entries = { gradientCorrection("C1") } } },
        })

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local entries = entriesOf(world, "2")
        assert.are.equal(1, #entries)
        assert.are.equal("C1", entries[1].CorrectionID)
        assert.are.equal("Mask/Gradient", entries[1].CorrectionMasks[1].What)
    end)

    it("halts at a first photo with nothing to select: that photo failed, the rest remaining, the alert a warning", function()
        local Handler, world = setup({
            photos = { { id = "1", createBehavior = "nothing" }, { id = "2" }, { id = "3" } },
        })
        local context = helper.requestContext(nil, { title = "create_mask_batch" })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" }, context)

        assert.is_nil(r.data)
        assert.truthy(itemFor(r.failed, "1").reason:find("found no sky", 1, true))
        assert.are.same({ "2", "3" }, r.remaining)
        assert.truthy(context.warnings[1]:find("No sky detected", 1, true))
        assert.truthy(context.warnings[1]:find("click OK", 1, true))
        assert.are.same({ { photo = "1", subtype = "sky" } }, world.calls.created)
        assert.are.same({}, world.calls.updates)
        assert.are.same({}, world.stores["2"].writes)
        assert.are.equal("library", world.module())
        assert.is_true(world.activeIs(world.startPhoto))
    end)

    it("tries the next photo when the first fails for a reason that leaves no alert", function()
        local Handler, world = setup({
            photos = { { id = "1", createBehavior = "double" }, { id = "2" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.truthy(itemFor(r.failed, "1").reason:find("added 2 masks", 1, true))
        assert.are.equal("created", resultFor(r, "2").status)
        assert.are.equal("computed", resultFor(r, "3").status)
        assert.are.same({ "3" }, world.calls.updates)
        assert.is_nil(r.remaining)
        assert.are.equal("library", world.module())
    end)

    it("reports ids that match no photo and skips duplicates", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "999", "2", "2", "1" }, type = "sky" })

        assert.are.same({ "999" }, r.not_found)
        assert.are.equal(2, #r.data.results)
        assert.are.same({ "2" }, world.calls.updates)
    end)

    it("does not open Develop when no id matches a photo", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "998", "999" }, type = "sky" })

        assert.is_nil(r.data)
        assert.are.same({ "998", "999" }, r.not_found)
        assert.are.same({}, world.calls.modules)
        assert.are.same({}, world.calls.created)
    end)

    it("stops starting targets when the request's budget runs out and lists the rest", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" }, { id = "5" } },
            secondsPerUpdate = 100,
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3", "4", "5" }, type = "sky" },
            helper.requestContext(300))

        assert.are.equal(4, #r.data.results)
        assert.are.same({ "5" }, r.remaining)
        assert.are.same({ "2", "3", "4" }, world.calls.updates)
    end)

    it("fails every target when Lightroom did not save the new mask", function()
        local Handler, world = setup({ unsavedTemplate = true })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal("created", resultFor(r, "1").status)
        assert.truthy(itemFor(r.failed, "2").reason:find("did not save", 1, true))
        assert.is_not_nil(itemFor(r.failed, "3"))
        assert.are.same({}, world.calls.updates)
        assert.are.same({}, world.stores["2"].writes)
    end)

    it("fails photos on an uncertified Lightroom without touching Develop", function()
        local Handler, world = setup({ maskWrites = { refuse = "Lightroom Classic 16.0 (16.0 [ 202611041403-7ac14c66 ]) is not certified for writing mask geometry (certified: none)." } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.is_nil(r.data)
        assert.are.equal(2, #r.failed)
        assert.truthy(itemFor(r.failed, "1").reason:find("is not certified", 1, true))
        assert.are.same({}, world.calls.modules)
        assert.are.same({}, world.calls.created)
    end)

    it("fails a photo whose existing masks do not match the pinned format and continues", function()
        local odd = Store.correction("Odd", { { What = "Mask/Mystery", MaskActive = true } }, { CorrectionID = "C1" })
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", entries = { odd } }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.truthy(itemFor(r.failed, "2").reason:find("do not match the pinned mask format", 1, true))
        assert.are.same({}, world.stores["2"].writes)
        assert.are.equal("created", resultFor(r, "1").status)
        assert.are.equal("computed", resultFor(r, "3").status)
        assert.are.same({ "3" }, world.calls.updates)
    end)

    it("creates the template on a first photo whose existing masks are outside the pinned format", function()
        local odd = Store.correction("Odd", { { What = "Mask/Mystery", MaskActive = true } }, { CorrectionID = "C1" })
        local Handler, world = setup({ photos = { { id = "1", entries = { odd } }, { id = "2" } } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.are.equal("created", resultFor(r, "1").status)
        assert.are.equal("computed", resultFor(r, "2").status)
        assert.are.same({ "2" }, world.calls.updates)
    end)

    it("rejects a call while another batch is running", function()
        local Handler, world = setup({})
        local nestedError
        local photo = world.catalog:getAllPhotos()[2]
        local original = photo.updateAISettings
        photo.updateAISettings = function(self)
            nestedError = helper.refusalOf(function()
                Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" })
            end)
            return original(self)
        end

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.truthy(nestedError:find("already running", 1, true))
        assert.are.equal("library", world.module())
    end)

    it("allows a new call after one that failed inside the Develop session", function()
        local Handler, world = setup({})
        local photo = world.catalog:getAllPhotos()[1]
        local update = photo.updateAISettings
        photo.updateAISettings = nil
        local message = helper.refusalOf(function() Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" }) end)
        assert.truthy(message:find("needs Lightroom Classic 13.3", 1, true), message)
        photo.updateAISettings = update

        local r = Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" })

        assert.are.equal("created", r.data.results[1].status)
    end)

    it("never reads or writes mask data outside the catalog gates", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        for _, id in ipairs({ "1", "2", "3" }) do
            assert.are.equal(0, world.stores[id].readsOutsideGate)
            assert.are.equal(0, world.stores[id].writesOutsideGate)
        end
        assert.is_false(world.catalog.getQueriedInsideReadAccess())
        assert.is_false(world.catalog.getQueriedInsideWriteAccess())
    end)

    describe("Lightroom version", function()
        it("needs the Lightroom mask API", function()
            local Handler, world = setup({ withoutCreateApi = true })
            assert.are.equal("create_mask_batch needs LrDevelopController.createNewMask, which this Lightroom does not offer"
                .. " (Lightroom Classic 11 or later has it)",
                helper.refusalOf(function() Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" }) end))
            assert.are.same({}, world.calls.modules)
        end)

        it("needs updateAISettings and changes nothing without it", function()
            local Handler, world = setup({ withoutUpdateApi = true })
            assert.are.equal("create_mask_batch needs Lightroom Classic 13.3 or later",
                helper.refusalOf(function() Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" }) end))
            assert.are.same({}, world.calls.modules)
            assert.are.same({}, world.calls.created)
        end)
    end)
end)
