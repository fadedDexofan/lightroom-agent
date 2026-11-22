local PathForms = require "PathForms"
local Reply = require "Reply"

local PhotoLookup = {}

function PhotoLookup.findByPath(catalog, path, caseSensitive)
    local photo = catalog:findPhotoByPath(path, caseSensitive)
    if photo or PathForms.isAscii(path) then return photo end
    local nfd = PathForms.toNfd(path)
    if nfd ~= path then
        photo = catalog:findPhotoByPath(nfd, caseSensitive)
        if photo then return photo end
    end
    local nfc = PathForms.toNfc(path)
    if nfc ~= path then return catalog:findPhotoByPath(nfc, caseSensitive) end
    return nil
end

local function localIdOf(id)
    if type(id) == "number" then return id end
    if type(id) == "string" and id:match("^[1-9]%d*$") then return tonumber(id) end
    return nil
end

-- Resolve a list of photo identifiers to photo objects.
-- Each id is a canonical local identifier (integer, or a string of digits
-- without a leading zero) or an absolute file path; the server's schema admits
-- nothing else. Returns a parallel array:
--   results[i] = { id = inputId, photo = photoOrNil }
--
-- findPhotoByPath is a catalog query, so like findPhotos it must not run inside
-- withReadAccessDo or withWriteAccessDo; callers resolve first.
--
-- Paths are not unique: a virtual copy reports its master's source path, so a
-- path names a master and all its virtual copies. A path always resolves to
-- the master; a virtual copy is addressed by its local id.
function PhotoLookup.resolveMany(catalog, photoIds)
    local results = {}
    local byLocalId, byPath = {}, {}
    local unverified, keyOf = {}, {}

    for i, id in ipairs(photoIds) do
        results[i] = { id = id, photo = nil }
        local localId = localIdOf(id)
        if localId then
            local key = tostring(localId)
            if byLocalId[key] == nil then
                byLocalId[key] = false
                local photo = catalog:getPhotoByLocalId(localId)
                if photo then
                    unverified[#unverified + 1] = photo
                    keyOf[photo] = key
                end
            end
        elseif byPath[id] == nil then
            byPath[id] = false
            local photo = PhotoLookup.findByPath(catalog, id)
            if photo and PathForms.same(photo:getRawMetadata("path"), id) then
                byPath[id] = photo:getRawMetadata("masterPhoto") or photo
            end
        end
    end

    if #unverified > 0 then
        local raw = catalog:batchGetRawMetadata(unverified, { "uuid" }) or {}
        for _, photo in ipairs(unverified) do
            if (raw[photo] or {}).uuid ~= nil then byLocalId[keyOf[photo]] = photo end
        end
    end

    for i, id in ipairs(photoIds) do
        local localId = localIdOf(id)
        if localId then
            results[i].photo = byLocalId[tostring(localId)] or nil
        else
            results[i].photo = byPath[id] or nil
        end
    end

    return results
end

function PhotoLookup.resolveDistinct(catalog, photoIds)
    local resolved = PhotoLookup.resolveMany(catalog, photoIds)
    local entries, notFound, seen, missed = {}, {}, {}, {}
    for _, entry in ipairs(resolved) do
        if not entry.photo then
            if not missed[tostring(entry.id)] then
                missed[tostring(entry.id)] = true
                notFound[#notFound + 1] = entry.id
            end
        elseif not seen[entry.photo] then
            seen[entry.photo] = true
            entries[#entries + 1] = entry
        end
    end
    return entries, notFound, resolved
end

function PhotoLookup.resolveOne(catalog, photoId) return PhotoLookup.resolveMany(catalog, { photoId })[1].photo end

function PhotoLookup.requireOne(catalog, photoId)
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then Reply.notFound(photoId) end
    return photo
end

return PhotoLookup
