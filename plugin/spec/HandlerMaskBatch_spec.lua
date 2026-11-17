local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = Store.DIGEST

local function setup(opts)
    opts = opts or {}
    local specs = opts.photos or { { id = "1" }, { id = "2" }, { id = "3" } }
    local photos, stores = {}, {}
    local calls = { updates = {}, modules = {} }
    for _, spec in ipairs(specs) do
        local photo = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        local store = Store.attach(photo, { entries = spec.entries or {} })
        stores[spec.id] = store
        photos[#photos + 1] = photo
        if not opts.withoutUpdateApi then
            photo.updateAISettings = function()
                calls.updates[#calls.updates + 1] = spec.id
                Store.computeAI(store, function()
                    if spec.ai == "nothing found" then return "absent" end
                    if spec.ai == "pending" then return "pending" end
                    return "computed"
                end)
            end
        end
    end
    local catalog = helper.fakeCatalog({ photos = photos })
    for _, spec in ipairs(specs) do Store.trackGates(stores[spec.id], catalog) end
    catalog.getTargetPhoto = function() return nil end
    helper.admitMaskWrites(opts.maskWrites)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) calls.modules[#calls.modules + 1] = name end,
        },
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskBatch", "HandlerMaskCreate", "AIMaskCompute", "GuardedMaskWrite", "MaskTypes",
        "DevelopSession", "DevelopBatch" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskBatch', { stores = stores, calls = calls }
end

local function itemFor(list, photoId)
    for _, item in ipairs(list or {}) do
        if item.photo_id == photoId then return item end
    end
    return nil
end

describe("HandlerMaskBatch.createMaskBatch in the saved settings", function()
    it("writes the same seed with the same adjustments to every photo, without Develop, and returns each mask id", function()
        local Handler, world = setup()
        local context = helper.requestContext(nil, { title = "create_mask_batch" })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky",
            adjustments = { local_Exposure = 0.5, local_colorgradeMidtoneHue = 62.4 } }, context)

        assert.are.equal(3, #r.data.results)
        for index, id in ipairs({ "1", "2", "3" }) do
            local result = r.data.results[index]
            assert.are.equal(id, result.photo_id)
            assert.are.equal("created", result.status)
            assert.are.equal("C1", result.mask_id)
            assert.are.same({ local_Exposure = 0.5, local_colorgradeMidtoneHue = 62 }, result.adjustments)
            local entry = world.stores[id].entries[1]
            assert.are.equal(2, entry.CorrectionMasks[1].MaskSubType)
            assert.are.equal(0.125, entry.LocalExposure2012)
            assert.are.equal(DIGEST, entry.CorrectionMasks[1].MaskDigest)
        end
        assert.are.same({ "1", "2", "3" }, world.calls.updates)
        assert.are.same({}, world.calls.modules)
    end)

    it("fails a photo where Lightroom finds nothing, removes its mask and finishes the batch", function()
        local Handler, world = setup({ photos = { { id = "1", ai = "nothing found" }, { id = "2" } } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "subject" })

        local failed = itemFor(r.failed, "1")
        assert.truthy(failed.reason:find("Lightroom found nothing for the subject mask on photo 1", 1, true), failed.reason)
        assert.are.same({}, world.stores["1"].entries)
        assert.are.equal("created", r.data.results[1].status)
        assert.are.equal("2", r.data.results[1].photo_id)
    end)

    it("answers unknown for a photo still computing at the limit, writes nothing more to it and finishes the batch", function()
        local Handler, world = setup({ photos = { { id = "1", ai = "pending" }, { id = "2" } } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local unknown = itemFor(r.unknown, "1")
        assert.truthy(unknown.reason:find("has not finished computing the AI masks of photo 1", 1, true), unknown.reason)
        assert.are.equal(1, #world.stores["1"].writes)
        assert.are.equal("2", r.data.results[1].photo_id)
    end)

    it("leaves the masks already on a photo as Lightroom stored them", function()
        local held = Store.correction("Old", { Store.linearComponent({ MaskID = "O1", MaskSyncID = "SO1" }) }, { CorrectionID = "old" })
        local Handler, world = setup({ photos = { { id = "1", entries = { held } } } })
        local before = Store.clone(world.stores["1"].entries[1])

        Handler.createMaskBatch({ photo_ids = { "1" }, type = "background" })

        assert.are.same(before, world.stores["1"].entries[1])
        assert.are.equal(22, world.stores["1"].entries[2].CorrectionMasks[1].MaskSubCategoryID)
    end)

    it("fails every photo of an uncertified Lightroom, writing nothing", function()
        local Handler, world = setup({ maskWrites = { refuse = "Mask geometry writes are not certified." } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal(3, #r.failed)
        for _, id in ipairs({ "1", "2", "3" }) do assert.are.equal(0, world.stores[id].attempts) end
    end)

    it("refuses on a Lightroom without the AI update call before writing anything", function()
        local Handler, world = setup({ withoutUpdateApi = true })

        local err = helper.failedOf(function()
            Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" }, helper.requestContext(nil, { title = "create_mask_batch" }))
        end)

        assert.are.equal("create_mask_batch needs Lightroom Classic 13.3 or later", err)
        assert.are.equal(0, world.stores["1"].attempts)
    end)

    it("lists unknown ids as not found and writes to a photo named twice once", function()
        local Handler, world = setup({ photos = { { id = "1" } } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "404", "/1.jpg" }, type = "sky" })

        assert.are.same({ "404" }, r.not_found)
        assert.are.equal(1, #world.stores["1"].writes)
    end)

    it("lists the photos it had no time for as remaining", function()
        local Handler, world = setup()
        local asked = 0
        local context = helper.requestContext(nil, { title = "create_mask_batch", stopping = function() asked = asked + 1; return asked > 1 end })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" }, context)

        assert.are.equal(1, #r.data.results)
        assert.are.same({ "2", "3" }, r.remaining)
        assert.are.equal(0, world.stores["2"].attempts)
    end)
end)
