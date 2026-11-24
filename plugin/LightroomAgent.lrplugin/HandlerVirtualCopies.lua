local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"

local CatalogWrite = require "CatalogWrite"
local DevelopBatch = require "DevelopBatch"
local DevelopSession = require "DevelopSession"
local Reply = require "Reply"

local Handler = {}
local RESERVE_SECONDS = 30

local function createOne(context, catalog, photo, state, copyName)
    if not DevelopSession.selectAlone(catalog, photo, state) then
        Reply.refuse("Could not select photo " .. tostring(photo.localIdentifier))
    end
    local masterId = tostring((photo:getRawMetadata("masterPhoto") or photo).localIdentifier)
    local created = CatalogWrite.invoke(context, "createVirtualCopies", catalog.createVirtualCopies, catalog, copyName)
        or {}
    local createdIds = {}
    for index, made in ipairs(created) do
        createdIds[index] = tostring(made.localIdentifier)
    end
    local function stop(problem)
        if #createdIds > 0 then problem = problem .. "; virtual copies created: " .. table.concat(createdIds, ", ") end
        error(problem, 0)
    end
    if #created ~= 1 then stop("Lightroom returned " .. #created .. " virtual copies instead of one") end
    local copyId = createdIds[1]
    local read, copyMaster = LrTasks.pcall(created[1].getRawMetadata, created[1], "masterPhoto")
    if not read then stop(Reply.messageOf(copyMaster)) end
    local copyMasterId = copyMaster and tostring(copyMaster.localIdentifier)
    if copyMasterId ~= masterId then
        stop(
            "Lightroom made virtual copy "
                .. copyId
                .. " of photo "
                .. tostring(copyMasterId)
                .. ", not of photo "
                .. masterId
        )
    end
    return { master_photo_id = masterId, copy_photo_id = copyId }
end

function Handler.create(args, context)
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESERVE_SECONDS,
        each = function(photo, state) return createOne(context, catalog, photo, state, args.copy_name) end,
        dataOf = function(results) return { copies = results } end,
    })
end

return Handler
