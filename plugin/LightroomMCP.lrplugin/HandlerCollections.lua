local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local CatalogWrite = require 'CatalogWrite'
local Contract = require 'Contract'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'
local Log = require 'Log'
local PhotoSummary = require 'PhotoSummary'
local SearchHandler = require 'HandlerSearch'

local CollectionsHandler = {}

function CollectionsHandler.listCollections(args)
    local catalog = LrApplication.activeCatalog()
    local all = {}

    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0

    catalog:withReadAccessDo(function()
        for _, collection in ipairs(catalog:getChildCollections()) do
            table.insert(all, {
                collection = collection,
                name = collection:getName(),
                is_smart = collection:isSmartCollection(),
            })
        end

        local function addCollectionsFromSet(collSet, prefix)
            for _, coll in ipairs(collSet:getChildCollections()) do
                table.insert(all, {
                    collection = coll,
                    name = prefix .. coll:getName(),
                    is_smart = coll:isSmartCollection(),
                })
            end
            for _, childSet in ipairs(collSet:getChildCollectionSets()) do
                addCollectionsFromSet(childSet, prefix .. childSet:getName() .. " / ")
            end
        end

        for _, set in ipairs(catalog:getChildCollectionSets()) do
            addCollectionsFromSet(set, set:getName() .. " / ")
        end
    end)

    local total = #all
    local last = math.min(offset + limit, total)
    local slice = {}
    for i = offset + 1, last do
        local entry = all[i]
        entry.photo_count = #(entry.collection:getPhotos() or {})
        entry.collection = nil
        table.insert(slice, entry)
    end

    Log.info(string.format("Found %d collections, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        collections = slice,
        has_more = (offset + #slice) < total,
    }
end

-- Splits a collection set path on the " / " separator listCollections uses.
local function splitSetPath(path)
    local names = {}
    local rest = path
    while true do
        local first, last = rest:find(" / ", 1, true)
        local name = first and rest:sub(1, first - 1) or rest
        if name:match("^%s*$") then
            Reply.refuse("parent contains an empty collection set name: " .. path)
        end
        -- Edge spaces or slashes come from a malformed separator ("A /",
        -- "A / /B"); the set would exist but its path could not be read back.
        if name:match("^[%s/]") or name:match("[%s/]$") then
            Reply.refuse(string.format(
                "parent has a malformed collection set name '%s'; separate sets with ' / ': %s",
                name, path))
        end
        table.insert(names, name)
        if not first then
            return names
        end
        rest = rest:sub(last + 1)
    end
end

-- Lightroom compares sibling names ignoring case, and collections and
-- collection sets under one parent share those names.
local function findNamed(items, name)
    local wanted = name:lower()
    for _, item in ipairs(items) do
        if item:getName():lower() == wanted then
            return item
        end
    end
    return nil
end

local function createCollection(args, searchDesc)
    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name
    local setNames = args.parent and splitSetPath(args.parent) or {}
    local parentSet = nil
    local existingLevels = 0
    local problem = nil

    -- Existing sets are reused under their stored names: asking Lightroom to
    -- create "trips" beside "Trips" fails with "name is not unique".
    if setNames[1] then
        catalog:withReadAccessDo(function()
            local sets = catalog:getChildCollectionSets()
            local collections = catalog:getChildCollections()
            for i, setName in ipairs(setNames) do
                local found = findNamed(sets, setName)
                if not found then
                    if findNamed(collections, setName) then
                        problem = string.format("parent '%s' names a collection, not a collection set", setName)
                    end
                    break
                end
                setNames[i] = found:getName()
                parentSet = found
                existingLevels = i
                sets = found:getChildCollectionSets()
                collections = found:getChildCollections()
            end
        end)
    end
    if problem then Reply.refuse(problem) end

    local parentPath = table.concat(setNames, " / ")
    local path = setNames[1] and (parentPath .. " / " .. collectionName) or collectionName

    -- Lightroom refuses to read a collection set in the withWriteAccessDo that
    -- created it ("Can't get collection information after creating collection
    -- inside the same withWriteAccessDo function"), so the collection goes in
    -- a second gate, where the new set can be read.
    local createdSets = nil
    if existingLevels < #setNames then
        local created, setsError = LrTasks.pcall(CatalogWrite.run, catalog, "Create Collection Sets", function()
            for i = existingLevels + 1, #setNames do
                local set = catalog:createCollectionSet(setNames[i], parentSet, true)
                -- A name clash returns nil instead of raising; the failed gate
                -- rolls back the sets created before it.
                if not set then
                    problem = "Lightroom did not create collection set: " .. setNames[i]
                    error(problem, 0)
                end
                parentSet = set
            end
        end)
        if not created then
            if problem then Reply.refuse(problem) end
            error(setsError, 0)
        end
        createdSets = "the collection sets " .. table.concat(setNames, " / ", existingLevels + 1) .. " were created"
    end

    CatalogWrite.run(catalog, "Create Collection", function()
        -- Checked inside the gate that creates, so a concurrent create cannot
        -- slip in between. A same-named collection would also make
        -- add_to_collection's bare-name lookup ambiguous.
        local collections = parentSet and parentSet:getChildCollections() or catalog:getChildCollections()
        local sets = parentSet and parentSet:getChildCollectionSets() or catalog:getChildCollectionSets()
        if findNamed(collections, collectionName) then
            problem = "Collection already exists: " .. path
            return
        end
        local clash = findNamed(sets, collectionName)
        if clash then
            problem = string.format("A collection set named '%s' already exists %s",
                clash:getName(), parentSet and ("in " .. parentPath) or "at the top level")
            return
        end

        local created
        if searchDesc then
            created = catalog:createSmartCollection(collectionName, searchDesc, parentSet, false)
        else
            created = catalog:createCollection(collectionName, parentSet, false)
        end
        if not created then
            if not createdSets then
                problem = "Lightroom did not create collection: " .. path
                return
            end
            error("Lightroom did not create collection: " .. path .. "; " .. createdSets, 0)
        end
        Log.info("Created collection: " .. path)
    end, createdSets)
    if problem then Reply.refuse(problem) end

    return { path = path }
end

function CollectionsHandler.createCollection(args)
    return createCollection(args)
end

function CollectionsHandler.createSmartCollection(args)
    return createCollection(args, SearchHandler.buildSearchDesc(args))
end

-- Match the paths returned by listCollections, then bare names of nested
-- collections. A listed path wins: a top-level "City" beside "Trips / City"
-- has no other name to be addressed by.
local function findAllCollections(catalog, name)
    local byPath = {}
    local byName = {}
    for _, collection in ipairs(catalog:getChildCollections()) do
        if collection:getName() == name then
            table.insert(byPath, collection)
        end
    end

    local function findInSet(collSet, prefix)
        for _, coll in ipairs(collSet:getChildCollections()) do
            if prefix .. coll:getName() == name then
                table.insert(byPath, coll)
            elseif coll:getName() == name then
                table.insert(byName, coll)
            end
        end
        for _, childSet in ipairs(collSet:getChildCollectionSets()) do
            findInSet(childSet, prefix .. childSet:getName() .. " / ")
        end
    end

    for _, set in ipairs(catalog:getChildCollectionSets()) do
        findInSet(set, set:getName() .. " / ")
    end

    if byPath[1] then
        return byPath
    end
    return byName
end

-- Resolves a bare name or listed path to exactly one collection. A bare name
-- shared by several collections is rejected rather than resolved to whichever
-- enumerates first.
local function findOneCollection(catalog, name)
    local matches = findAllCollections(catalog, name)
    if #matches == 0 then
        Reply.refuse("Collection not found: " .. name)
    end
    if #matches > 1 then
        Reply.refuse(string.format("%d collections are named '%s'; use a collection path", #matches, name))
    end
    return matches[1]
end

local function findOneRegularCollection(catalog, name)
    local collection = findOneCollection(catalog, name)
    if collection:isSmartCollection() then
        Reply.refuse("Cannot add or remove photos in a smart collection: " .. name)
    end
    return collection
end

CollectionsHandler.findOneRegularCollection = findOneRegularCollection

function CollectionsHandler.addToCollection(args)

    local catalog = LrApplication.activeCatalog()

    -- Reject an unknown collection BEFORE resolving ids. Resolution scans the
    -- whole catalog and costs tens of seconds on a large library; spending that
    -- only to discover a typo'd name pushed the request past the server's
    -- timeout, so the caller got no answer at all instead of "Collection not
    -- found".
    catalog:withReadAccessDo(function()
        findOneRegularCollection(catalog, args.collection_name)
    end)

    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    local addedCount = 0
    local alreadyInCollection = {}

    CatalogWrite.run(catalog, "Add Photos to Collection", function()
        -- Looked up again rather than carried across gates: the check above
        -- only proved the name resolved then, and the write gate is what makes
        -- the result safe to act on.
        local targetCollection = findOneRegularCollection(catalog, args.collection_name)
        local members = {}
        for _, photo in ipairs(targetCollection:getPhotos()) do members[photo] = true end
        local photosToAdd = {}
        for _, entry in ipairs(entries) do
            if members[entry.photo] then
                alreadyInCollection[#alreadyInCollection + 1] = tostring(entry.photo.localIdentifier)
            else
                photosToAdd[#photosToAdd + 1] = entry.photo
            end
        end
        if #photosToAdd > 0 then
            targetCollection:addPhotos(photosToAdd)
            addedCount = #photosToAdd
        end
    end)

    Log.info(string.format("Added %d photos to collection: %s", addedCount, args.collection_name))

    return Reply.parts({
        data = { added = addedCount, already_in_collection = alreadyInCollection },
        not_found = notFound,
    })
end

-- Removes photos from a collection only; they stay in the catalog.
function CollectionsHandler.removeFromCollection(args)

    local catalog = LrApplication.activeCatalog()
    local removedCount = 0
    local notInCollection = {}

    -- Checked before resolving ids, as add_to_collection does: resolution scans
    -- the catalog, too slow to spend on a typo'd name.
    catalog:withReadAccessDo(function()
        findOneRegularCollection(catalog, args.collection_name)
    end)

    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end

    CatalogWrite.run(catalog, "Remove Photos from Collection", function()
        local targetCollection = findOneRegularCollection(catalog, args.collection_name)

        local members = {}
        for _, photo in ipairs(targetCollection:getPhotos()) do
            members[photo] = true
        end

        -- Only members count as removed, so `removed` says what changed rather
        -- than echoing how many ids were sent.
        local photosToRemove = {}
        for _, entry in ipairs(entries) do
            if members[entry.photo] then
                photosToRemove[#photosToRemove + 1] = entry.photo
            else
                notInCollection[#notInCollection + 1] = tostring(entry.photo.localIdentifier)
            end
        end

        if #photosToRemove > 0 then
            targetCollection:removePhotos(photosToRemove)
            removedCount = #photosToRemove
        end
    end)

    Log.info(string.format("Removed %d photos from collection: %s", removedCount, args.collection_name))

    return Reply.parts({
        data = { removed = removedCount, not_in_collection = notInCollection },
        not_found = notFound,
    })
end

-- Returns a page of a collection's photos, regular or smart, in the shape
-- search_photos uses.
function CollectionsHandler.getCollectionPhotos(args)

    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0

    local catalog = LrApplication.activeCatalog()

    local collection
    catalog:withReadAccessDo(function()
        collection = findOneCollection(catalog, args.collection_name)
    end)

    -- OUTSIDE withReadAccessDo: a smart collection's getPhotos() runs a
    -- catalog search, and a query that yields inside the read gate deadlocks
    -- on Windows (#134/#124), as getTargetPhotos and findPhotos do.
    local photos = collection:getPhotos() or {}
    local total = #photos

    local last = math.min(offset + limit, total)
    local results = PhotoSummary.page(catalog, photos, offset + 1, last, args.include_path == true)

    Log.info(string.format("Collection %s has %d photos, returning %d (offset=%d, limit=%d)",
        args.collection_name, total, #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

-- Deletes the collection itself; its photos stay in the catalog.
function CollectionsHandler.deleteCollection(args)

    local catalog = LrApplication.activeCatalog()
    local found
    catalog:withReadAccessDo(function()
        found = findOneCollection(catalog, args.collection_name)
    end)
    local photoCount = #(found:getPhotos() or {})

    CatalogWrite.run(catalog, "Delete Collection", function()
        findOneCollection(catalog, args.collection_name):delete()
    end)

    Log.info(string.format("Deleted collection: %s (%d photos, still in the catalog)",
        args.collection_name, photoCount))

    return { photo_count = photoCount }
end

return CollectionsHandler
