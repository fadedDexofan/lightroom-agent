local LrApplication = import 'LrApplication'

local CatalogWrite = require 'CatalogWrite'
local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local Handler = {}

local function resolve(args)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    return catalog, photo, tostring(photo.localIdentifier)
end

local function snapshots(photo)
    local result = {}
    for _, snapshot in ipairs(photo:getDevelopSnapshots() or {}) do
        result[#result + 1] = { id = tostring(snapshot.snapshotID), name = snapshot.name }
    end
    return result
end

local function find(photo, id)
    for _, snapshot in ipairs(photo:getDevelopSnapshots() or {}) do
        if tostring(snapshot.snapshotID) == id then return snapshot end
    end
    return nil
end

local function requireSnapshot(photo, id)
    if not find(photo, id) then Reply.refuse('Snapshot not found on this photo: ' .. id) end
end

function Handler.list(args)
    local _, photo, photoId = resolve(args)
    return { photo_id = photoId, snapshots = snapshots(photo) }
end

function Handler.create(args, context)
    local catalog, photo, photoId = resolve(args)
    CatalogWrite.run(context, catalog, 'Create Develop Snapshot', function()
        if not CatalogWrite.call(context, photo, "createDevelopSnapshot", args.name, args.replace == true) then
            Reply.refuse('Snapshot name already exists: ' .. args.name)
        end
    end)
    -- Lightroom publishes the new snapshot only after the write gate returns.
    for _, snapshot in ipairs(snapshots(photo)) do
        if snapshot.name == args.name then return { photo_id = photoId, snapshot = snapshot } end
    end
    error('Created snapshot could not be read back')
end

function Handler.apply(args, context)
    local catalog, photo, photoId = resolve(args)
    requireSnapshot(photo, args.snapshot_id)
    DevelopSession.withPhoto(context, catalog, photo, function()
        CatalogWrite.run(context, catalog, 'Apply Develop Snapshot', function()
            CatalogWrite.call(context, photo, "applyDevelopSnapshot", find(photo, args.snapshot_id).snapshotID)
        end)
    end)
    return { photo_id = photoId, snapshot_id = args.snapshot_id }
end

function Handler.delete(args, context)
    local catalog, photo, photoId = resolve(args)
    requireSnapshot(photo, args.snapshot_id)
    DevelopSession.withPhoto(context, catalog, photo, function()
        CatalogWrite.run(context, catalog, 'Delete Develop Snapshot', function()
            CatalogWrite.call(context, photo, "deleteDevelopSnapshot", find(photo, args.snapshot_id).id_global)
        end)
        local deleted = DevelopSession.waitFor(function()
            return find(photo, args.snapshot_id) == nil
        end, 5)
        if not deleted then error('Lightroom did not delete snapshot: ' .. args.snapshot_id) end
    end)
    return { photo_id = photoId, snapshot_id = args.snapshot_id }
end

return Handler
