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
    local masterId = tostring((photo:getRawMetadata('masterPhoto') or photo).localIdentifier)
    local created = CatalogWrite.invoke(context, "createVirtualCopies", catalog.createVirtualCopies, catalog, copyName) or {}
    for _, made in ipairs(created) do context.ledger:record('virtual copy ' .. tostring(made.localIdentifier)) end
    if #created ~= 1 then error('Lightroom returned ' .. #created .. ' virtual copies instead of one', 0) end
    local copyId = tostring(created[1].localIdentifier)
    local copyMaster = created[1]:getRawMetadata('masterPhoto')
    local copyMasterId = copyMaster and tostring(copyMaster.localIdentifier)
    if copyMasterId ~= masterId then
        error('Lightroom made virtual copy ' .. copyId .. ' of photo ' .. tostring(copyMasterId)
            .. ', not of photo ' .. masterId, 0)
    end
    return { master_photo_id = masterId, copy_photo_id = copyId }
end

function Handler.create(args, context)
    local catalog = LrApplication.activeCatalog()
    local parts = DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESERVE_SECONDS,
        each = function(photo, state)
            return CatalogWrite.developState(catalog, { photo }, function()
                return createOne(context, catalog, photo, state, args.copy_name)
            end)
        end,
    })
    if parts.data then parts.data = { copies = parts.data.results } end
    return parts
end

return Handler
