local LrDevelopController = import 'LrDevelopController'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Contract = require 'Contract'
local DevelopSession = require 'DevelopSession'
local Reply = require 'Reply'

local CatalogWrite = {}

CatalogWrite.WAIT_SECONDS = Contract.CATALOG_WRITE_WAIT_SECONDS
CatalogWrite.NOTHING = {}

local RAISE_INSIDE_GATE = {
    applyDevelopSettings = { rolledBack = true, observed = "LrC 16.0, facts pass 2 (w): a develop setting" },
    setRawMetadata = { rolledBack = true, observed = "LrC 16.0, facts pass 2 (w): rating; gate rows D2: gps" },
    createCollectionSet = { rolledBack = true, observed = "LrC 16.0, facts pass 2 (w)" },
    addPhotos = { rolledBack = true, observed = "LrC 16.0, facts pass 2 (w): a photo added to a collection" },
    createKeyword = { rolledBack = true, observed = "LrC 16.0, gate rows 2026-11-16" },
    createDevelopSnapshot = { rolledBack = true, observed = "LrC 16.0, gate rows 2026-11-16" },
    setAttributes = { rolledBack = true, observed = "LrC 16.0, gate rows D2: a keyword's rename" },
    createCollection = { rolledBack = true, observed = "LrC 16.0, gate rows D2" },
    createSmartCollection = { rolledBack = true, observed = "LrC 16.0, gate rows D2" },
    removePhotos = { rolledBack = true, observed = "LrC 16.0, gate rows D2: photos removed from a collection" },
    addKeyword = { rolledBack = true, observed = "LrC 16.0, gate rows D2" },
    removeKeyword = { rolledBack = true, observed = "LrC 16.0, gate rows D2" },
    setPropertyForPlugin = { rolledBack = true, observed = "LrC 16.0, gate rows D2" },
    addPhoto = { rolledBack = false, observed = "LrC 16.0, gate rows 2026-11-16: the photo stays in the catalog" },
    applyDevelopPreset = { rolledBack = false, observed = "LrC 16.0, gate rows 2026-11-16: the preset's settings stay" },
    deleteAllEmptyMasks = { rolledBack = false, observed = "LrC 16.0, gate rows 2026-11-16: the empty group stays deleted" },
    applyDevelopSnapshot = { rolledBack = false, observed = "LrC 16.0, gate rows D2: the snapshot's settings stay" },
    deleteDevelopSnapshot = { rolledBack = false, observed = "LrC 16.0, gate rows D2: the snapshot stays deleted" },
    updateAISettings = { rolledBack = false, observed = "LrC 16.0, gate rows 2026-11-16: the compute runs outside the transaction" },
}

function CatalogWrite.run(context, catalog, title, fn)
    local returned
    local outcome = catalog:withWriteAccessDo(title, function() returned = fn() end,
        { timeout = CatalogWrite.WAIT_SECONDS })
    if outcome == "aborted" then
        Reply.refuse("The catalog stayed busy with another write for " .. CatalogWrite.WAIT_SECONDS
            .. " s, so Lightroom did not run " .. title)
    end
    if returned ~= CatalogWrite.NOTHING then context.ledger:record(title) end
end

function CatalogWrite.developState(catalog, photos, operation)
    for _, photo in ipairs(photos) do DevelopSession.flushIfShowing(catalog, photo) end
    return operation()
end

function CatalogWrite.developSettings(context, catalog, photo, title, settingsFor)
    CatalogWrite.developState(catalog, { photo }, function()
        CatalogWrite.run(context, catalog, title, function()
            local settings = settingsFor()
            if settings == nil then return CatalogWrite.NOTHING end
            CatalogWrite.call(context, photo, "applyDevelopSettings", settings, title)
        end)
    end)
end

function CatalogWrite.call(context, object, method, ...)
    local raised = RAISE_INSIDE_GATE[method]
    if not (raised and raised.rolledBack) then context.ledger:record(method) end
    return object[method](object, ...)
end

function CatalogWrite.invoke(context, what, fn, ...)
    context.ledger:record(what)
    return fn(...)
end

function CatalogWrite.createFolder(context, path)
    if LrFileUtils.exists(path) then return end
    local topmost, parent = path, LrPathUtils.parent(path)
    while parent and not LrFileUtils.exists(parent) do
        topmost, parent = parent, LrPathUtils.parent(parent)
    end
    local mark = context.ledger:mark()
    CatalogWrite.invoke(context, path, LrFileUtils.createAllDirectories, path)
    if not LrFileUtils.exists(topmost) then context.ledger:undone(mark) end
    return topmost
end

function CatalogWrite.copyFile(context, source, target)
    local mark = context.ledger:mark()
    local copied, problem = CatalogWrite.invoke(context, target, LrFileUtils.copy, source, target)
    if copied and LrFileUtils.exists(target) == "file" then return end
    if not LrFileUtils.exists(target) then context.ledger:undone(mark) end
    error("could not copy " .. source .. " to " .. target .. (problem and ": " .. tostring(problem) or ""), 0)
end

function CatalogWrite.develop(context, name, ...)
    context.ledger:record(name, true)
    return LrDevelopController[name](...)
end

return CatalogWrite
