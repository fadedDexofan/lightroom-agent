local helper = require 'spec_helper'

local SUBJECT_AND_BACKGROUND = {
    { What = "Correction", CorrectionID = "57E2D8EE-5F6C-4822-B258-F7D8892D7C1F", CorrectionName = "Mask 1", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "05212FF8-3B95-4ED6-8D23-A911F82F1BB0", MaskName = "Subject 1", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 1 } } },
    { What = "Correction", CorrectionID = "07DDC19E-D633-46F9-B1B8-8E9EAB9CB611", CorrectionName = "Mask 2", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "2BAFCB9F-DD98-4570-8D29-061BC3170D21", MaskName = "Background 1", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 0, MaskSubCategoryID = 22 } } },
}

local SKY_AND_LANDSCAPE = {
    { What = "Correction", CorrectionID = "C81F4B60-E236-4412-B78C-570D7A7F3867", CorrectionName = "Mask 1", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "529F7F30-82B6-495F-B943-CE741683FD59", MaskName = "Sky 1", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 2 } } },
    { What = "Correction", CorrectionID = "71AAE5A0-55C7-4B19-988E-7F7AD3A08772", CorrectionName = "Sky", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "AC2FF0A9-6E64-4C6D-AC02-24F8ED74177C", MaskName = "Sky", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 0, MaskSubCategoryID = 50006 } } },
    { What = "Correction", CorrectionID = "CFE912E2-9992-42A9-8882-22D88DB0AF16", CorrectionName = "Vegetation", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "82D82601-3200-4048-A792-54B65E6B7A3C", MaskName = "Vegetation", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 0, MaskSubCategoryID = 50005 } } },
}

local PEOPLE = {
    { What = "Correction", CorrectionID = "5ED9028D-3B12-4B5E-A91A-3C41F3F62634", CorrectionName = "People - Facial Skin", CorrectionActive = true, CorrectionMasks = { { What = "Mask/Image", MaskID = "B3E20173-ED0E-460D-B6F5-DE1ABA11CF7E", MaskName = "People - Facial Skin", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1, MaskSubType = 3, MaskSubCategoryID = 2 } } },
}

local LUMINANCE = {
    What = "Mask/RangeMask", MaskID = "5EDEEEF2-5665-4470-B2FC-756A5328B301", MaskName = "Luminance Range", MaskInverted = false, MaskBlendMode = 0, MaskValue = 1,
    CorrectionRangeMask = { LumRange = "0.500000 0.600000 0.900000 1.000000", Type = 2, Version = 3, SampleType = 0, LuminanceDepthSampleInfo = "0 0.607422 0.718750", Invert = false },
}

local COLOR = {
    What = "Mask/RangeMask", MaskID = "t-color",
    CorrectionRangeMask = { Type = 1, ColorAmount = 0.494949, PointModels = { "0.522527 0.888059 0.758296 0.050000 0.188000 0" } },
}

local function correction(id, components, fields)
    local entry = { What = "Correction", CorrectionID = id, CorrectionName = "Mask " .. id, CorrectionActive = true,
        CorrectionMasks = components }
    for key, value in pairs(fields or {}) do entry[key] = value end
    return entry
end

local function forbidden(name)
    return function() error(name .. " must not be called") end
end

local function setup(opts)
    local photos = {}
    for _, spec in ipairs(opts.photos) do
        photos[#photos + 1] = helper.fakePhoto({
            id = spec.id, path = "/" .. spec.id .. ".jpg", developSettings = spec.developSettings or {},
            orientation = spec.orientation or "AB", dimensions = { width = 3000, height = 2000 },
        })
    end
    local catalog = helper.fakeCatalog({ photos = photos })
    catalog.setSelectedPhotos = forbidden("setSelectedPhotos")
    catalog.setActiveSources = forbidden("setActiveSources")
    local function forbiddenModule(module)
        return setmetatable({}, { __index = function(_, name) return forbidden(module .. "." .. name) end })
    end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = forbiddenModule("LrApplicationView"),
        LrDevelopController = forbiddenModule("LrDevelopController"),
        LrSelection = forbiddenModule("LrSelection"),
        LrTasks = { pcall = pcall, sleep = forbidden("LrTasks.sleep") },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMasks = nil
    return require 'HandlerMasks', catalog
end

local function listed(entries, opts)
    opts = opts or {}
    local Handler = setup({ photos = { {
        id = "1", orientation = opts.orientation,
        developSettings = { MaskGroupBasedCorrections = entries },
    } } })
    return Handler.listMasks({ photo_id = "1" }, opts.context)
end

describe("HandlerMasks.listMasks", function()
    it("lists Lightroom's Subject and Background masks newest first, as Lightroom's Masks panel shows them", function()
        assert.are.same({
            photo_id = "1",
            count = 2,
            masks = {
                { id = "07DDC19E-D633-46F9-B1B8-8E9EAB9CB611", name = "Mask 2", hidden = false, tools = {
                    { id = "2BAFCB9F-DD98-4570-8D29-061BC3170D21", type = "aiSelection", subtype = "background", inverted = false },
                } },
                { id = "57E2D8EE-5F6C-4822-B258-F7D8892D7C1F", name = "Mask 1", hidden = false, tools = {
                    { id = "05212FF8-3B95-4ED6-8D23-A911F82F1BB0", type = "aiSelection", subtype = "subject", inverted = false },
                } },
            },
        }, listed(SUBJECT_AND_BACKGROUND))
    end)

    it("names Sky and the Landscape parts Lightroom computed with create_mask's words", function()
        local masks = listed(SKY_AND_LANDSCAPE).masks

        assert.are.same({ "Vegetation", "Sky", "Mask 1" }, { masks[1].name, masks[2].name, masks[3].name })
        assert.are.same({ id = "82D82601-3200-4048-A792-54B65E6B7A3C", type = "aiSelection", subtype = "landscape",
            part = "vegetation", inverted = false }, masks[1].tools[1])
        assert.are.same({ id = "AC2FF0A9-6E64-4C6D-AC02-24F8ED74177C", type = "aiSelection", subtype = "landscape",
            part = "sky", inverted = false }, masks[2].tools[1])
        assert.are.same({ id = "529F7F30-82B6-495F-B943-CE741683FD59", type = "aiSelection", subtype = "sky",
            inverted = false }, masks[3].tools[1])
    end)

    it("names a People part Lightroom computed with create_mask's part name", function()
        assert.are.same({ id = "B3E20173-ED0E-460D-B6F5-DE1ABA11CF7E", type = "aiSelection", subtype = "people",
            part = "face_skin", inverted = false }, listed(PEOPLE).masks[1].tools[1])
    end)

    it("lists gradients, brushes and every range kind with the stored range of each range tool", function()
        local tools = listed({ correction("m-1", {
            { What = "Mask/Gradient", MaskID = "t-linear" },
            { What = "Mask/CircularGradient", MaskID = "t-radial" },
            { What = "Mask/Paint", MaskID = "t-brush" },
            COLOR,
            LUMINANCE,
            { What = "Mask/RangeMask", MaskID = "t-depth", CorrectionRangeMask = { Type = -1, DepthRange = "0.000000 0.100000 0.400000 0.500000" } },
        }) }).masks[1].tools

        assert.are.same({
            { id = "t-linear", type = "gradient", inverted = false },
            { id = "t-radial", type = "radialGradient", inverted = false },
            { id = "t-brush", type = "brush", inverted = false },
            { id = "t-color", type = "rangeMask", subtype = "color", inverted = false,
                range = { sample = { x = 0.05, y = 0.188, l = 0.522527, a = 0.888059, b = 0.758296 }, amount = 0.494949 } },
            { id = "5EDEEEF2-5665-4470-B2FC-756A5328B301", type = "rangeMask", subtype = "luminance", inverted = false,
                range = { min = 0.6, max = 0.9, lower_falloff = 0.1, upper_falloff = 0.1 } },
            { id = "t-depth", type = "rangeMask", subtype = "depth", inverted = false,
                range = { min = 0.1, max = 0.4, lower_falloff = 0.1, upper_falloff = 0.1 } },
        }, tools)
    end)

    it("reports a colour sample pin in the displayed frame of a cropped, rotated photo", function()
        local Handler = setup({ photos = { {
            id = "1", orientation = "DA",
            developSettings = {
                CropLeft = 0.1, CropTop = 0.1, CropRight = 0.8, CropBottom = 0.7, CropAngle = 0,
                MaskGroupBasedCorrections = { correction("m-1", { {
                    What = "Mask/RangeMask", MaskID = "t-color",
                    CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { "0.5 0.5 0.5 0.800000 0.100000 0" } },
                } }) },
            },
        } } })

        local sample = Handler.listMasks({ photo_id = "1" }).masks[1].tools[1].range.sample

        assert.is_true(math.abs(sample.x) < 1e-6)
        assert.is_true(math.abs(sample.y) < 1e-6)
    end)

    it("shows a turned-off mask as hidden and an inverted component as inverted", function()
        local mask = listed({ correction("m-1", {
            { What = "Mask/Gradient", MaskID = "t-1", MaskInverted = true },
        }, { CorrectionActive = false }) }).masks[1]

        assert.is_true(mask.hidden)
        assert.is_true(mask.tools[1].inverted)
    end)

    it("lists a component of an encoding it does not know by its stored kind, without a subtype", function()
        local tools = listed({ correction("m-1", {
            { What = "Mask/Image", MaskID = "t-ai", MaskSubType = 3, MaskSubCategoryID = 99 },
            { What = "Mask/Future", MaskID = "t-new" },
        }) }).masks[1].tools

        assert.are.same({
            { id = "t-ai", type = "Mask/Image", inverted = false },
            { id = "t-new", type = "Mask/Future", inverted = false },
        }, tools)
    end)

    it("lists a mask without components as having no tools", function()
        assert.are.same({}, listed({ { What = "Correction", CorrectionID = "m-1", CorrectionName = "Empty" } }).masks[1].tools)
    end)

    it("still lists the masks, without ranges, when the photo's frame cannot be read", function()
        local context = helper.requestContext(nil, { title = "list_masks" })

        local r = listed({ correction("m-1", { COLOR }) }, { orientation = "ZZ", context = context })

        assert.are.equal(1, r.count)
        assert.are.same({ id = "t-color", type = "rangeMask", subtype = "color", inverted = false }, r.masks[1].tools[1])
        assert.are.equal(1, #context.warnings)
        assert.truthy(context.warnings[1]:find("stored ranges of photo 1 could not be read", 1, true), context.warnings[1])
    end)

    it("returns an empty list for a photo whose saved settings hold no masks", function()
        for _, settings in ipairs({ {}, { MaskGroupBasedCorrections = {} } }) do
            local Handler = setup({ photos = { { id = "1", developSettings = settings } } })

            assert.are.same({ photo_id = "1", count = 0, masks = {} }, Handler.listMasks({ photo_id = "1" }))
        end
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({ photos = { { id = "7", developSettings = { MaskGroupBasedCorrections = { correction("m", {}) } } } } })

        assert.are.equal("7", Handler.listMasks({ photo_id = 7 }).photo_id)
        assert.are.equal(1, Handler.listMasks({ photo_id = "/7.jpg" }).count)
    end)

    it("names the photo id when the photo is unknown", function()
        local Handler = setup({ photos = { { id = "1" } } })

        assert.are.equal("404", helper.notFoundOf(function() Handler.listMasks({ photo_id = "404" }) end))
    end)

    it("reads the saved settings without Develop, a selection change or a write", function()
        local Handler, catalog = setup({ photos = { { id = "1", developSettings = { MaskGroupBasedCorrections = SUBJECT_AND_BACKGROUND } } } })

        assert.are.equal(2, Handler.listMasks({ photo_id = "1" }).count)
        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
