local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local DIGEST = "ABCDEF0123456789ABCDEF0123456789"

local function existingGradient()
    return Store.correction("Gradient", { Store.linearComponent({ MaskID = "A1", MaskSyncID = "SA1" }) },
        { CorrectionID = "mask-a", LocalExposure2012 = 0.25 })
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries or { existingGradient() } })
    local calls = { updateAI = 0, modules = {} }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            for _, entry in ipairs(store.entries) do
                for _, component in ipairs(entry.CorrectionMasks) do
                    if component.What == "Mask/Image" and component.MaskDigest == nil and (component.ErrorReason or 0) == 0 then
                        if opts.nothingFound then
                            component.ErrorReason = 1
                        elseif not opts.neverCompute then
                            component.MaskDigest, component.InputDigest, component.LocalInputDigest = DIGEST, DIGEST, DIGEST
                        end
                    end
                end
            end
        end
    end
    local catalog = helper.fakeCatalog({ photos = { photo } })
    Store.trackGates(store, catalog)
    catalog.getTargetPhoto = function() return photo end
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
    for _, name in ipairs({ "HandlerMaskCreate", "HandlerAiMasks", "AIMaskCompute", "GuardedMaskWrite", "MaskTypes", "MaskValues",
        "DevelopSession" }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskCreate', store, calls
end

local SEEDS = {
    subject = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 1, MaskName = "Subject 1", MaskActive = true,
        MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    sky = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 2, MaskName = "Sky 1", MaskActive = true,
        MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    background = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 0, MaskSubCategoryID = 22, MaskName = "Background 1",
        MaskActive = true, MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
}

describe("HandlerMaskCreate.createMask Subject, Sky and Background in the saved settings", function()
    for _, typeName in ipairs({ "subject", "sky", "background" }) do
        it("writes a " .. typeName .. " entry from the kind's seed, lets Lightroom compute it and returns its id", function()
            local Handler, store, calls = setup()
            local other = Store.clone(store.entries[1])
            local context = helper.requestContext(nil, { title = "create_mask" })

            local r = Handler.createMask({ photo_id = "1", type = typeName }, context)

            local entry = Store.clone(store.writes[1][2])
            assert.are.same({ SEEDS[typeName] }, entry.CorrectionMasks)
            assert.are.equal("Correction", entry.What)
            assert.is_nil(entry.CorrectionID)
            assert.are.equal("C1", r.mask_id)
            assert.are.equal(typeName, r.type)
            assert.are.equal(DIGEST, store.entries[2].CorrectionMasks[1].MaskDigest)
            assert.are.same(other, store.entries[1])
            assert.are.equal(1, calls.updateAI)
            assert.are.same({}, calls.modules)
            assert.are.same({}, context.warnings)
            assert.is_nil(r.adjustments)
        end)
    end

    it("writes the requested adjustments into the new entry and reports them as Lightroom stored them", function()
        local Handler, store = setup()

        local r = Handler.createMask({ photo_id = "1", type = "sky",
            adjustments = { local_Exposure = 0.5, local_colorgradeMidtoneHue = 62.4, local_Texture = 23.66666666 } })

        local entry = store.entries[2]
        assert.are.equal(0.125, entry.LocalExposure2012)
        assert.are.equal(62, entry.LocalColorGradeMidtoneHue)
        assert.is_nil(entry.LocalShadows2012)
        assert.are.same({ local_Exposure = 0.5, local_colorgradeMidtoneHue = 62, local_Texture = 23.6667 }, r.adjustments)
    end)

    it("removes the new mask and refuses, with no alert to dismiss, when Lightroom finds nothing", function()
        local Handler, store = setup({ nothingFound = true })
        local before = Store.clone(store.entries)

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.truthy(err:find("Lightroom found no subject on photo 1", 1, true), err)
        assert.is_nil(err:find("alert", 1, true))
        assert.are.same(before, store.entries)
    end)

    it("answers unknown and writes nothing more while Lightroom is still computing at the limit", function()
        local Handler, store = setup({ neverCompute = true })

        local message = helper.unknownOf(function() Handler.createMask({ photo_id = "1", type = "sky" }) end)

        assert.truthy(message:find("has not finished computing the AI masks of photo 1", 1, true), message)
        assert.are.equal(1, #store.writes)
        assert.are.equal(2, #store.entries)
    end)

    it("is a certified operation", function()
        local Handler, store = setup({ maskWrites = { refuse = "Mask geometry writes are not certified." } })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.truthy(err:find("not certified", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses on a Lightroom without the AI update call", function()
        local Handler, store = setup({ withoutUpdateAi = true })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "1", type = "subject" }) end)

        assert.are.equal("create_mask needs Lightroom Classic 13.3 or later", err)
        assert.are.equal(0, store.attempts)
    end)

    it("accepts a file path and answers with the photo's own id", function()
        local Handler = setup()

        local r = Handler.createMask({ photo_id = "/1.jpg", type = "sky" })

        assert.are.equal("1", r.photo_id)
    end)

    it("answers not_found for an unknown photo", function()
        local Handler = setup()
        assert.are.equal("404", helper.notFoundOf(function() Handler.createMask({ photo_id = "404", type = "sky" }) end))
    end)
end)
