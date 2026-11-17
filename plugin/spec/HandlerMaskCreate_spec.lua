local helper = require 'spec_helper'

local function existingMask(id)
    return {
        ID = id,
        Name = "Mask " .. id,
        Hidden = false,
        Tools = { { ID = "tool-" .. id, Name = "Gradient", Type = "gradient", Hidden = false, Inverted = false } },
    }
end

local function aiMask(id, subtype)
    return {
        ID = id,
        Name = "Mask " .. id,
        Hidden = false,
        Tools = { { ID = "tool-" .. id, Name = subtype, Type = "aiSelection", Subtype = subtype, Hidden = false, Inverted = false } },
    }
end

local function setup(opts)
    opts = opts or {}
    local existing = opts.existing or {}
    local settingsGroups = {}
    for index = 1, #existing do settingsGroups[index] = { CorrectionID = tostring(index) } end
    local photo = helper.fakePhoto({
        id = "10",
        path = "/10.jpg",
        developSettings = { MaskGroupBasedCorrections = settingsGroups },
    })
    local other = helper.fakePhoto({ id = "11", path = "/11.jpg" })
    local masks = {}
    for index, mask in ipairs(existing) do masks[index] = mask end

    local calls = {
        created = {},
        setValue = {},
        selectMask = {},
        deleteMask = {},
        tools = {},
        trackingDelay = {},
        threshold = {},
        stopTracking = 0,
        modules = {},
    }
    local polls = 0
    local values = {}
    local module = "library"
    local active = photo
    local tool = opts.startTool or "loupe"
    local behavior = opts.behavior or "append"
    local pollsBeforeAppear = opts.pollsBeforeAppear or 0
    local newMaskId = "new-mask"
    local selectedMask = opts.selectedMask
    local omitExistingPolls = 0

    local function appendNew()
        masks[#masks + 1] = aiMask(newMaskId, calls.created[#calls.created].subtype)
    end

    local controller = {
        getAllMasks = function()
            polls = polls + 1
            if module ~= "develop" then error("Develop module is not active") end
            if opts.notReadyPolls and polls <= opts.notReadyPolls then return {} end
            if opts.firstOnlyPolls and polls <= opts.firstOnlyPolls then return { masks[1] } end
            if opts.listsNothingAfterDelete and calls.deleteMask[1] then return {} end
            if omitExistingPolls > 0 then
                omitExistingPolls = omitExistingPolls - 1
                local added = {}
                for index = #existing + 1, #masks do added[#added + 1] = masks[index] end
                return added
            end
            if calls.created[1] then
                local sinceCreate = polls - calls.createdAtPoll
                if behavior == "delayed" and sinceCreate == pollsBeforeAppear and #masks == #existing then
                    appendNew()
                elseif behavior == "vanishes" then
                    if sinceCreate == 1 then appendNew() end
                    if sinceCreate == 4 and #masks > #existing then masks[#masks] = nil end
                end
            end
            local reversed = {}
            for index = #masks, 1, -1 do reversed[#reversed + 1] = masks[index] end
            return reversed
        end,
        selectMask = function(id)
            calls.selectMask[#calls.selectMask + 1] = id
            if not opts.ignoreSelect then selectedMask = id end
        end,
        getSelectedMask = function() return selectedMask end,
        goToMasking = function() end,
        selectMaskTool = function() end,
        selectTool = function(name)
            if not (opts.maskingToolIgnored and name == "masking") then tool = name end
            calls.tools[#calls.tools + 1] = name
        end,
        getSelectedTool = function()
            if opts.pointColorSubtool and tool == "masking" then return "local_point_color" end
            return tool
        end,
        createNewMask = function(maskType, subtype)
            if module ~= "develop" then error("Develop module is not active") end
            calls.created[#calls.created + 1] = { type = maskType, subtype = subtype }
            calls.createdAtPoll = polls
            if opts.dropsExistingOnCreate then table.remove(masks, 1) end
            if opts.reidentifiesExistingOnCreate then masks[1] = existingMask("a2") end
            if opts.savedMaskOnCreate then settingsGroups[#settingsGroups + 1] = { CorrectionID = "orphan" } end
            if behavior == "append" then
                appendNew()
            elseif behavior == "empty" then
                masks[#masks + 1] = { ID = newMaskId, Name = "Mask", Hidden = false, Tools = {} }
            elseif behavior == "double" then
                appendNew()
                masks[#masks + 1] = aiMask("second-mask", subtype)
            end
        end,
        deleteMask = function(id)
            if opts.deleteFails then error("cannot delete") end
            calls.deleteMask[#calls.deleteMask + 1] = id
            if opts.deleteIgnored then return end
            if opts.listUnreadableAfterDelete then module = "library" end
            for index = #masks, 1, -1 do
                if masks[index].ID == id then table.remove(masks, index) end
            end
        end,
        setValue = function(param, value)
            if opts.setValueFailsOn == param then
                omitExistingPolls = opts.omitsExistingAfterFailurePolls or 0
                error("setValue failed")
            end
            calls.setValue[#calls.setValue + 1] = { param = param, value = value, mask = selectedMask }
            if opts.selectAfterFirstWrite and #calls.setValue == 1 then selectedMask = opts.selectAfterFirstWrite end
            local clamp = opts.clampTo and opts.clampTo[param]
            values[param] = clamp and math.max(-clamp, math.min(clamp, value)) or value
        end,
        getValue = function(param) return values[param] or 0 end,
        stopTracking = function() calls.stopTracking = calls.stopTracking + 1 end,
        setTrackingDelay = function(seconds) calls.trackingDelay[#calls.trackingDelay + 1] = seconds end,
        setMultipleAdjustmentThreshold = function(seconds) calls.threshold[#calls.threshold + 1] = seconds end,
    }
    if opts.withoutCreateApi then controller.createNewMask = nil end
    if opts.withoutMaskApi then
        controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
    end

    local catalog = helper.fakeCatalog({ photos = { photo, other } })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, selected, selection)
        recordSelection(self, selected, selection)
        active = selected
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                calls.modules[#calls.modules + 1] = name
            end,
        },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMaskCreate = nil
    package.loaded.DevelopSession = nil
    package.loaded.MaskSelection = nil
    package.loaded.MaskCreationAdjustments = nil
    local Handler = require 'HandlerMaskCreate'
    return Handler, calls, masks, catalog
end

local function idsOf(masks)
    local ids = {}
    for _, mask in ipairs(masks) do ids[#ids + 1] = mask.ID end
    return ids
end

describe("HandlerMaskCreate.createMask", function()
    it("creates the matching AI mask for each type and returns its id", function()
        local expected = {
            subject = "subject",
            sky = "sky",
            background = "background",
        }
        for typeName, subtype in pairs(expected) do
            local Handler, calls = setup({})

            local r = Handler.createMask({ photo_id = "10", type = typeName })

            assert.are.equal("10", r.photo_id)
            assert.are.equal(typeName, r.type)
            assert.are.equal("new-mask", r.mask_id)
            assert.are.same({ { type = "aiSelection", subtype = subtype } }, calls.created)
            assert.are.equal("new-mask", r.mask.id)
            assert.are.equal("aiSelection", r.mask.tools[1].type)
            assert.is_nil(r.adjustments)
        end
    end)

    it("warns when a mask that was on the photo is gone after creating the new one", function()
        local Handler = setup({ existing = { existingMask("a"), existingMask("b") }, dropsExistingOnCreate = true })
        local context = helper.requestContext(nil, { title = "create_mask" })

        local r = Handler.createMask({ photo_id = "10", type = "sky" }, context)

        assert.are.equal("new-mask", r.mask_id)
        assert.are.equal(1, #context.warnings)
        assert.truthy(context.warnings[1]:find("no longer lists mask a", 1, true), context.warnings[1])
    end)

    it("leaves the masks already on the photo untouched", function()
        local Handler, calls, masks = setup({ existing = { existingMask("a"), existingMask("b") } })

        local r = Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "a", "b", "new-mask" }, idsOf(masks))
        assert.are.same({}, calls.deleteMask)
        assert.are.same({ "new-mask" }, calls.selectMask)
    end)

    it("writes no slider when Lightroom does not select the new mask", function()
        local Handler, calls, masks = setup({ existing = { existingMask("a") }, selectedMask = "a", ignoreSelect = true })

        local refusal = helper.refusalOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Exposure = 1 } })
        end)

        assert.truthy(refusal:find("Could not select mask new-mask", 1, true))
        assert.are.same({}, calls.setValue)
        assert.are.same({ "a" }, idsOf(masks))
    end)

    it("starts every local slider from its neutral value when no adjustments are given", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject" })

        local written = {}
        for _, call in ipairs(calls.setValue) do written[call.param] = call.value end
        assert.are.equal(#require('LocalSliders').list, #calls.setValue)
        assert.are.equal(0, written.local_Exposure)
        assert.are.equal(0, written.local_colorgradeMidtoneHue)
        assert.are.equal(0, written.local_glow)
        assert.are.equal(50, written.local_colorgradeBlending)
    end)

    it("writes requested adjustments and zeroes the rest", function()
        local Handler, calls = setup({})

        local r = Handler.createMask({
            photo_id = "10",
            type = "sky",
            adjustments = {
                local_Exposure = -1.5, local_Contrast = 20, local_Highlights = -30, local_Shadows = 10, local_Whites = 5, local_Blacks = -5,
                local_Texture = 12, local_Clarity = 8, local_Dehaze = 25, local_Temperature = -10, local_Tint = 4,
                local_Saturation = 15, local_Sharpness = 30, local_LuminanceNoise = 18,
            },
        })

        local written = {}
        for _, call in ipairs(calls.setValue) do written[call.param] = call.value end
        for name, value in pairs({
            local_Exposure = -1.5, local_Contrast = 20, local_Highlights = -30, local_Shadows = 10, local_Whites = 5,
            local_Blacks = -5, local_Texture = 12, local_Clarity = 8, local_Dehaze = 25, local_Temperature = -10,
            local_Tint = 4, local_Saturation = 15, local_Sharpness = 30, local_LuminanceNoise = 18,
            local_Moire = 0, local_colorgradeMidtoneHue = 0, local_colorgradeBlending = 50, local_glow = 0,
        }) do
            assert.are.equal(value, written[name], name)
        end
        assert.are.equal(-1.5, r.adjustments.local_Exposure)
        assert.are.equal(18, r.adjustments.local_LuminanceNoise)
    end)

    it("zeroes sliders that were not requested", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Exposure = 0.7 } })

        local written = {}
        for _, call in ipairs(calls.setValue) do written[call.param] = call.value end
        assert.are.equal(0.7, written.local_Exposure)
        assert.are.equal(0, written.local_Contrast)
        assert.are.equal(0, written.local_LuminanceNoise)
    end)

    it("groups the writes into one history step and restores the grouping defaults", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Exposure = 1 } })

        assert.are.same({ 10, 2 }, calls.trackingDelay)
        assert.are.same({ 10, 0.5 }, calls.threshold)
        assert.are.equal(1, calls.stopTracking)
    end)

    it("restores the grouping defaults when a slider write fails", function()
        local Handler, calls = setup({ setValueFailsOn = "local_Dehaze" })

        helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.are.same({ 10, 2 }, calls.trackingDelay)
        assert.are.same({ 10, 0.5 }, calls.threshold)
    end)

    it("removes the new mask and reports the failure when a slider write fails", function()
        local Handler, calls, masks = setup({
            existing = { existingMask("a") },
            setValueFailsOn = "local_Tint",
        })

        local err = helper.refusalOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Tint = 5 } })
        end)

        assert.truthy(err:find("setValue failed", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
    end)

    it("stops the neutral writes, removes the new mask and answers unknown when another mask becomes selected", function()
        local Handler, calls, masks = setup({ existing = { existingMask("a") }, selectAfterFirstWrite = "a" })
        local first = require('LocalSliders').list[1]

        local err = helper.unknownOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.are.same({ { param = first.name, value = require('LocalSliders').neutralOf(first), mask = "new-mask" } },
            calls.setValue)
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
        assert.are.equal("Another mask became selected while writing the new mask; the new mask was removed, but"
            .. " written before the move: " .. first.name .. "; read the masks with list_masks before retrying", err)
    end)

    it("removes the new mask when Lightroom reads back a different value than was written", function()
        local Handler, calls, masks = setup({
            existing = { existingMask("a") },
            clampTo = { local_Contrast = 5 },
        })

        local err = helper.refusalOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Contrast = 20 } })
        end)

        assert.truthy(err:find("Lightroom did not keep local_Contrast 20 (reads 5)", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
    end)

    it("tells the caller to dismiss Lightroom's alert when nothing is found", function()
        local Handler = setup({ behavior = "nothing" })

        local reply = Handler.createMask({ photo_id = "10", type = "sky" })

        assert.truthy(reply.warnings[1]:find("\"No sky detected\" alert; click OK in Lightroom", 1, true))
    end)

    it("answers unknown when nothing is found on a maskless photo whose saved settings gain a mask", function()
        local Handler, calls = setup({ behavior = "nothing", savedMaskOnCreate = true })

        local reply = Handler.createMask({ photo_id = "10", type = "sky" })

        assert.is_nil(reply.failed)
        assert.are.equal("10", reply.unknown[1].photo_id)
        assert.truthy(reply.unknown[1].reason:find("Lightroom found no sky to select on photo 10", 1, true))
        assert.truthy(reply.unknown[1].reason:find("may still be on the photo: call list_masks", 1, true),
            reply.unknown[1].reason)
        assert.truthy(reply.warnings[1]:find("click OK", 1, true))
        assert.are.same({}, calls.deleteMask)
    end)

    it("removes the new mask when Develop briefly leaves the photo's other masks out of its list", function()
        local Handler, calls, masks = setup({
            existing = { existingMask("a") },
            setValueFailsOn = "local_Tint",
            omitsExistingAfterFailurePolls = 3,
        })

        local err = helper.refusalOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { local_Tint = 5 } })
        end)

        assert.truthy(err:find("setValue failed", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
    end)

    it("waits for a mask that Lightroom adds after detection finishes", function()
        local Handler, _, masks = setup({ behavior = "delayed", pollsBeforeAppear = 40 })

        local r = Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "new-mask" }, idsOf(masks))
    end)

    it("reports nothing found when no mask appears, and changes no masks", function()
        local Handler, calls, masks = setup({ behavior = "nothing", existing = { existingMask("a") } })

        local reply = Handler.createMask({ photo_id = "10", type = "sky" })

        assert.is_nil(reply.data)
        assert.are.equal("10", reply.failed[1].photo_id)
        assert.truthy(reply.failed[1].reason:find("Lightroom found no sky to select on photo 10", 1, true))
        assert.truthy(reply.warnings[1]:find("click OK", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({}, calls.deleteMask)
        assert.are.same({}, calls.setValue)
    end)

    it("deletes an empty mask that Lightroom leaves behind", function()
        local Handler, calls, masks = setup({ behavior = "empty", existing = { existingMask("a") } })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("created an empty sky mask", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
        assert.are.same({}, calls.setValue)
    end)

    it("treats a mask that disappears again as nothing found", function()
        local Handler, _, masks = setup({ behavior = "vanishes" })

        local reply = Handler.createMask({ photo_id = "10", type = "background" })

        assert.truthy(reply.failed[1].reason:find("found no background to select", 1, true))
        assert.are.same({}, idsOf(masks))
    end)

    it("removes every new mask when Lightroom adds more than one", function()
        local Handler, calls, masks = setup({ behavior = "double", existing = { existingMask("a") } })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.truthy(err:find("added 2 masks", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.equal(2, #calls.deleteMask)
    end)

    it("names a new mask it could not remove", function()
        local Handler = setup({ behavior = "empty", deleteFails = true })

        local err = helper.unknownOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("could not remove the new mask (still listed: new-mask)", 1, true))
    end)

    it("answers unknown, naming the mask, when a removal Lightroom accepted leaves the new mask", function()
        local Handler = setup({ behavior = "empty", deleteIgnored = true })

        local err = helper.unknownOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("new-mask", 1, true))
    end)

    it("answers unknown when the mask list cannot be read after the removal", function()
        local Handler = setup({ behavior = "empty", listUnreadableAfterDelete = true })

        local err = helper.unknownOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("could not be read", 1, true), err)
    end)

    for _, case in ipairs({
        { fake = "listsNothingAfterDelete", deleted = { "new-mask" } },
        { fake = "reidentifiesExistingOnCreate", deleted = {} },
    }) do
        it("answers unknown when the mask list after a failure no longer lists the photo's masks (" .. case.fake .. ")",
            function()
                local Handler, calls = setup({ existing = { existingMask("a") }, behavior = "empty", [case.fake] = true })

                local err = helper.unknownOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

                assert.truthy(err:find("call list_masks before retrying", 1, true), err)
                assert.are.same(case.deleted, calls.deleteMask)
            end)
    end

    it("waits for the existing masks to load before taking its snapshot", function()
        local Handler, _, masks = setup({ existing = { existingMask("a") }, notReadyPolls = 12 })

        local r = Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "a", "new-mask" }, idsOf(masks))
    end)

    it("refuses to create when the existing masks never load", function()
        local Handler, calls = setup({ existing = { existingMask("a") }, notReadyPolls = 100000 })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.truthy(err:find("Develop lists 0 of the 1 masks in photo 10's saved settings", 1, true))
        assert.are.same({}, calls.created)
    end)

    it("keeps the masks Develop lists late when a failed create removes its own mask", function()
        local Handler, calls, masks = setup({ existing = { existingMask("a"), existingMask("b"), existingMask("c") },
            firstOnlyPolls = 3, setValueFailsOn = "local_Dehaze" })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.are.same({ "new-mask" }, calls.deleteMask)
        assert.are.same({ "a", "b", "c" }, idsOf(masks))
        assert.truthy(err:find("setValue failed", 1, true), err)
    end)

    it("refuses with the listed and saved counts when Develop lists only some masks", function()
        local Handler, calls = setup({ existing = { existingMask("a"), existingMask("b"), existingMask("c") },
            firstOnlyPolls = 100000 })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.truthy(err:find("Develop lists 1 of the 3 masks in photo 10's saved settings", 1, true), err)
        assert.are.same({}, calls.created)
    end)

    it("opens the masking tool and puts the previous tool back", function()
        local Handler, calls = setup({ startTool = "crop" })

        Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    for _, pointColorSubtool in ipairs({ false, true }) do
        it("leaves the tool alone when the masking tool is already open (local Point Color subtool: "
            .. tostring(pointColorSubtool) .. ")", function()
            local Handler, calls = setup({ startTool = "masking", pointColorSubtool = pointColorSubtool })

            Handler.createMask({ photo_id = "10", type = "subject" })

            assert.are.equal(1, #calls.created)
            assert.are.same({}, calls.tools)
        end)
    end

    it("puts the previous tool back after a failure", function()
        local Handler, calls = setup({ behavior = "nothing", startTool = "crop" })

        Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    it("refuses before creating anything when the masking tool does not open, and puts the previous tool back", function()
        local Handler, calls = setup({ startTool = "crop", maskingToolIgnored = true })

        local err = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("did not open the masking tool", 1, true))
        assert.truthy(err:find("nothing was changed", 1, true))
        assert.are.same({}, calls.created)
        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    it("accepts a numeric photo id and a file path and answers with the photo's own id", function()
        local Handler = setup({})
        assert.are.equal("10", Handler.createMask({ photo_id = 10, type = "sky" }).photo_id)

        local PathHandler = setup({})
        assert.are.equal("10", PathHandler.createMask({ photo_id = "/10.jpg", type = "sky" }).photo_id)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({})

        assert.are.equal("404", helper.notFoundOf(function() Handler.createMask({ photo_id = "404", type = "sky" }) end))
        assert.are.same({}, calls.modules)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        for opts, expected in pairs({
            [{ withoutMaskApi = true }] = "create_mask needs LrDevelopController.getAllMasks, which this Lightroom"
                .. " does not offer (Lightroom Classic 11 or later has it)",
            [{ withoutCreateApi = true }] = "create_mask needs LrDevelopController.createNewMask, which this Lightroom"
                .. " does not offer (Lightroom Classic 11 or later has it)",
        }) do
            local Handler, calls = setup(opts)

            local refusal = helper.refusalOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

            assert.are.equal(expected, refusal)
            assert.are.same({}, calls.modules)
        end
    end)

    it("puts back the module afterwards", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("resolves photos and reads settings outside any query gate", function()
        local Handler, _, _, catalog = setup({})

        Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
