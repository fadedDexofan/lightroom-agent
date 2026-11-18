local helper = require 'spec_helper'

describe('HandlerTreatment', function()
    local Handler, catalog, photos, settings, state, calls

    local function setup(opts)
        opts = opts or {}
        photos, settings = {}, {}
        for i = 1, 3 do
            photos[i] = helper.fakePhoto({ id = tostring(i), path = '/' .. i .. '.arw', fileName = i .. '.arw' })
            settings[photos[i]] = { ConvertToGrayscale = false, CameraProfile = 'Adobe Standard',
                Look = { Name = 'Adobe Color', UUID = 'B952C231111CD8E0ECCF14B86BAA7077' } }
            photos[i].getDevelopSettings = function(photo) return settings[photo] end
            photos[i].quickDevelopSetTreatment = function(_, treatment)
                calls.treatments[#calls.treatments + 1] = treatment
                if opts.ignore or (opts.dropsFirst and #calls.treatments == 1) then return end
                for _, selected in ipairs(state.selected) do
                    local grey = treatment == 'grayscale'
                    settings[selected].ConvertToGrayscale = grey
                    if settings[selected].Look then
                        settings[selected].Look = { Name = grey and 'Adobe Monochrome' or 'Adobe Color' }
                    end
                end
            end
        end
        settings[photos[2]] = { ConvertToGrayscale = false, CameraProfile = 'Embedded' }
        state = { active = photos[3], selected = { photos[3], photos[1] }, sources = { 'collection' } }
        calls = { treatments = {}, selections = {} }
        catalog = helper.fakeCatalog({ photos = photos })
        catalog.kAllPhotos = 'all'
        catalog.getTargetPhoto = function() return state.active end
        catalog.getTargetPhotos = function() return state.selected end
        catalog.getActiveSources = function() return state.sources end
        catalog.setActiveSources = function(_, sources) state.sources = sources end
        catalog.setSelectedPhotos = function(_, active, selected)
            calls.selections[#calls.selections + 1] = selected
            if opts.unselectable and active == photos[1] then return end
            state.active, state.selected = active, selected
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrApplicationView = { getCurrentModuleName = function() return 'library' end, switchToModule = function() end },
            LrDate = { currentTime = function() return 0 end },
            LrLogger = helper.defaultLrLogger(),
            LrProgressScope = function() return { setCancelable = function() end, setPortionComplete = function() end,
                setCaption = function() end, done = function() end, isCanceled = function() return false end } end,
            LrSelection = { selectNone = function() state.active, state.selected = nil, {} end },
            LrTasks = { pcall = pcall, sleep = function() end },
        })
        package.loaded.DevelopSession = nil
        package.loaded.DevelopBatch = nil
        package.loaded.HandlerTreatment = nil
        Handler = require 'HandlerTreatment'
    end

    local function assertRestored()
        assert.are.equal(photos[3], state.active)
        assert.are.same({ photos[3], photos[1] }, state.selected)
        assert.are.same({ 'collection' }, state.sources)
    end

    it('converts each photo alone through Lightroom and reports the flag and the profile before and after', function()
        setup()
        local result = Handler.set({ photo_ids = { '1', '/2.arw' }, treatment = 'black_and_white' })
        assert.are.same({ results = {
            { photo_id = '1', treatment = 'black_and_white', convert_to_grayscale = true,
                profile = { before = 'Adobe Color', after = 'Adobe Monochrome' } },
            { photo_id = '2', treatment = 'black_and_white', convert_to_grayscale = true,
                profile = { before = 'Embedded', after = 'Embedded' } },
        } }, result.data)
        assert.are.same({ 'grayscale', 'grayscale' }, calls.treatments)
        assert.are.same({ photos[1] }, calls.selections[1])
        assert.is_false(settings[photos[3]].ConvertToGrayscale)
        assertRestored()
    end)

    it('switches back to color', function()
        setup()
        Handler.set({ photo_ids = { '1' }, treatment = 'black_and_white' })
        local result = Handler.set({ photo_ids = { '1' }, treatment = 'color' })
        assert.are.same({ photo_id = '1', treatment = 'color', convert_to_grayscale = false,
            profile = { before = 'Adobe Monochrome', after = 'Adobe Color' } },
            result.data.results[1])
        assert.are.same({ 'grayscale', 'color' }, calls.treatments)
    end)

    it('sends a dispatch Lightroom dropped once more and answers by the read', function()
        setup({ dropsFirst = true })
        local result = Handler.set({ photo_ids = { '1' }, treatment = 'black_and_white' })
        assert.is_nil(result.unknown)
        assert.is_true(result.data.results[1].convert_to_grayscale)
        assert.are.same({ 'grayscale', 'grayscale' }, calls.treatments)
        assertRestored()
    end)

    it('reports a photo Lightroom did not convert after the second dispatch as unknown, naming the dispatch', function()
        setup({ ignore = true })
        local result = Handler.set({ photo_ids = { '1' }, treatment = 'black_and_white' })
        assert.is_nil(result.data)
        assert.are.equal('1', result.unknown[1].photo_id)
        assert.are.equal('Lightroom did not change the treatment after two dispatches; ConvertToGrayscale reads false;'
            .. ' written before this stopped: quickDevelopSetTreatment', result.unknown[1].reason)
        assert.are.same({ 'grayscale', 'grayscale' }, calls.treatments)
        assertRestored()
    end)

    it('refuses a photo it cannot select alone without converting anything', function()
        setup({ unselectable = true })
        local result = Handler.set({ photo_ids = { '1', '2' }, treatment = 'black_and_white' })
        assert.are.same({ photo_id = '1', reason = 'Could not select photo 1 alone' }, result.failed[1])
        assert.are.equal('2', result.data.results[1].photo_id)
        assert.are.same({ 'grayscale' }, calls.treatments)
        assert.is_false(settings[photos[1]].ConvertToGrayscale)
    end)

    it('answers unknown inputs as not_found without touching the selection', function()
        setup()
        local result = Handler.set({ photo_ids = { '999' }, treatment = 'color' })
        assert.is_nil(result.data)
        assert.are.same({ '999' }, result.not_found)
        assert.are.same({}, calls.selections)
    end)
end)
