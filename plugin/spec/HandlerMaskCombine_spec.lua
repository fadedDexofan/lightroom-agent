local helper = require "spec_helper"
local Store = require "fake_mask_store"

local DIGEST = Store.DIGEST

local function existing()
    return {
        Store.correction(
            "Gradient",
            { Store.linearComponent({ MaskID = "A1", MaskSyncID = "SA1" }) },
            { CorrectionID = "mask-a", LocalExposure2012 = 0.25 }
        ),
        Store.correction("Sky", {
            {
                What = "Mask/Image",
                MaskActive = true,
                MaskInverted = false,
                MaskBlendMode = 0,
                MaskValue = 1,
                MaskVersion = 1,
                MaskSubType = 2,
                MaskID = "B1",
                MaskSyncID = "SB1",
                MaskDigest = DIGEST,
                InputDigest = DIGEST,
                LocalInputDigest = DIGEST,
            },
        }, { CorrectionID = "mask-b" }),
    }
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries or existing(), rejectWrite = opts.rejectWrite })
    local calls = { updateAI = 0, modules = {} }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            Store.computeAI(store, function(_, component)
                if opts.becomes and opts.becomes[component.MaskID] then return opts.becomes[component.MaskID] end
                if opts.absent then return "absent" end
                if opts.neverCompute then return "pending" end
                return "computed"
            end)
            if opts.dropAppended then
                local target = store.entries[1].CorrectionMasks
                target[#target] = nil
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
    for _, name in ipairs({
        "HandlerMaskCombine",
        "AIMaskCompute",
        "GuardedMaskWrite",
        "MaskTypes",
        "MaskValues",
        "DevelopSession",
    }) do
        package.loaded[name] = nil
    end
    return require "HandlerMaskCombine", store, calls
end

local SEEDS = {
    subject = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 1, MaskName = "Subject 1", MaskActive = true },
    sky = { What = "Mask/Image", MaskVersion = 1, MaskSubType = 2, MaskName = "Sky 1", MaskActive = true },
    background = {
        What = "Mask/Image",
        MaskVersion = 1,
        MaskSubType = 0,
        MaskSubCategoryID = 22,
        MaskName = "Background 1",
        MaskActive = true,
    },
}
local FORMS = {
    add = { MaskBlendMode = 0, MaskValue = 1, MaskInverted = false },
    subtract = { MaskBlendMode = 1, MaskValue = 0, MaskInverted = false },
    intersect = { MaskBlendMode = 1, MaskValue = 0, MaskInverted = true },
}

local function written(store)
    local component = Store.clone(store.writes[1][1].CorrectionMasks[2])
    return component
end

describe("HandlerMaskCombine.combineMask in the saved settings", function()
    for _, case in ipairs({
        { operation = "add", type = "subject" },
        { operation = "subtract", type = "subject" },
        { operation = "intersect", type = "subject" },
        { operation = "add", type = "sky" },
        { operation = "add", type = "background" },
    }) do
        it(
            "appends the "
                .. case.type
                .. " seed in the "
                .. case.operation
                .. " form to the named mask and returns its id",
            function()
                local Handler, store, calls = setup()
                local other = Store.clone(store.entries[2])
                local context = helper.requestContext(nil, { title = "combine_mask" })

                local r = Handler.combineMask(
                    { photo_ids = { "1" }, mask_id = "mask-a", operation = case.operation, type = case.type },
                    context
                )

                local expected = Store.clone(SEEDS[case.type])
                for key, value in pairs(FORMS[case.operation]) do
                    expected[key] = value
                end
                local component = written(store)
                expected.MaskID = component.MaskID
                assert.are.same(expected, component)
                assert.is_string(component.MaskID)
                assert.are.equal(component.MaskID, r.tool_id)
                assert.are.equal("mask-a", r.mask_id)
                assert.are.equal(DIGEST, store.entries[1].CorrectionMasks[2].MaskDigest)
                assert.are.same(other, store.entries[2])
                assert.are.equal(1, calls.updateAI)
                assert.are.equal(1, store.readsInsideWrite)
                assert.are.same({}, calls.modules)
                assert.are.same({}, context.warnings)
            end
        )
    end

    it("judges only its own component in a mask that already holds a computed AI component", function()
        local Handler, store = setup()
        local context = helper.requestContext(nil, { title = "combine_mask" })

        local r = Handler.combineMask(
            { photo_ids = { "1" }, mask_id = "mask-b", operation = "subtract", type = "subject" },
            context
        )

        assert.are.equal(store.entries[2].CorrectionMasks[2].MaskID, r.tool_id)
        assert.are.equal(2, #store.entries[2].CorrectionMasks)
        assert.are.same({}, context.warnings)
    end)

    it("puts the mask back and refuses when Lightroom finds nothing to combine", function()
        local Handler, store = setup({ absent = true })
        local before = Store.clone(store.entries)

        local err = helper.failedOf(
            function() Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "sky" }) end
        )

        assert.truthy(err:find("Lightroom found nothing for the sky to add to mask mask-a on photo 1", 1, true), err)
        assert.are.same(before, store.entries)
    end)

    it("answers unknown and writes nothing more while Lightroom is still computing at the limit", function()
        local Handler, store = setup({ neverCompute = true })

        local message = helper.unknownOf(
            function()
                Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "subject" })
            end
        )

        assert.truthy(message:find("has not finished computing the AI masks of photo 1", 1, true), message)
        assert.are.equal(1, #store.writes)
        assert.are.equal(2, #store.entries[1].CorrectionMasks)
    end)

    it("refuses a mask that is not in the saved settings, writing nothing", function()
        local Handler, store = setup()

        local err = helper.failedOf(
            function()
                Handler.combineMask({ photo_ids = { "1" }, mask_id = "nope", operation = "add", type = "subject" })
            end
        )

        assert.truthy(err:find("Mask nope is not in the saved settings of photo 1", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)

    it("is a certified operation", function()
        local Handler, store = setup({ maskWrites = { refuse = "Mask geometry writes are not certified." } })

        local err = helper.failedOf(
            function()
                Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "subject" })
            end
        )

        assert.truthy(err:find("not certified", 1, true), err)
        assert.are.equal(0, store.attempts)
    end)

    it("answers not_found for an unknown photo", function()
        local Handler = setup()
        assert.are.equal(
            "404",
            helper.notFoundOf(
                function()
                    Handler.combineMask({
                        photo_ids = { "404" },
                        mask_id = "mask-a",
                        operation = "add",
                        type = "subject",
                    })
                end
            )
        )
    end)
end)

describe("HandlerMaskCombine.combineMask judging the target mask", function()
    local function aiComponent(id)
        return {
            What = "Mask/Image",
            MaskActive = true,
            MaskInverted = false,
            MaskBlendMode = 0,
            MaskValue = 1,
            MaskVersion = 1,
            MaskSubType = 2,
            MaskID = id,
            MaskSyncID = "S" .. id,
            MaskDigest = DIGEST,
            InputDigest = DIGEST,
            LocalInputDigest = DIGEST,
        }
    end

    it("warns about another mask whose AI component the photo-wide recompute changed", function()
        local Handler = setup({ becomes = { B1 = { MaskDigest = "RECOMPUTED" } } })
        local context = helper.requestContext(nil, { title = "combine_mask" })

        Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "sky" }, context)

        assert.are.same(
            { "Photo 1: Lightroom's photo-wide AI recompute changed mask mask-b; check it" },
            context.warnings
        )
    end)

    it("warns when only the second AI component of a mask changed", function()
        local entries = existing()
        entries[2].CorrectionMasks = { aiComponent("B1"), aiComponent("B2") }
        local Handler = setup({ entries = entries, becomes = { B2 = { MaskDigest = "RECOMPUTED" } } })
        local context = helper.requestContext(nil, { title = "combine_mask" })

        Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "sky" }, context)

        assert.are.same(
            { "Photo 1: Lightroom's photo-wide AI recompute changed mask mask-b; check it" },
            context.warnings
        )
    end)

    it("puts the mask back and fails when Lightroom keeps no appended component", function()
        local Handler, store = setup({ dropAppended = true })
        local before = Store.clone(store.entries)

        local message = helper.failedOf(
            function() Handler.combineMask({ photo_ids = { "1" }, mask_id = "mask-a", operation = "add", type = "sky" }) end
        )

        assert.are.equal("Lightroom kept 0 of the 1 requested masks on photo 1; the new masks were removed", message)
        assert.are.same(before, store.entries)
    end)
end)
