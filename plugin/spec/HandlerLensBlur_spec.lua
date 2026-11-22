local helper = require "spec_helper"

local function setup(opts)
    opts = opts or {}
    local photos = { helper.fakePhoto({ id = "1", path = "/1.dng" }), helper.fakePhoto({ id = "2", path = "/2.dng" }) }
    local catalog = helper.fakeCatalog({ photos = photos })
    local active, selection, module = photos[2], { photos[2] }, "library"
    local sources = { "collection" }
    local values = opts.values
        or {
            LensBlurActive = false,
            LensBlurAmount = 35,
            LensBlurCatEye = 0,
            LensBlurHighlightsBoost = 50,
            LensBlurFocalRange = "-80 0 28 108",
        }
    local saved = {
        Active = values.LensBlurActive,
        BlurAmount = values.LensBlurAmount,
        CatEyeAmount = values.LensBlurCatEye,
        HighlightsBoost = values.LensBlurHighlightsBoost,
        FocalRange = values.LensBlurFocalRange,
        BokehShape = 0,
    }
    local bokeh = "Circle"
    local writes = 0
    local pendingActive, activationWait, prematureFlush = nil, 0, false
    local colorGradeBlending
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selection end
    catalog.setSelectedPhotos = function(_, photo, selected)
        active, selection = photo, selected
    end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, nextSources) sources = nextSources end
    photos[1].getDevelopSettings = function()
        if opts.nilRead then return nil end
        return { LensBlur = saved, ProcessVersion = opts.storedProcess, ColorGradeBlending = colorGradeBlending }
    end
    local controller = {
        getValue = function(name) return values[name] end,
        getRange = function(name)
            if name == "LensBlurAmount" then return 0, opts.amountMax or 100 end
            return -100, 100
        end,
        setValue = function(name, value)
            writes = writes + 1
            if name == "LensBlurActive" and opts.activationDelay then
                pendingActive, activationWait = value, opts.activationDelay
                return
            end
            if name == "LensBlurActive" or values.LensBlurActive then values[name] = value end
        end,
        getSelectedLensBlurBokeh = function()
            if values.LensBlurActive then return bokeh end
        end,
        setLensBlurBokeh = function(value)
            writes = writes + 1
            bokeh = value
        end,
        stopTracking = function(localParam)
            if localParam or opts.ignoreSave then return end
            if pendingActive ~= nil then prematureFlush = true end
            if prematureFlush then return end
            local amount = opts.ignoreAmountSave and saved.BlurAmount or values.LensBlurAmount
            saved = {
                Active = values.LensBlurActive,
                BlurAmount = values.LensBlurAmount,
                CatEyeAmount = values.LensBlurCatEye,
                HighlightsBoost = values.LensBlurHighlightsBoost,
                FocalRange = values.LensBlurFocalRange,
                BokehShape = bokeh,
            }
            saved.BlurAmount = amount
        end,
    }
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrDevelopController = controller,
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(value)
                module = value
                if value == "develop" and opts.normalizeDevelop then colorGradeBlending = 50 end
            end,
        },
        LrSelection = {
            selectNone = function()
                active, selection = nil, {}
            end,
        },
        LrTasks = {
            pcall = pcall,
            sleep = function(seconds)
                if pendingActive ~= nil then
                    activationWait = activationWait - seconds
                    if activationWait <= 0 then
                        values.LensBlurActive, pendingActive = pendingActive, nil
                    end
                end
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.PhotoLookup = nil
    package.loaded.HandlerLensBlur = nil
    return {
        Handler = require "HandlerLensBlur",
        values = values,
        saved = function() return saved end,
        writes = function() return writes end,
        settings = function() return photos[1]:getDevelopSettings() end,
        view = function() return { active = active.localIdentifier, module = module, sources = sources } end,
    }
end

describe("HandlerLensBlur", function()
    it("refuses a photo whose saved settings Lightroom does not return before opening Develop", function()
        local ctx = setup({ nilRead = true })
        assert.has_error(
            function() ctx.Handler.set({ photo_id = "1", amount = 50 }, helper.requestContext()) end,
            "Lightroom returned no saved settings for photo 1"
        )
        assert.are.equal(0, ctx.writes())
        assert.are.equal("library", ctx.view().module)
    end)

    it("enables an inactive photo before saving Amount50 and restores the view", function()
        local ctx = setup()

        local result = ctx.Handler.set({ photo_id = "/1.dng", amount = 50 })

        assert.are.equal("1", result.photo_id)
        assert.is_nil(result.success)
        assert.is_true(result.active)
        assert.are.equal(50, result.amount)
        assert.are.equal(50, ctx.saved().BlurAmount)
        assert.is_true(ctx.saved().Active)
        assert.are.same({ active = "2", module = "library", sources = { "collection" } }, ctx.view())
    end)

    it("waits for asynchronous activation before committing and saving Amount50", function()
        local ctx = setup({ activationDelay = 12 })

        local result = ctx.Handler.set({ photo_id = "1", amount = 50 })

        assert.is_true(result.active)
        assert.are.equal(50, result.amount)
        assert.are.equal(50, ctx.saved().BlurAmount)
        assert.is_true(ctx.saved().Active)
        assert.are.same({ active = "2", module = "library", sources = { "collection" } }, ctx.view())
    end)

    it("stops before Amount when activation never becomes ready", function()
        local ctx = setup({ activationDelay = 30 })

        local class, err = helper.outcomeOf(
            function(context) ctx.Handler.set({ photo_id = "1", amount = 50 }, context) end
        )

        assert.are.equal("unknown", class)

        assert.matches("did not finish changing LensBlurActive", err, 1, true)
        assert.are.equal(1, ctx.writes())
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.same({ active = "2", module = "library", sources = { "collection" } }, ctx.view())
    end)

    it("reads an uninitialized photo as off without writing", function()
        local ctx = setup({ values = {} })

        local result = ctx.Handler.get({ photo_id = "/1.dng" })

        assert.are.equal("1", result.photo_id)
        assert.is_false(result.active)
        assert.is_nil(result.amount)
        assert.are.same({ "amount", "cat_eye", "highlights_boost", "focal_range", "bokeh" }, result.unavailable)
        assert.are.equal(0, ctx.writes())
    end)

    it("sets combined controls and returns the focal range inner endpoints", function()
        local ctx = setup()

        local result = ctx.Handler.set({
            photo_id = "1",
            amount = 50,
            cat_eye = 20,
            highlights_boost = 30,
            focal_range = { near = 10, far = 30 },
            bokeh = "Ring",
        })

        assert.are.equal(20, result.cat_eye)
        assert.are.equal(30, result.highlights_boost)
        assert.are.same({ near = 10, far = 30 }, result.focal_range)
        assert.are.equal("-70 10 30 110", result.focal_range_raw)
        assert.are.equal("Ring", result.bokeh)
    end)

    it("writes the focal range with a decimal point under a comma-decimal locale", function()
        local ctx = setup()
        assert.truthy(os.setlocale("ru_RU.UTF-8", "numeric"))

        local ok, result = pcall(ctx.Handler.set, { photo_id = "1", focal_range = { near = 12.5, far = 30.25 } })
        os.setlocale("C", "numeric")

        assert.is_true(ok, tostring(result))
        assert.are.equal("-67.5 12.5 30.25 110.25", result.focal_range_raw)
    end)

    it("can save adjustments and leave Lens Blur disabled", function()
        local ctx = setup()

        local result = ctx.Handler.set({ photo_id = "1", active = false, amount = 50 })

        assert.is_false(result.active)
        assert.is_false(ctx.saved().Active)
        assert.are.equal(50, ctx.saved().BlurAmount)
    end)

    it("writes a value the schema admits without asking Lightroom for a range", function()
        local ctx = setup({ amountMax = 40 })

        ctx.Handler.set({ photo_id = "1", amount = 50 })

        assert.are.equal(50, ctx.saved().BlurAmount)
    end)

    for _, case in ipairs({
        { "5.0", "Version 1" },
        { "5.7", "Version 2" },
        { 5.0, "Version 1" },
        { 5.7, "Version 2" },
    }) do
        local storedProcess = case[1]
        for _, operation in ipairs({ "get", "set" }) do
            it(
                operation
                    .. " refuses stored legacy process "
                    .. tostring(storedProcess)
                    .. " without normalizing settings",
                function()
                    local ctx = setup({ storedProcess = storedProcess, normalizeDevelop = true })
                    local before = ctx.settings()

                    local err = helper.failedOf(function() ctx.Handler[operation]({ photo_id = "1", amount = 50 }) end)

                    assert.matches("Process Version 3 or later", err, 1, true)
                    assert.are.same(before, ctx.settings())
                    assert.is_nil(ctx.settings().ColorGradeBlending)
                    assert.are.equal(0, ctx.writes())
                    assert.are.same({ active = "2", module = "library", sources = { "collection" } }, ctx.view())
                end
            )
        end
    end

    it("stops when the controller accepts a value but never saves it", function()
        local ctx = setup({ ignoreSave = true })

        local class, err = helper.outcomeOf(
            function(context) ctx.Handler.set({ photo_id = "1", amount = 50 }, context) end
        )

        assert.are.equal("unknown", class)

        assert.matches("did not save LensBlurActive", err, 1, true)
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.same({ active = "2", module = "library", sources = { "collection" } }, ctx.view())
    end)

    it("stops later adjustments when Amount readback differs from saved settings", function()
        local ctx = setup({ ignoreAmountSave = true })

        local class, err = helper.outcomeOf(
            function(context) ctx.Handler.set({ photo_id = "1", amount = 50, cat_eye = 20 }, context) end
        )

        assert.are.equal("unknown", class)

        assert.matches("did not save LensBlurAmount", err, 1, true)
        assert.are.equal(50, ctx.values.LensBlurAmount)
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.equal(0, ctx.values.LensBlurCatEye)
    end)

    it("leaves an uninitialized disabled photo unchanged when disabling it", function()
        local ctx = setup({ values = {} })

        local result = ctx.Handler.set({ photo_id = "1", active = false })

        assert.is_false(result.active)
        assert.are.equal(0, ctx.writes())
    end)

    it("answers an unknown photo as not found without writing", function()
        local ctx = setup()
        assert.are.equal("999", helper.notFoundOf(function() ctx.Handler.set({ photo_id = "999", amount = 50 }) end))
        assert.are.equal(0, ctx.writes())
    end)
end)
