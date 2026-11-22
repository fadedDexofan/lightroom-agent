local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"

local CatalogWrite = require "CatalogWrite"
local Contract = require "Contract"
local KeywordTree = require "KeywordTree"
local Reply = require "Reply"
local Log = require "Log"

local KeywordsHandler = {}

-- Lists the catalog's keyword hierarchy as a flat, paginated list of full
-- paths, so a client can pick existing keywords (set_keywords accepts the same
-- "Parent|Child" paths) instead of guessing names and creating duplicates.
-- A hierarchy can hold thousands of keywords, so `query` narrows the list to
-- keywords whose name or a synonym contains the text, and `paths_only` returns
-- bare path strings instead of one object per keyword.
function KeywordsHandler.listKeywords(args)
    local catalog = LrApplication.activeCatalog()

    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0

    local parentParts = nil
    if args.parent ~= nil then parentParts = KeywordTree.split(args.parent) end

    local query = nil
    if args.query ~= nil then query = KeywordTree.fold(args.query) end

    local pathsOnly = args.paths_only == true

    local function matches(name, synonyms)
        if not query then return true end
        if KeywordTree.fold(name):find(query, 1, true) then return true end
        for _, synonym in ipairs(synonyms) do
            if KeywordTree.fold(synonym):find(query, 1, true) then return true end
        end
        return false
    end

    local total = 0
    local slice = {}

    catalog:withReadAccessDo(function()
        local root = nil
        if parentParts then
            root = KeywordTree.resolve(catalog, parentParts)
            if not root then Reply.refuse("Keyword not found: " .. KeywordTree.join(parentParts)) end
        end

        KeywordTree.walk(catalog, root, function(keyword, path, attributes)
            local name = attributes.keywordName or keyword:getName()
            local synonyms = attributes.synonyms or {}
            if query and not matches(name, synonyms) then return end

            total = total + 1
            if total > offset and #slice < limit then
                if pathsOnly then
                    table.insert(slice, path)
                else
                    table.insert(slice, {
                        path = path,
                        name = name,
                        synonyms = synonyms,
                        include_on_export = attributes.includeOnExport,
                    })
                end
            end
        end)
    end)

    Log.info(string.format("Found %d keywords, returning %d (offset=%d, limit=%d)", total, #slice, offset, limit))

    return {
        count = total,
        keywords = slice,
        has_more = (offset + #slice) < total,
    }
end

-- Renames one keyword in place: every photo tagged with it shows the new name,
-- and its parent, children and synonyms are unchanged. A plain name must match
-- exactly one keyword; a "Parent|Child" path addresses it directly.
function KeywordsHandler.renameKeyword(args, context)
    -- Trimmed like a level of a path, so the keyword is found again by name.
    local newName = KeywordTree.trim(args.new_name)

    local parts = nil
    local oldName = nil
    if KeywordTree.isPath(args.keyword) then
        parts = KeywordTree.split(args.keyword)
    else
        oldName = KeywordTree.trim(args.keyword)
    end

    local catalog = LrApplication.activeCatalog()
    local keyword, oldPath, newPath, photoCount, tempName

    local function findKeyword()
        if parts then
            local resolved = KeywordTree.resolve(catalog, parts)
            if not resolved then Reply.refuse("Keyword not found: " .. KeywordTree.join(parts)) end
            return resolved
        end
        local matches = KeywordTree.findByName(catalog, oldName)
        if #matches == 0 then
            Reply.refuse("Keyword not found: " .. oldName)
        elseif #matches > 1 then
            local found = {}
            for _, match in ipairs(matches) do
                table.insert(found, match.path)
            end
            Reply.refuse("Keyword is ambiguous, give its path: " .. oldName .. " (" .. table.concat(found, ", ") .. ")")
        end
        return matches[1].keyword
    end

    catalog:withReadAccessDo(function() keyword = findKeyword() end)
    photoCount = #(keyword:getPhotos() or {})

    CatalogWrite.run(context, catalog, "Rename Keyword", function()
        keyword = findKeyword()

        local currentName = keyword:getName()
        if currentName == newName then Reply.refuse("Keyword is already named '" .. newName .. "'") end

        -- Lightroom matches names ignoring case, so a sibling "callie" would
        -- clash with "Callie"; the keyword itself does not.
        local parent = keyword:getParent()
        local clash = KeywordTree.findChild(catalog, parent, newName)
        if clash and clash ~= keyword then
            Reply.refuse(
                "A keyword named '"
                    .. clash:getName()
                    .. "' already exists at "
                    .. KeywordTree.pathOf(clash)
                    .. "; rename cannot merge keywords"
            )
        end

        oldPath = KeywordTree.pathOf(keyword)
        -- Built rather than read back: until this transaction commits,
        -- getName() still returns the old name.
        newPath = parent and (KeywordTree.pathOf(parent) .. KeywordTree.SEPARATOR .. newName) or newName
        -- Lightroom silently ignores a rename that changes only the case, so
        -- that goes through a temporary name, committed first.
        if KeywordTree.fold(currentName) == KeywordTree.fold(newName) then
            tempName = newName .. " (renaming)"
            local n = 1
            while KeywordTree.findChild(catalog, parent, tempName) do
                n = n + 1
                tempName = string.format("%s (renaming %d)", newName, n)
            end
            if not CatalogWrite.call(context, keyword, "setAttributes", { keywordName = tempName }) then
                error("Lightroom refused to rename keyword '" .. oldPath .. "' to '" .. tempName .. "'")
            end
        else
            if not CatalogWrite.call(context, keyword, "setAttributes", { keywordName = newName }) then
                error("Lightroom refused to rename keyword '" .. oldPath .. "' to '" .. newName .. "'")
            end
        end
    end)

    if tempName then
        -- LrTasks.pcall, not pcall: a write gate yields, and Lua 5.1's pcall
        -- cannot yield, so withWriteAccessDo fails inside it with "must be
        -- called from within an LrTask".
        local ok, err = LrTasks.pcall(function()
            CatalogWrite.run(context, catalog, "Rename Keyword", function()
                if not CatalogWrite.call(context, keyword, "setAttributes", { keywordName = newName }) then
                    error("Lightroom refused the final rename to '" .. newName .. "'")
                end
            end)
        end)
        if not ok then
            error(
                string.format(
                    "Keyword '%s' was left named '%s' while changing its case: %s",
                    oldPath,
                    tempName,
                    Reply.messageOf(err)
                )
            )
        end
    end

    Log.info(string.format("Renamed keyword %s to %s (%d photos)", oldPath, newPath, photoCount))

    return {
        old_path = oldPath,
        new_path = newPath,
        photo_count = photoCount,
    }
end

return KeywordsHandler
