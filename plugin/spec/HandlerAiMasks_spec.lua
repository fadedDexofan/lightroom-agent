local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = "ABCDEF0123456789ABCDEF0123456789"

local function computeEveryEntry(opts)
    return function(state)
        for _, entry in ipairs(state.entries) do
            local component = entry.CorrectionMasks[1]
            if component.What == "Mask/Image" and component.MaskDigest == nil then
                local category = component.MaskSubCategoryID
                if opts.absentCategories and opts.absentCategories[category] then
                    component.ErrorReason = 1
                elseif not opts.neverCompute then
                    component.MaskDigest = DIGEST
                    component.InputDigest = DIGEST
                    component.LocalInputDigest = DIGEST
                end
            end
        end
    end
end

local function existingGradient()
    return Store.correction("Sky gradient", { Store.linearComponent({ MaskID = "C1T1" }) }, { CorrectionID = "C1" })
end

local function existingSky()
    return Store.correction("Sky", { {
        What = "Mask/Image", MaskActive = true, MaskInverted = false, MaskBlendMode = 0, MaskValue = 1,
        MaskSubType = 2, MaskID = "C1T1", MaskDigest = DIGEST, InputDigest = DIGEST, LocalInputDigest = DIGEST,
    } }, { CorrectionID = "C1" })
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries, processVersion = opts.processVersion, rejectWrite = opts.rejectWrite })
    local calls = { updateAI = 0, modules = {}, catalogs = 0 }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            if opts.updateFails then error("AI update failed") end
            computeEveryEntry(opts)(store)
            if opts.dropLastEntry then store.entries[#store.entries] = nil end
        end
    end
    local catalog = helper.fakeCatalog({ photos = { photo }, writeAccessAborts = opts.writeAccessAborts })
    Store.trackGates(store, catalog)

    helper.admitMaskWrites(opts.maskWrites)

    helper.installImport({
        LrApplication = {
            activeCatalog = function() calls.catalogs = calls.catalogs + 1; return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) calls.modules[#calls.modules + 1] = name end,
        },
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({
        "HandlerMaskCreate", "HandlerAiMasks", "AiMaskParts", "GuardedMaskWrite", "AIMaskCompute", "DevelopSession", "Log", "MaskSelection",
    }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskCreate', store, calls
end

describe("HandlerMaskCreate.createMask people", function()
    it("writes one all-people mask per part and returns the ids", function()
        local Handler, store, calls = setup()

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair", "face_skin" } })

        local written = store.writes[1]
        assert.are.equal(2, #written)
        local hair = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Image", hair.What)
        assert.are.equal(3, hair.MaskSubType)
        assert.are.equal(5, hair.MaskSubCategoryID)
        assert.is_nil(hair.InstanceIDs)
        assert.is_nil(hair.MaskDigest)
        assert.are.equal(2, written[2].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(1, calls.updateAI)
        assert.are.equal("people", result.type)
        assert.is_nil(result.person)
        assert.are.equal("C1", result.mask_id)
        assert.are.same({
            { mask_id = "C1", part = "hair" },
            { mask_id = "C2", part = "face_skin" },
        }, result.masks)
        assert.are.equal(0, #calls.modules)
    end)

    it("writes entire_person as an all-people part and keeps the masks already on the photo", function()
        local Handler, store = setup({ entries = { existingGradient() } })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "face_skin", "entire_person" } })

        local written = store.writes[1]
        assert.are.equal(3, #written)
        assert.are.equal("Sky gradient", written[1].CorrectionName)
        assert.are.equal(3, written[2].CorrectionMasks[1].MaskSubType)
        assert.are.equal(3, written[3].CorrectionMasks[1].MaskSubType)
        assert.are.equal(13, written[3].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(3, #store.entries)
        assert.are.equal("C2", result.masks[1].mask_id)
    end)

    it("removes the new masks and reports it when the photo has no such part", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [5] = true } })

        local reply = Handler.createMask({ type = "people", photo_id = "1", parts = { "face_skin", "hair" } })

        assert.is_nil(reply.data)
        assert.matches("found no hair on any person in photo 1", reply.failed[1].reason, 1, true)
        assert.matches("the new masks were removed", reply.failed[1].reason, 1, true)
        assert.matches("Update AI Settings Errors", reply.warnings[1], 1, true)
        assert.are.equal(1, #store.entries)
        assert.are.equal("Sky gradient", store.entries[1].CorrectionName)
    end)

    it("answers unknown when a part is missing on a photo that already had AI masks", function()
        local existing = Store.correction("Sky", { {
            What = "Mask/Image", MaskActive = true, MaskInverted = false, MaskBlendMode = 0, MaskValue = 1,
            MaskSubType = 2, MaskID = "C1T1", MaskDigest = DIGEST, InputDigest = DIGEST, LocalInputDigest = DIGEST,
        } }, { CorrectionID = "C1" })
        local Handler, store = setup({ entries = { existing }, absentCategories = { [5] = true } })

        local reply = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })

        assert.is_nil(reply.failed)
        assert.matches("found no hair on any person in photo 1", reply.unknown[1].reason, 1, true)
        assert.matches("its existing AI masks may have changed", reply.unknown[1].reason, 1, true)
        assert.matches("Update AI Settings Errors", reply.warnings[1], 1, true)
        assert.are.equal(1, #store.entries)
        assert.are.equal("C1", store.entries[1].CorrectionID)
    end)

    it("warns when the new masks computed on a photo that already had AI masks", function()
        local Handler = setup({ entries = { existingSky() } })
        local context = helper.requestContext(nil, { title = "create_mask" })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)

        assert.are.equal("1", result.photo_id)
        assert.are.equal(1, #context.warnings)
        assert.matches("Photo 1: Lightroom recomputed AI settings for the whole photo, so its existing AI masks may have changed",
            context.warnings[1], 1, true)
    end)

    it("does not warn about a recompute when the photo had no AI masks", function()
        local Handler = setup({ entries = { existingGradient() } })
        local context = helper.requestContext(nil, { title = "create_mask" })

        Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)

        assert.are.same({}, context.warnings)
    end)

    it("fails on a photo that is not found without writing", function()
        local Handler, store = setup()

        assert.are.equal("99", helper.notFoundOf(function() Handler.createMask({ type = "people", photo_id = "99", parts = { "hair" } }) end))
        assert.are.equal(0, store.attempts)
    end)

    it("refuses on a Lightroom without the AI update call", function()
        local Handler, store = setup({ withoutUpdateAi = true })

        assert.are.equal("create_mask needs Lightroom Classic 13.3 or later",
            helper.refusalOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end))
        assert.are.equal(0, store.attempts)
    end)

    it("removes the new masks when the AI update call fails", function()
        local Handler, store = setup({ updateFails = true })

        local message = helper.refusalOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)

        assert.matches("Lightroom could not compute the AI masks: AI update failed", message, 1, true)
        assert.are.equal(0, #store.entries)
    end)

    for _, case in ipairs({
        { held = "a gradient", existing = existingGradient },
        { held = "an AI mask", existing = existingSky },
    }) do
        it("refuses and removes the new masks when the catalog stays busy for the AI compute on a photo with "
            .. case.held, function()
            local previous = case.existing()
            local Handler, store, calls = setup({
                entries = { previous },
                writeAccessAborts = function(title) return title == "Update AI Settings" end,
            })
            local context = helper.requestContext(nil, { title = "create_mask" })

            local refusal = helper.refusalOf(function()
                Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)
            end)

            assert.matches("stayed busy with another write", refusal, 1, true)
            assert.matches("; the new masks were removed$", refusal)
            assert.are.same({ previous }, store.entries)
            assert.are.equal(0, calls.updateAI)
            assert.are.same({}, context.warnings)
        end)
    end

    it("answers unknown, not a refusal, when the new masks could not be removed", function()
        local Handler, store = setup({ updateFails = true, rejectWrite = function(attempt) return attempt >= 2 end })

        local message = helper.unknownOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })
        end)

        assert.matches("could not be removed", message, 1, true)
        assert.are.equal(1, #store.entries)
    end)

    it("leaves the masks alone and says so when Lightroom never finishes computing", function()
        local Handler, store, calls = setup({ neverCompute = true })

        local message = helper.unknownOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })
        end)

        assert.matches("has not finished computing", message, 1, true)
        assert.matches("can freeze Lightroom", message, 1, true)
        assert.matches("Do not write to this photo until the masks show in Develop", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(1, #store.entries)
        assert.are.equal(1, calls.updateAI)
    end)

    it("removes the new masks when Lightroom drops one of them", function()
        local Handler, store = setup({ dropLastEntry = true })

        local message = helper.refusalOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair", "lips" } })
        end)

        assert.matches("Lightroom kept 1 of the 2 requested masks", message, 1, true)
        assert.are.equal(0, #store.entries)
    end)

    it("does the catalog reads and writes only inside their gates", function()
        local Handler, store = setup()

        Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })

        assert.are.equal(0, store.readsOutsideGate)
        assert.are.equal(0, store.writesOutsideGate)
    end)

    it("rejects a second Develop-driving call while one runs", function()
        local Handler, _, _ = setup()
        local DevelopSession = require 'DevelopSession'
        local message
        DevelopSession.run(helper.requestContext(nil, { title = "other_tool" }), nil, false, function()
            message = helper.refusalOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)
        end)

        assert.matches("other_tool is already running", message, 1, true)
    end)
end)

describe("HandlerMaskCreate.createMask landscape", function()
    it("writes one landscape mask per category and returns the ids", function()
        local Handler, store, calls = setup()

        local result = Handler.createMask({ type = "landscape", photo_id = "1", categories = { "sky", "water", "vegetation" } })

        local written = store.writes[1]
        assert.are.equal(3, #written)
        local sky = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Image", sky.What)
        assert.are.equal(0, sky.MaskSubType)
        assert.are.equal(50006, sky.MaskSubCategoryID)
        assert.are.equal(50007, written[2].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(50005, written[3].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal("Sky", written[1].CorrectionName)
        assert.are.equal(1, calls.updateAI)
        assert.are.equal("landscape", result.type)
        assert.are.equal("C1", result.mask_id)
        assert.are.same({
            { mask_id = "C1", category = "sky" },
            { mask_id = "C2", category = "water" },
            { mask_id = "C3", category = "vegetation" },
        }, result.masks)
    end)

    it("removes every new mask when one category is absent", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [50007] = true } })

        local reply = Handler.createMask({ type = "landscape", photo_id = "1", categories = { "sky", "water" } })

        assert.matches("found no water in photo 1", reply.failed[1].reason, 1, true)
        assert.are.equal(1, #store.entries)
        assert.are.equal("Sky gradient", store.entries[1].CorrectionName)
    end)

end)

describe("HandlerMaskCreate.createMask AI selectors", function()
    it("keeps both guarded types off an uncertified Lightroom without writing", function()
        for _, typeName in ipairs({ "people", "landscape" }) do
            local Handler, store, calls = setup({ maskWrites = { refuse = "Lightroom Classic 16.0 (16.0 [ 202611041403-7ac14c66 ]) is not certified for writing mask geometry (certified: none)." } })
            local args = { photo_id = "1", type = typeName }
            if typeName == "people" then args.parts = { "hair" } else args.categories = { "sky" } end
            assert.matches("is not certified",
                helper.refusalOf(function() Handler.createMask(args) end), 1, true)
            assert.are.equal(0, store.attempts)
            assert.are.equal(0, calls.updateAI)
        end
    end)
end)
