local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrSelection = import 'LrSelection'
local LrTasks = import 'LrTasks'

local CatalogWrite = require 'CatalogWrite'
local DevelopSession = require 'DevelopSession'
local PhotoSources = require 'PhotoSources'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local Handler = {}

-- Lightroom drops a selection set while a huge source such as All Photographs is
-- still loading, so the call is repeated until it sticks (#462).
local SELECT_TIMEOUT_SECONDS = 30
local RESELECT_SECONDS = 2

local function selectExactly(catalog, photos)
    return DevelopSession.selectExactly(catalog, photos[1], photos, SELECT_TIMEOUT_SECONDS, RESELECT_SECONDS)
end

local function surviving(catalog, photos)
    local raw = catalog:batchGetRawMetadata(photos, { 'uuid' }) or {}
    local result = {}
    for _, photo in ipairs(photos) do
        if (raw[photo] or {}).uuid then result[#result + 1] = photo end
    end
    return result
end

local function restore(catalog, view)
    local problems = {}
    if not PhotoSources.show(catalog, view.sources) then problems[#problems + 1] = "Lightroom did not reopen the previous source" end
    local ok, result = LrTasks.pcall(function()
        local photos = surviving(catalog, view.selection)
        if #photos > 0 then
            local active = photos[1]
            for _, photo in ipairs(photos) do
                if photo == view.active then active = photo end
            end
            local ordered = { active }
            for _, photo in ipairs(photos) do
                if photo ~= active then ordered[#ordered + 1] = photo end
            end
            if not selectExactly(catalog, ordered) then
                error("Lightroom did not restore the surviving selection")
            end
        else
            LrSelection.selectNone()
            if not DevelopSession.waitFor(function() return catalog:getTargetPhoto() == nil end, 10) then
                error("Lightroom did not restore the empty selection")
            end
        end
    end)
    LrApplicationView.switchToModule(view.module)
    if not ok then problems[#problems + 1] = Reply.messageOf(result) end
    if #problems > 0 then error(table.concat(problems, "; "), 0) end
end

function Handler.removePhotos(args, context)
    local catalog = LrApplication.activeCatalog()
    local entries, notFound, resolved = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    local photos, seen = {}, {}
    for i, entry in ipairs(entries) do
        photos[i] = entry.photo
        seen[entry.photo] = true
    end
    catalog:withReadAccessDo(function()
        local raw = catalog:batchGetRawMetadata(photos, {
            'virtualCopies', 'masterPhoto', 'isInStackInFolder', 'stackInFolderIsCollapsed',
            'topOfStackInFolderContainingPhoto',
        }) or {}
        for _, entry in ipairs(resolved) do
            local info = entry.photo and raw[entry.photo] or {}
            if tonumber(entry.id) == nil and (info.masterPhoto or #(info.virtualCopies or {}) > 0) then
                Reply.refuse("The path " .. tostring(entry.id) .. " names a master and its virtual copies; "
                    .. "pass each photo's numeric id instead")
            end
        end
        for _, photo in ipairs(photos) do
            local info = raw[photo] or {}
            for _, copy in ipairs(info.virtualCopies or {}) do
                if not seen[copy] then
                    Reply.refuse("Include every virtual copy when removing its master from the catalog")
                end
            end
            if info.isInStackInFolder and info.stackInFolderIsCollapsed then
                local top = info.topOfStackInFolderContainingPhoto
                Reply.refuse("Photo " .. tostring(photo.localIdentifier) .. " is in a collapsed stack whose top photo is "
                    .. tostring(top and top.localIdentifier) .. "; expand the stack in Lightroom first, then call again"
                    .. " (Lightroom cannot select a collapsed stack's hidden photos, and removing its top alone"
                    .. " could remove the whole stack)")
            end
        end
    end)
    return DevelopSession.run(context, catalog, false, function()
        local active = catalog:getTargetPhoto()
        local view = {
            module = LrApplicationView.getCurrentModuleName(),
            sources = catalog:getActiveSources(),
            active = active,
            selection = active and catalog:getTargetPhotos() or {},
        }
        local ok, result = LrTasks.pcall(function()
            LrApplicationView.switchToModule("library")
            LrApplicationView.gridView()
            local folders = PhotoSources.foldersOf(catalog, photos)
            local inFolders = folders ~= nil and PhotoSources.show(catalog, folders)
            if not inFolders and not PhotoSources.show(catalog, { catalog.kAllPhotos }) then
                Reply.refuse("Lightroom did not show the photos' folders or All Photographs; nothing was removed")
            end
            Log.info(string.format("remove_photos_from_catalog: selecting %d photo(s) in %s", #photos,
                inFolders and (#folders .. " folder(s)") or "All Photographs"))
            if not selectExactly(catalog, photos) then
                Reply.refuse("Lightroom did not select exactly the requested photos; nothing was removed")
            end
            if LrApplicationView.getCurrentModuleName() ~= "library"
                or not DevelopSession.selectionMatches(catalog, photos[1], photos) then
                Reply.refuse("The selection changed; nothing was removed")
            end
            CatalogWrite.invoke(context, "Remove from Catalog", LrSelection.removeFromCatalog)
            if not DevelopSession.waitFor(function() return #surviving(catalog, photos) == 0 end, 10) then
                error("Lightroom did not remove every requested photo; check the catalog before retrying")
            end
            return Reply.parts({ data = { removed = #photos }, not_found = notFound })
        end)
        local restored, restoreError = LrTasks.pcall(restore, catalog, view)
        if not restored then
            error((ok and "Photos removed" or Reply.messageOf(result))
                .. "; could not restore selection: " .. Reply.messageOf(restoreError), 0)
        end
        if not ok then error(result, 0) end
        return result
    end)
end

return Handler
