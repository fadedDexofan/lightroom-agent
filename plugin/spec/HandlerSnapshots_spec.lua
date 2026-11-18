local helper = require 'spec_helper'
local fake = require 'fake_mask_develop'

describe('develop snapshots', function()
    local handler, photo, other, state, calls, develop
    before_each(function()
        state, calls = {}, {}
        develop = fake.build({
            photos = { { id = '1' }, { id = '2' } },
            handler = 'HandlerSnapshots',
            modules = { 'HandlerSnapshots', 'DevelopSession', 'PhotoLookup', 'CatalogWrite' },
        })
        photo, other = develop.photos[1], develop.photos[2]
        local function inDevelop() return develop.module == 'develop' and develop.active == photo end
        local serial = 0
        local writing, createdInGate = false, false
        photo.getDevelopSnapshots = function()
            if writing and createdInGate then return {} end
            return state
        end
        other.getDevelopSnapshots = function() return {} end
        photo.createDevelopSnapshot = function(_, name, replace)
            createdInGate = true
            for _, item in ipairs(state) do
                if item.name == name then
                    if not replace then return false end
                    calls.replaced = item.snapshotID
                    return true
                end
            end
            serial = serial + 1
            state[#state + 1] = { snapshotID = 'snapshot-' .. serial, id_global = 'global-' .. serial, name = name }
            return true
        end
        photo.applyDevelopSnapshot = function(_, id)
            assert.is_true(inDevelop())
            calls.applied = id
        end
        photo.deleteDevelopSnapshot = function(_, id)
            assert.is_true(inDevelop())
            calls.deleted = id
            for i, item in ipairs(state) do
                if item.id_global == id then table.remove(state, i) return end
            end
        end
        local catalog = develop.catalog
        local writeAccess = catalog.withWriteAccessDo
        catalog.withWriteAccessDo = function(self, name, fn)
            writing, createdInGate = true, false
            local ok, result = pcall(writeAccess, self, name, fn)
            writing = false
            if not ok then error(result) end
            return result
        end
        handler = develop.Handler
    end)

    it('lists an empty photo and returns created ids and names under the resolved photo id', function()
        local listed = handler.list({ photo_id = '/1.jpg' })
        assert.same({ photo_id = '1', snapshots = {} }, listed)
        local result = handler.create({ photo_id = '/1.jpg', name = 'before' })
        assert.same({ photo_id = '1', snapshot = { id = 'snapshot-1', name = 'before' } }, result)
        assert.same({ result.snapshot }, handler.list({ photo_id = 1 }).snapshots)
    end)

    it('refuses duplicate names unless replacement is requested', function()
        local first = handler.create({ photo_id = '1', name = 'before' }).snapshot
        assert.equals('Snapshot name already exists: before',
            helper.failedOf(function() handler.create({ photo_id = '1', name = 'before' }) end))
        assert.same({ first }, handler.list({ photo_id = '1' }).snapshots)
        assert.is_nil(calls.replaced)
        assert.same(first, handler.create({ photo_id = '1', name = 'before', replace = true }).snapshot)
        assert.equals(first.id, calls.replaced)
    end)

    it('applies and deletes only the requested snapshot, answering with the resolved photo id', function()
        local first = handler.create({ photo_id = '1', name = 'a' }).snapshot
        local second = handler.create({ photo_id = '1', name = 'b' }).snapshot
        assert.same({ photo_id = '1', snapshot_id = first.id },
            handler.apply({ photo_id = '/1.jpg', snapshot_id = first.id }))
        assert.equals(first.id, calls.applied)
        assert.same({ photo_id = '1', snapshot_id = first.id },
            handler.delete({ photo_id = '/1.jpg', snapshot_id = first.id }))
        assert.equals('global-1', calls.deleted)
        assert.same({ second }, handler.list({ photo_id = '1' }).snapshots)
        assert.same({ 'develop', 'library', 'develop', 'library' }, develop.calls.modules)
    end)

    it('answers unknown when Lightroom silently ignores a deletion', function()
        local first = handler.create({ photo_id = '1', name = 'a' }).snapshot
        photo.deleteDevelopSnapshot = function() end
        local class, message = helper.outcomeOf(function(context)
            handler.delete({ photo_id = '1', snapshot_id = first.id }, context)
        end)
        assert.equals('unknown', class)
        assert.matches('Lightroom did not delete snapshot', message, 1, true)
        assert.same({ first }, handler.list({ photo_id = '1' }).snapshots)
    end)

    for _, action in ipairs({ 'apply', 'delete' }) do
        it('refuses unknown and foreign snapshot ids for ' .. action, function()
            local first = handler.create({ photo_id = '1', name = 'a' }).snapshot
            assert.equals('Snapshot not found on this photo: missing',
                helper.failedOf(function() handler[action]({ photo_id = '1', snapshot_id = 'missing' }) end))
            assert.equals('Snapshot not found on this photo: ' .. first.id,
                helper.failedOf(function() handler[action]({ photo_id = '2', snapshot_id = first.id }) end))
            assert.same({}, calls)
            assert.same({ first }, handler.list({ photo_id = '1' }).snapshots)
        end)
    end

    it('answers an unknown photo as not found for every operation', function()
        for _, action in ipairs({ 'create', 'list', 'apply', 'delete' }) do
            assert.equals('999', helper.notFoundOf(function()
                handler[action]({ photo_id = '999', name = 'a', snapshot_id = 'missing' })
            end))
        end
        assert.same({}, state)
        assert.same({}, calls)
    end)
end)
