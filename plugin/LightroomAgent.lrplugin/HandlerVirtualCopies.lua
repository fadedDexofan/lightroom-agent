local LrApplication = import 'LrApplication'

local CatalogWrite = require 'CatalogWrite'
local DevelopBatch = require 'DevelopBatch'
local DevelopSession = require 'DevelopSession'
local Reply = require 'Reply'

local Handler = {}
local RESERVE_SECONDS = 30

local function createOne(context, catalog, photo, state, copyName)
    if not DevelopSession.selectAlone(catalog, photo, state) then
        Reply.refuse('Could not select photo ' .. tostring(photo.localIdentifier))
    end
    local created = CatalogWrite.invoke(context, "createVirtualCopies", catalog.createVirtualCopies, catalog, copyName) or {}
    if #created ~= 1 then error('Lightroom did not return exactly one virtual copy') end
    local copy = created[1]
    local master = copy:getRawMetadata('masterPhoto')
    return {
        master_photo_id = tostring(master.localIdentifier),
        copy_photo_id = tostring(copy.localIdentifier),
    }
end

function Handler.create(args, context)
    local catalog = LrApplication.activeCatalog()
    local parts = DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESERVE_SECONDS,
        each = function(photo, state) return createOne(context, catalog, photo, state, args.copy_name) end,
    })
    if parts.data then parts.data = { copies = parts.data.results } end
    return parts
end

return Handler
