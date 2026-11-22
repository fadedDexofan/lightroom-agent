local LrStringUtils = import "LrStringUtils"

local PathForms = require "PathForms"

local CatalogFolders = {}

function CatalogFolders.foldedPath(path) return LrStringUtils.lower(PathForms.toNfc(path)) end

local function withoutTrailingSeparator(path) return (path:gsub("[/\\]+$", "")) end

function CatalogFolders.remember(known, path)
    path = withoutTrailingSeparator(path)
    if path == "" then return end
    local key = CatalogFolders.foldedPath(path)
    known[key] = known[key] or {}
    for _, spelling in ipairs(known[key]) do
        if PathForms.same(spelling, path) then return end
    end
    table.insert(known[key], path)
end

function CatalogFolders.of(catalog)
    local known = {}
    local function visit(folder)
        CatalogFolders.remember(known, folder:getPath())
        for _, child in ipairs(folder:getChildren() or {}) do
            visit(child)
        end
    end
    for _, folder in ipairs(catalog:getFolders() or {}) do
        visit(folder)
    end
    return known
end

function CatalogFolders.spellingsOf(known, path) return known[CatalogFolders.foldedPath(withoutTrailingSeparator(path))] end

return CatalogFolders
