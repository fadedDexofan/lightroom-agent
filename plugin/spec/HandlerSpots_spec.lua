local helper = require 'spec_helper'

local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child) end
    return result
end

local function setup(options)
    options = options or {}
    local photos = { helper.fakePhoto({ id = '1', path = '/1.jpg' }),
        helper.fakePhoto({ id = '2', path = '/2.jpg' }) }
    local catalog = helper.fakeCatalog({ photos = photos })
    local active, module, tool, selected = photos[1], 'library', options.tool or 'loupe', 2
    local spots = options.spots or options.empty and {} or {
        { SpotType = 'heal', Opacity = 1, opacity = 1, Masks = { { MaskID = 'first' } } },
        { SpotType = 'heal', Opacity = 0.7, opacity = 0.7, Masks = { { MaskID = 'second' } } },
    }
    local calls = { writes = 0, deletes = 0, opens = 0, tools = {} }
    local controller = {
        getAllSpots = function() return clone(spots) end,
        getSelectedTool = function()
            if options.pointColorSubtool and tool == 'masking' then return 'local_point_color' end
            return tool
        end,
        selectTool = function(value)
            calls.tools[#calls.tools + 1] = value
            if not options.ignoreRestore then tool = value end
        end,
        goToRemove = function() tool = 'dust'; calls.opens = calls.opens + 1 end,
        setSelectedSpotIndex = function(index)
            if options.refuse or not spots[index] then return false, 'not selectable' end
            selected = index
            return true
        end,
        getSelectedSpotIndex = function() return selected end,
        getSelectedSpotParams = function() return clone(spots[selected]) end,
        setSelectedSpotParams = function(params)
            calls.writes = calls.writes + 1
            assert.are.same(spots[selected].Masks, params.Masks)
            if options.throw then error('SDK failure') end
            if options.ignoreAfterFirst and calls.writes > 1 then return end
            if not options.ignore then spots[selected] = clone(params) end
            if options.keepsOpacity and calls.writes == 1 then spots[selected].Opacity = options.keepsOpacity end
            if options.changeOther and calls.writes == 1 then spots[2].Opacity = 0.1 end
            if options.addSpot and calls.writes == 1 then spots[#spots + 1] = { SpotType = 'clone', Opacity = 1 } end
            if options.throwAfterWrite and calls.writes == 1 then error('SDK failure') end
        end,
        deleteSelectedSpot = function()
            calls.deletes = calls.deletes + 1
            if not options.ignore then table.remove(spots, selected) end
        end,
    }
    for _, name in ipairs(options.without or {}) do controller[name] = nil end
    local originalSelect = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selection)
        originalSelect(self, photo, selection)
        active = photo
    end
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return { active } end
    catalog.getActiveSources = function() return { 'source' } end
    catalog.setActiveSources = function() end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end,
            versionTable = function() return { major = options.old and 14 or 15, minor = options.old and 0 or 6 } end },
        LrApplicationView = { getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end },
        LrDevelopController = controller,
        LrTasks = { pcall = pcall, sleep = function() end },
        LrSelection = { selectNone = function() active = nil end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerSpots = nil
    package.loaded.DevelopSession = nil
    package.loaded.PhotoLookup = nil
    local handler = require 'HandlerSpots'
    return handler, calls, function() return spots end, function()
        return { active = active.localIdentifier, module = module, tool = tool }
    end
end

describe('Remove spots', function()
    it('lists complete SDK fields with reusable one-based indices and restores the view', function()
        local handler, calls, spots, state = setup()
        local result = handler.list({ photo_id = '/2.jpg' })
        assert.are.equal('2', result.photo_id)
        assert.is_nil(result.success)
        assert.are.equal(2, result.count)
        assert.are.same({ index = 1, params = spots()[1] }, result.spots[1])
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
        assert.are.equal(0, calls.opens)
    end)

    it('passes spot parameters of unexpected shape through in the marked form', function()
        local handler = setup({ spots = { { SpotType = 'heal', Opacity = 1, Masks = { { MaskID = 'a' }, nil, { MaskID = 'c' } } } } })

        local result = handler.list({ photo_id = '2' })

        assert.are.equal('table', result.spots[1].params.Masks['$lua'])
        assert.are.same({ 3, { MaskID = 'c' } }, result.spots[1].params.Masks.entries[2])
    end)

    it('lists a photo without spots as an empty array', function()
        local handler = setup({ empty = true })
        assert.are.same({}, handler.list({ photo_id = '1' }).spots)
    end)

    it('updates only uppercase Opacity using the full selected table', function()
        local handler, calls, spots, state = setup()
        local second = clone(spots()[2])
        local result = handler.update({ photo_id = '/2.jpg', index = 1, params = { Opacity = 0.4 } })
        assert.are.equal('2', result.photo_id)
        assert.are.equal(0.4, result.params.Opacity)
        assert.are.equal(1, result.params.opacity)
        assert.are.same(second, spots()[2])
        assert.are.equal(1, calls.writes)
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('does not write when the opacity already matches', function()
        local handler, calls = setup()
        assert.is_false(handler.update({ photo_id = '1', index = 1, params = { Opacity = 1 } }).changed)
        assert.are.equal(0, calls.writes)
    end)

    it('deletes only the selected spot and returns shifted indices', function()
        local handler, calls, spots = setup()
        local expected = clone(spots()[2])
        local result = handler.delete({ photo_id = '/2.jpg', index = 1 })
        assert.are.equal('2', result.photo_id)
        assert.are.same({ expected }, spots())
        assert.are.same({ { index = 1, params = expected } }, result.spots)
        assert.are.equal(1, calls.deletes)
    end)

    it('refuses an out-of-range index without a write', function()
        local handler, calls = setup()
        assert.truthy(helper.failedOf(function()
            handler.update({ photo_id = '2', index = 3, params = { Opacity = 0.4 } })
        end):find('valid range: 1..2', 1, true))
        assert.are.equal(0, calls.writes)
    end)

    it('reports the range when SDK selection returns false and leaves all spots unchanged', function()
        local handler, calls, spots, state = setup({ refuse = true })
        local original = clone(spots())
        assert.truthy(helper.failedOf(function()
            handler.delete({ photo_id = '2', index = 1 })
        end):find('valid range: 1..2', 1, true))
        assert.are.same(original, spots())
        assert.are.equal(0, calls.deletes)
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('restores Remove when it was already open', function()
        local handler, _, _, state = setup({ tool = 'dust' })
        handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.3 } })
        assert.are.equal('dust', state().tool)
    end)

    it('restores Masking, not its local Point Color subtool, without a warning', function()
        local handler, calls, spots, state = setup({ tool = 'masking', pointColorSubtool = true })
        local context = helper.requestContext(nil, { title = 'update_spot' })
        handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.3 } }, context)
        assert.are.equal(0.3, spots()[1].Opacity)
        assert.are.same({ 'masking' }, calls.tools)
        assert.are.equal('masking', state().tool)
        assert.are.same({}, context.warnings)
    end)

    it('answers an Opacity Lightroom did not keep, with an unconfirmed rollback, as unknown', function()
        local handler = setup({ keepsOpacity = 0.5, ignoreAfterFirst = true })
        local class, message = helper.outcomeOf(function(context)
            handler.update({ photo_id = '2', index = 1, params = { Opacity = 0.3 } }, context)
        end)
        assert.are.equal("unknown", class)
        assert.truthy(message:find('did not keep Opacity', 1, true))
        assert.is_nil(message:find('restored', 1, true))
        assert.truthy(message:find('list_spots', 1, true))
    end)

    for _, case in ipairs({
        { fake = 'changeOther', names = 'changed another spot' },
        { fake = 'addSpot', names = 'changed the spot count' },
    }) do
        it('answers unknown and writes nothing back when Lightroom changed other spots (' .. case.fake .. ')', function()
            local handler, calls = setup({ [case.fake] = true })
            local class, message = helper.outcomeOf(function(context)
                handler.update({ photo_id = '2', index = 1, params = { Opacity = 0.3 } }, context)
            end)
            assert.are.equal("unknown", class)
            assert.truthy(message:find(case.names, 1, true), message)
            assert.truthy(message:find('list_spots', 1, true), message)
            assert.is_nil(message:find('restored', 1, true), message)
            assert.are.equal(1, calls.writes)
        end)
    end

    it('answers unknown naming the controller writes when Lightroom did not keep the Opacity and Develop shows the'
        .. ' original again, and restores tool and module', function()
        local handler, _, _, state = setup({ ignore = true })
        local class, message = helper.outcomeOf(function(context)
            handler.update({ photo_id = '2', index = 1, params = { Opacity = 0.3 } }, context)
        end)
        assert.are.equal("unknown", class)
        assert.truthy(message:find('did not keep Opacity', 1, true))
        assert.truthy(message:find('original parameters restored', 1, true))
        assert.truthy(message:find('written before this stopped: setSelectedSpotParams', 1, true), message)
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('keeps a finished delete when the tool cannot be restored', function()
        local handler, calls, spots = setup({ ignoreRestore = true })
        local context = helper.requestContext(nil, { title = 'delete_spot' })
        local result = handler.delete({ photo_id = '1', index = 1 }, context)
        assert.is_nil(result.success)
        assert.is_nil(result.warning)
        assert.truthy(context.warnings[1]:find('Could not restore', 1, true))
        assert.are.equal(1, calls.deletes)
        assert.are.equal(1, #spots())
    end)

    it('answers an unknown photo as not found before opening Develop', function()
        local handler, calls = setup()
        assert.are.equal('999', helper.notFoundOf(function() handler.list({ photo_id = '999' }) end))
        assert.are.equal(0, calls.opens)
    end)

    it('answers unknown when writing the spot raises on every call, rollback included', function()
        local handler, calls = setup({ throw = true })
        local class, message = helper.outcomeOf(function(context)
            handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.4 } }, context)
        end)
        assert.are.equal("unknown", class)
        assert.truthy(message:find('SDK failure; rollback not confirmed', 1, true), message)
        assert.are.equal(2, calls.writes)
    end)

    it('answers unknown naming the controller writes when writing the spot raises and Develop shows the original'
        .. ' again', function()
        local handler, calls, spots = setup({ throwAfterWrite = true, ignore = true })
        local before = clone(spots())
        local class, message = helper.outcomeOf(function(context)
            handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.4 } }, context)
        end)
        assert.are.equal("unknown", class)
        assert.truthy(message:find('SDK failure; original parameters restored', 1, true), message)
        assert.truthy(message:find('written before this stopped: setSelectedSpotParams', 1, true), message)
        assert.are.same(before, spots())
        assert.are.equal(2, calls.writes)
    end)

    it('answers unknown when writing the spot raises after Lightroom changed another spot', function()
        local handler, _, spots = setup({ throwAfterWrite = true, ignore = true, changeOther = true })
        local class, message = helper.outcomeOf(function(context)
            handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.4 } }, context)
        end)
        assert.are.equal("unknown", class)
        assert.truthy(message:find('SDK failure', 1, true), message)
        assert.truthy(message:find('Lightroom changed another spot', 1, true), message)
        assert.are.equal(0.1, spots()[2].Opacity)
    end)
end)
