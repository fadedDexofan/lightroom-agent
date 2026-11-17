local LrApplication = import 'LrApplication'

local CatalogWrite = require 'CatalogWrite'
local Contract = require 'Contract'
local KeywordTree = require 'KeywordTree'
local PhotoLookup = require 'PhotoLookup'
local PhotoWrites = require 'PhotoWrites'
local Log = require 'Log'
local Reply = require 'Reply'

local OrganizationHandler = {}

-- Set while a setKeywords call runs; still set at the next call's start when
-- the last one failed part-way.
local keywordCallFailed = false

-- Splits the requested keywords into plain names and hierarchy paths.
-- A string containing "|" is a parent-first path ("Places|Europe|Paris");
-- anything else is a plain name.
local function parseKeywordList(keywords)
    local entries = {}
    local seen = {}
    for _, kw in ipairs(keywords or {}) do
        local entry, dedupeKey
        if KeywordTree.isPath(kw) then
            local parts = KeywordTree.split(kw)
            entry = { parts = parts, key = KeywordTree.join(parts) }
            -- Lightroom matches paths case-insensitively, so "A|B" and "a|b"
            -- address one keyword.
            dedupeKey = KeywordTree.fold(entry.key)
        else
            -- Trimmed like a path level, so the keyword created for it is found
            -- again by name.
            local name = KeywordTree.trim(kw)
            if name == "" then
                Reply.refuse("Invalid keyword (empty): '" .. kw .. "'")
            end
            entry = { name = name, key = name }
            -- Exact: a plain-name remove matches exact case, so "Paris" and
            -- "paris" are two removals. Case variants of an add are deduped
            -- where they are created.
            dedupeKey = "=" .. name
        end
        if not seen[dedupeKey] then
            seen[dedupeKey] = true
            table.insert(entries, entry)
        end
    end
    return entries
end

-- create_missing = false: every keyword to add must already exist. Returns a
-- list of problems (empty when all resolve) without touching the catalog.
local function findUnresolvable(catalog, addEntries)
    local problems = {}
    for _, entry in ipairs(addEntries) do
        if entry.parts then
            if not KeywordTree.resolve(catalog, entry.parts) then
                table.insert(problems, "not found: " .. entry.key)
            end
        else
            local matches = KeywordTree.findByName(catalog, entry.name)
            if #matches == 0 then
                table.insert(problems, "not found: " .. entry.name)
            elseif #matches > 1 then
                local paths = {}
                for _, match in ipairs(matches) do
                    table.insert(paths, match.path)
                end
                table.insert(problems, "ambiguous: " .. entry.name
                    .. " (" .. table.concat(paths, ", ") .. ")")
            end
        end
    end
    return problems
end

-- Creates every missing level of `pathsToEnsure` (lists of names). Lightroom
-- rejects a parent created earlier in the same write transaction ("bad
-- argument #2 to 'format'"), so each depth gets its own transaction, run after
-- the level above it is committed and visible to getChildren().
local function createMissingLevels(context, catalog, pathsToEnsure)
    local function prefixOf(parts, depth)
        local prefix = {}
        for i = 1, depth do
            prefix[i] = parts[i]
        end
        return prefix
    end

    local maxDepth = 0
    for _, parts in ipairs(pathsToEnsure) do
        maxDepth = math.max(maxDepth, #parts)
    end

    for depth = 1, maxDepth do
        local missing = {}
        catalog:withReadAccessDo(function()
            local seen = {}
            -- One index per parent at this depth; the top level uses the
            -- cached one.
            local indexes = {}
            for _, parts in ipairs(pathsToEnsure) do
                if #parts >= depth then
                    local folded = KeywordTree.fold(KeywordTree.join(prefixOf(parts, depth)))
                    if not seen[folded] then
                        seen[folded] = true
                        local parent = nil
                        if depth > 1 then
                            local parentParts = prefixOf(parts, depth - 1)
                            parent = KeywordTree.resolve(catalog, parentParts)
                            if not parent then
                                error("Keyword level was not created: " .. KeywordTree.join(parentParts))
                            end
                        end
                        local existing
                        if parent then
                            indexes[parent] = indexes[parent] or KeywordTree.childIndex(catalog, parent)
                            existing = indexes[parent][KeywordTree.fold(parts[depth])]
                        else
                            existing = KeywordTree.findTopLevel(catalog, parts[depth])
                        end
                        if not existing then
                            table.insert(missing, {
                                parent = parent, name = parts[depth], path = KeywordTree.join(prefixOf(parts, depth)),
                            })
                        end
                    end
                end
            end
        end)

        if #missing > 0 then
            CatalogWrite.run(context, catalog, "Create Keywords", function()
                for _, level in ipairs(missing) do
                    CatalogWrite.call(context, catalog, "createKeyword", level.name, {}, true, level.parent, true)
                end
            end)
            -- The cached top-level index has not seen what was just created.
            if depth == 1 then KeywordTree.forgetTopIndex() end
        end
    end
end

function OrganizationHandler.setKeywords(args, context)

    -- Default true: a plain name that does not exist yet is created.
    local createMissing = args.create_missing ~= false

    local catalog = LrApplication.activeCatalog()

    -- A call that failed part-way may have changed keywords behind the cached
    -- top-level index.
    if keywordCallFailed then KeywordTree.forgetTopIndex() end
    keywordCallFailed = true

    local addEntries = parseKeywordList(args.add_keywords)

    local removeNames = {}
    local removePaths = {}
    local hasRemovePaths = false
    for _, entry in ipairs(parseKeywordList(args.remove_keywords)) do
        if entry.parts then
            removePaths[KeywordTree.fold(entry.key)] = true
            hasRemovePaths = true
        else
            removeNames[entry.name] = true
        end
    end

    -- Reject unknown or ambiguous keywords BEFORE resolving ids or opening the
    -- write gate, so a strict call that cannot be honoured changes nothing.
    if not createMissing and #addEntries > 0 then
        local problems = {}
        catalog:withReadAccessDo(function()
            problems = findUnresolvable(catalog, addEntries)
        end)
        if #problems > 0 then
            Reply.refuse("Keywords not resolved (create_missing is false): "
                .. table.concat(problems, "; "))
        end
    end

    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then
        keywordCallFailed = false
        return Reply.parts({ not_found = notFound })
    end

    -- A plain name is created at the top level.
    if createMissing and #addEntries > 0 then
        local pathsToEnsure = {}
        for _, entry in ipairs(addEntries) do
            table.insert(pathsToEnsure, entry.parts or { entry.name })
        end
        createMissingLevels(context, catalog, pathsToEnsure)
    end

    CatalogWrite.run(context, catalog, "Set Keywords", function()
        local keywordObjs = {}
        local seenKeywords = {}
        for _, entry in ipairs(addEntries) do
            local keyword
            if entry.parts then
                keyword = KeywordTree.resolve(catalog, entry.parts)
            elseif createMissing then
                keyword = KeywordTree.findTopLevel(catalog, entry.name)
                if not keyword then
                    -- Changed in Lightroom since the index was built.
                    KeywordTree.forgetTopIndex()
                    keyword = KeywordTree.findTopLevel(catalog, entry.name)
                end
            else
                -- Looked up again rather than carried across gates: the check
                -- above only proved the name resolved then.
                local matches = KeywordTree.findByName(catalog, entry.name)
                if #matches == 1 then
                    keyword = matches[1].keyword
                end
            end
            if not keyword then
                error("Keyword not resolved: " .. entry.key)
            end
            -- "Summer" and "summer" resolve to one keyword.
            if not seenKeywords[keyword] then
                seenKeywords[keyword] = true
                table.insert(keywordObjs, keyword)
            end
        end

        for _, entry in ipairs(entries) do
            local photo = entry.photo
            for _, kwObj in ipairs(keywordObjs) do
                CatalogWrite.call(context, photo, "addKeyword", kwObj)
            end

            if next(removeNames) or hasRemovePaths then
                local existingKeywords = photo:getRawMetadata('keywords')
                if existingKeywords then
                    for _, kw in ipairs(existingKeywords) do
                        -- A plain name removes every keyword so named; a
                        -- path removes only the keyword at that place.
                        local byPath = hasRemovePaths
                            and removePaths[KeywordTree.fold(KeywordTree.pathOf(kw))]
                        if removeNames[kw:getName()] or byPath then
                            CatalogWrite.call(context, photo, "removeKeyword", kw)
                        end
                    end
                end
            end
        end
    end)

    keywordCallFailed = false
    Log.info(string.format("Updated keywords for %d photos", #entries))

    return Reply.parts({ data = { updated = #entries }, not_found = notFound })
end

function OrganizationHandler.removeKeywordSubtree(args, context)
    local catalog = LrApplication.activeCatalog()
    local parent = KeywordTree.resolve(catalog, KeywordTree.split(args.parent))
    if not parent then Reply.refuse("Keyword parent not found: " .. args.parent) end
    local keywords = { parent }
    local subtree = { [parent] = true }
    KeywordTree.walk(catalog, parent, function(keyword)
        keywords[#keywords + 1] = keyword
        subtree[keyword] = true
    end)

    local photos, notFound = {}, {}
    if args.catalog_wide == true then
        -- Keyword photo queries can yield: collect before opening either gate.
        local seen = {}
        for _, keyword in ipairs(keywords) do
            for _, photo in ipairs(keyword:getPhotos()) do
                if not seen[photo] then
                    seen[photo] = true
                    photos[#photos + 1] = photo
                end
            end
        end
    else
        local entries
        entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
        if #entries == 0 then return Reply.parts({ not_found = notFound }) end
        for i, entry in ipairs(entries) do photos[i] = entry.photo end
    end

    local updated, removed = 0, 0
    CatalogWrite.run(context, catalog, "Remove Keyword Subtree", function()
        for _, photo in ipairs(photos) do
            local changed = false
            for _, keyword in ipairs(photo:getRawMetadata('keywords') or {}) do
                if subtree[keyword] then
                    CatalogWrite.call(context, photo, "removeKeyword", keyword)
                    removed = removed + 1
                    changed = true
                end
            end
            if changed then updated = updated + 1 end
        end
    end)
    return Reply.parts({ data = { updated = updated, removed = removed }, not_found = notFound })
end

local PICK_STATUS = {}
for _, flag in ipairs(Contract.PHOTO_FLAGS) do PICK_STATUS[flag.name] = flag.pickStatus end

function OrganizationHandler.setRatingAndFlag(args, context)
    local hasRating = args.rating ~= nil
    local hasFlag = args.flag ~= nil
    local pickStatus = hasFlag and PICK_STATUS[args.flag] or nil

    -- LrSDK rejects literal 0 on the rating field; nil means "no rating".
    local ratingValue = args.rating
    if ratingValue == 0 then ratingValue = nil end

    return PhotoWrites.each(context, LrApplication.activeCatalog(), { photo_ids = args.photo_ids, title = "Set Rating and Flag", write = function(call)
        if hasRating then call('setRawMetadata', 'rating', ratingValue) end
        if hasFlag then call('setRawMetadata', 'pickStatus', pickStatus) end
    end })
end

function OrganizationHandler.setColorLabel(args, context)
    return PhotoWrites.each(context, LrApplication.activeCatalog(), { photo_ids = args.photo_ids, title = "Set Color Label", write = function(call)
        call('setRawMetadata', 'colorNameForLabel', args.label)
    end })
end

return OrganizationHandler
