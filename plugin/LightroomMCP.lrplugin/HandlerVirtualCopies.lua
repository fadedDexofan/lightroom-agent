local LrApplication = import 'LrApplication'

local DevelopBatch = require 'DevelopBatch'
local DevelopSession = require 'DevelopSession'
local Reply = require 'Reply'

local Handler = {}
local RESERVE_SECONDS = 30

local function createOne(catalog, photo, state, copyName)
    if not DevelopSession.selectAlone(catalog, photo, state) then
        Reply.refuse('Could not select photo ' .. tostring(photo.localIdentifier))
    end
    local created = catalog:createVirtualCopies(copyName) or {}
    if #created ~= 1 then error('Lightroom did not return exactly one virtual copy') end
    local copy = created[1]
    if not copy:getRawMetadata('isVirtualCopy') then error('Lightroom did not return a virtual copy') end
    local master = copy:getRawMetadata('masterPhoto')
    if not master then error('Virtual copy has no master photo') end
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
        each = function(photo, state) return createOne(catalog, photo, state, args.copy_name) end,
    })
    if parts.data then parts.data = { copies = parts.data.results } end
    return parts
end

return Handler
