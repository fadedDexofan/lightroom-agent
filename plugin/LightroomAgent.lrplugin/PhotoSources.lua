local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local PhotoSources = {}

local function folderList(catalog, photos)
    local raw = catalog:batchGetRawMetadata(photos, { "path" }) or {}
    local folders, seen = {}, {}
    for _, photo in ipairs(photos) do
        local path = (raw[photo] or {}).path
        local parent = type(path) == "string" and LrPathUtils.parent(path) or nil
        if not parent then return nil end
        if not seen[parent] then
            if LrFileUtils.exists(parent) ~= "directory" then return nil end
            local folder = catalog:getFolderByPath(parent)
            if not folder then return nil end
            seen[parent] = true
            folders[#folders + 1] = folder
        end
    end
    return folders
end

function PhotoSources.foldersOf(catalog, photos)
    local ok, folders = LrTasks.pcall(folderList, catalog, photos)
    return ok and folders or nil
end

function PhotoSources.show(catalog, sources)
    local ok, changed = LrTasks.pcall(function() return catalog:setActiveSources(sources) end)
    return ok and changed ~= false
end

return PhotoSources
