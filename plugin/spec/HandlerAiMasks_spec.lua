local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = Store.DIGEST

local function computeEveryEntry(opts)
    return function(state)
        Store.computeAI(state, function(entry, component)
            if opts.existingBecomes and entry.CorrectionID == "C1" then return opts.existingBecomes end
            local category = component.MaskSubCategoryID
            if opts.absentCategories and opts.absentCategories[category] then return "absent" end
            if opts.neverCompute or (opts.pendingCategories and opts.pendingCategories[category])
                or (opts.pendingIds and opts.pendingIds[entry.CorrectionID]) then
                return "pending"
            end
            return "computed"
        end)
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
    local store = Store.attach(photo, { entries = opts.entries, processVersion = opts.processVersion, rejectWrite = opts.rejectWrite,
        transformWrite = opts.transformWrite })
    local calls = { updateAI = 0, modules = {}, catalogs = 0 }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            if opts.updateFails then error("AI update failed") end
            if opts.computesOnSecondRead then
                local reads, getDevelopSettings = 0, photo.getDevelopSettings
                photo.getDevelopSettings = function(self)
                    reads = reads + 1
                    if reads == 2 then computeEveryEntry(opts)(store) end
                    return getDevelopSettings(self)
                end
                return
            end
            computeEveryEntry(opts)(store)
            if opts.raisesAfterCompute then error("AI update failed late") end
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
        assert.are.equal(written[1].CorrectionID, result.mask_id)
        assert.are.same({
            { mask_id = written[1].CorrectionID, part = "hair" },
            { mask_id = written[2].CorrectionID, part = "face_skin" },
        }, result.masks)
        assert.are.equal(0, #calls.modules)
    end)

    it("answers done when Lightroom stores another reference point than the part's seed sent", function()
        local Handler, store = setup({ transformWrite = function(stored, writeNumber)
            if writeNumber == 1 then stored[#stored].CorrectionMasks[1].ReferencePoint = "0.412 0.377" end
            return stored
        end })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })

        assert.are.equal(store.writes[1][1].CorrectionID, result.mask_id)
        assert.are.equal(1, #store.writes)
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
        assert.are.equal(written[2].CorrectionID, result.masks[1].mask_id)
    end)

    it("removes the new masks and refuses when the photo has no such part", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [5] = true } })
        local context = helper.requestContext(nil, { title = "create_mask" })

        local refusal = helper.failedOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "face_skin", "hair" } }, context)
        end)

        assert.matches("found no hair on any person in photo 1", refusal, 1, true)
        assert.matches("the new masks were removed", refusal, 1, true)
        assert.are.same({}, context.warnings)
        assert.are.equal(1, #store.entries)
        assert.are.equal("Sky gradient", store.entries[1].CorrectionName)
    end)

    it("refuses and restores the photo when a part is missing on a photo that already had AI masks", function()
        local Handler, store = setup({ entries = { existingSky() }, absentCategories = { [5] = true } })

        local refusal = helper.failedOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })
        end)

        assert.matches("found no hair on any person in photo 1; the new masks were removed", refusal, 1, true)
        assert.are.same({ existingSky() }, store.entries)
    end)

    for _, case in ipairs({
        { what = "whose result Lightroom's recompute changed", becomes = { MaskDigest = "0123" },
          warnings = { "Photo 1: Lightroom's photo-wide AI recompute changed mask C1; check it" } },
        { what = "that became failed", becomes = { ErrorReason = 2 },
          warnings = { "Photo 1: Lightroom's photo-wide AI recompute changed mask C1; check it" } },
        { what = "that the recompute left as it was", becomes = nil, warnings = {} },
    }) do
        it("answers for an existing AI mask " .. case.what, function()
            local Handler, store = setup({ entries = { existingSky() }, existingBecomes = case.becomes })
            local context = helper.requestContext(nil, { title = "create_mask" })

            local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)

            assert.are.equal(store.writes[1][2].CorrectionID, result.mask_id)
            assert.are.same(case.warnings, context.warnings)
        end)
    end

    it("names an AI mask that was already failed before the call and does not let it decide", function()
        local failed = existingSky()
        failed.CorrectionMasks[1].MaskDigest = nil
        failed.CorrectionMasks[1].ErrorReason = 1
        local Handler, store = setup({ entries = { failed } })
        local context = helper.requestContext(nil, { title = "create_mask" })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)

        assert.are.equal(store.writes[1][2].CorrectionID, result.mask_id)
        assert.are.same({ "Photo 1: mask C1 was already failed (ErrorReason 1, no result) before this call" }, context.warnings)
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

    it("answers unknown and writes nothing more when the AI update raises and leaves the new masks uncomputed", function()
        local Handler, store, calls = setup({ updateFails = true })

        local message = helper.unknownOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)

        assert.matches("Lightroom could not compute the people masks: AI update failed", message, 1, true)
        assert.matches("has not finished computing the AI masks of photo 1 within 15 s", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(1, #store.entries)
        assert.are.equal(1, calls.updateAI)
    end)

    it("judges the photo when the AI update raises after Lightroom computed the new masks", function()
        local Handler, store = setup({ raisesAfterCompute = true })
        local context = helper.requestContext(nil, { title = "create_mask" })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)

        assert.are.equal(1, #result.masks)
        assert.are.equal(1, #store.entries)
        assert.are.equal(1, #store.writes)
        assert.are.same({ "Photo 1: Lightroom could not compute the people masks: AI update failed late; nothing on the"
            .. " photo was still computing afterwards, so the call judged the photo as it stands" }, context.warnings)
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

            local refusal = helper.failedOf(function()
                Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)
            end)

            assert.matches("stayed busy with another write", refusal, 1, true)
            assert.matches("; the new masks were removed$", refusal)
            assert.are.same({ previous }, store.entries)
            assert.are.equal(0, calls.updateAI)
            assert.are.same({}, context.warnings)
        end)
    end

    it("answers unknown when the removal of the new masks cannot be confirmed", function()
        local Handler, store = setup({ absentCategories = { [5] = true }, rejectWrite = function(attempt) return attempt >= 2 end })

        local class, message = helper.outcomeOf(function(context)
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }, context)
        end)

        assert.are.equal("unknown", class)
        assert.matches("the new masks could not be confirmed removed", message, 1, true)
        assert.are.equal(1, #store.entries)
    end)

    it("writes nothing more and answers unknown when Lightroom has not finished computing at the limit", function()
        local Handler, store, calls = setup({ neverCompute = true })

        local message = helper.unknownOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })
        end)

        assert.matches("Lightroom has not finished computing the AI masks of photo 1 within 15 s", message, 1, true)
        assert.matches("can freeze Lightroom", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(1, #store.entries)
        assert.are.equal(1, calls.updateAI)
    end)

    it("answers unknown and writes nothing more while an existing AI mask is still computing at the limit", function()
        local pending = existingSky()
        for _, key in ipairs({ "MaskDigest", "InputDigest", "LocalInputDigest" }) do pending.CorrectionMasks[1][key] = nil end
        local Handler, store = setup({ entries = { pending }, pendingIds = { C1 = true } })

        local message = helper.unknownOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })
        end)

        assert.matches("has not finished computing the AI masks of photo 1 within 15 s", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(2, #store.entries)
    end)

    it("withholds the restore while one own part is still computing after another was not found", function()
        local Handler, store = setup({ absentCategories = { [5] = true }, pendingCategories = { [6] = true } })

        local message = helper.unknownOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair", "lips" } })
        end)

        assert.matches("has not finished computing", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(2, #store.entries)
    end)

    it("waits for a compute Lightroom finishes after its first read and answers done", function()
        local Handler, store = setup({ computesOnSecondRead = true })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })

        assert.are.equal(1, #result.masks)
        assert.are.equal(1, #store.writes)
        assert.is_string(store.entries[1].CorrectionMasks[1].MaskDigest)
    end)

    it("removes the new masks when Lightroom drops one of them", function()
        local Handler, store = setup({ dropLastEntry = true })

        local message = helper.failedOf(function()
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
        assert.are.equal(written[1].CorrectionID, result.mask_id)
        assert.are.same({
            { mask_id = written[1].CorrectionID, category = "sky" },
            { mask_id = written[2].CorrectionID, category = "water" },
            { mask_id = written[3].CorrectionID, category = "vegetation" },
        }, result.masks)
    end)

    it("removes every new mask when one category is absent", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [50007] = true } })

        local refusal = helper.failedOf(function()
            Handler.createMask({ type = "landscape", photo_id = "1", categories = { "sky", "water" } })
        end)

        assert.matches("found no water in photo 1; the new masks were removed", refusal, 1, true)
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
                helper.failedOf(function() Handler.createMask(args) end), 1, true)
            assert.are.equal(0, store.attempts)
            assert.are.equal(0, calls.updateAI)
        end
    end)
end)
