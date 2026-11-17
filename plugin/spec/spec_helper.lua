-- Common test helpers + LR SDK mock factory.
-- Usage from a spec file:
--   local helper = require 'spec.spec_helper'
--   local catalog, photos = helper.mockCatalog({...})
--   helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
--   local Handler = require 'HandlerSearch'

local M = {}

-- Make plugin sources requireable.
local sep = package.config:sub(1, 1)
local pluginRoot = "plugin" .. sep .. "LightroomMCP.lrplugin" .. sep .. "?.lua"
if not package.path:find(pluginRoot, 1, true) then
    package.path = package.path .. ";" .. pluginRoot
end

-- Install a mock `import` global. Subsequent `import 'X'` calls return the mock for X.
-- Pure helper namespaces every spec gets unless it installs its own. lower is
-- ASCII-only here; Lightroom's folds Unicode.
local defaultImports = {
    LrStringUtils = { lower = string.lower },
    LrTasks = { pcall = pcall },
    LrDate = { currentTime = function() return 0 end },
    LrDevelopController = {},
    LrFileUtils = {},
    LrPathUtils = { parent = function(path) return path:match("^(.+)/[^/]+$") end },
    LrProgressScope = function()
        return {
            setCancelable = function() end, setPortionComplete = function() end, setCaption = function() end,
            isCanceled = function() return false end, done = function() end,
        }
    end,
}

function M.installImport(modules)
    package.loaded.CatalogWrite = nil
    _G.import = function(name)
        local m = modules[name]
        if m == nil then m = defaultImports[name] end
        if m == nil then
            error("No mock installed for import('" .. tostring(name) .. "')", 2)
        end
        return m
    end
end

local contexts = setmetatable({}, { __mode = "k" })

local function attempt(fn)
    local marks = {}
    for context in pairs(contexts) do marks[context] = context.ledger:mark() end
    local ok, err = pcall(fn)
    local written = {}
    for context in pairs(contexts) do
        for _, what in ipairs(context.ledger:since(marks[context] or 0)) do written[#written + 1] = what end
    end
    return ok, err, written
end

local function classOf(fn)
    local ok, err, written = attempt(fn)
    if ok then return "succeeded", err, written end
    local answer = require('Reply').outcome(false, err, {
        ledger = { live = function() return written end },
        warnings = {},
    })
    if answer.result then return "not found", err, written end
    return answer.effect == "none" and "failed" or "unknown", err, written
end

local function expected(wanted, class, err, written)
    local Reply = require('Reply')
    local detail = class == "succeeded" and "the call succeeded"
        or class == "not found" and "not found: " .. tostring(err)
        or #written > 0 and "the call wrote " .. table.concat(written, ", ") .. ": " .. Reply.messageOf(err)
        or "the call wrote nothing: " .. Reply.messageOf(err)
    error("expected " .. wanted .. ", but " .. detail, 3)
end

function M.failedOf(fn)
    local class, err, written = classOf(fn)
    if class ~= "failed" then expected("a failed outcome", class, err, written) end
    return require('Reply').messageOf(err)
end

function M.unknownOf(fn)
    local class, err, written = classOf(fn)
    if class ~= "unknown" then expected("an unknown outcome", class, err, written) end
    return require('Reply').messageOf(err)
end

function M.notFoundOf(fn)
    local class, err, written = classOf(fn)
    if class ~= "not found" then expected("not found", class, err, written) end
    return require('Reply').notFoundOf(err)
end

function M.catalogBusy(title)
    local aborting = { withWriteAccessDo = function() return "aborted" end }
    local _, err = pcall(require('CatalogWrite').run, { ledger = require('Ledger').new() }, aborting, title,
        function() end)
    return require('Reply').messageOf(err)
end

function M.outcomeOf(fn, context)
    context = context or M.requestContext()
    local ok, value = pcall(fn, context)
    local answer = require('Reply').outcome(ok, value, context)
    if answer.result then return "answered", answer.result end
    return answer.effect == "none" and "failed" or "unknown", answer.error
end

function M.admitMaskWrites(decision)
    package.loaded.MaskWriteAdmission = {
        requireAdmitted = function()
            if decision and decision.refuse then require('Reply').refuse(decision.refuse) end
        end,
    }
end

function M.requestContext(budgetSeconds, overrides)
    package.loaded.RequestContext = nil
    local RequestContext = require 'RequestContext'
    local context = RequestContext.new("test", (budgetSeconds or 3600) * 1000, nil)
    contexts[context] = true
    context.report = function() end
    for key, value in pairs(overrides or {}) do context[key] = value end
    return context
end

function M.withFixtureSlider(fn)
    local keys = require('Contract').LOCAL_KEYS
    keys[#keys + 1] = { name = "local_Fixture", stored = "LocalFixture", scale = 100 }
    package.loaded.LocalSliders = nil
    local ok, err = pcall(fn)
    keys[#keys] = nil
    package.loaded.LocalSliders = nil
    if not ok then error(err, 0) end
end

-- Default LrLogger stub used by every handler.
function M.defaultLrLogger()
    return setmetatable({}, {
        __call = function()
            return {
                info = function() end,
                warn = function() end,
                error = function() end,
                enable = function() end,
            }
        end,
    })
end

-- Valid Lightroom SDK metadata keys. The real getRawMetadata/getFormattedMetadata
-- THROW on an unsupported key, taking down the enclosing withReadAccessDo. The
-- non-validating mock used to return a value for any key, so a typo'd/invalid key
-- (e.g. `copyrightStatus` for `copyrightState`) shipped green. Validate against
-- this allowlist so specs catch it. Add genuinely-new SDK keys here.
local VALID_METADATA_KEYS = {}
for _, key in ipairs({
    -- File / catalog
    "fileName", "fileSize", "fileFormat", "path", "dimensions",
    "rating", "colorNameForLabel", "pickStatus", "keywords",
    "uuid", "isVirtualCopy", "isExported", "croppedDimensions", "dateTimeOriginalISO8601",
    "masterPhoto", "virtualCopies", "orientation",
    "isInStackInFolder", "stackInFolderIsCollapsed", "stackPositionInFolder",
    "topOfStackInFolderContainingPhoto", "stackInFolderMembers",
    -- EXIF
    "dateTimeOriginal", "dateTimeDigitized", "cameraMake", "cameraModel",
    "cameraSerialNumber", "lens", "isoSpeedRating", "focalLength",
    "focalLength35mm", "aperture", "shutterSpeed", "exposureBias",
    "exposureProgram", "meteringMode", "flash", "artist", "software",
    "gps", "gpsAltitude",
    -- IPTC content / location / rights
    "title", "caption", "headline", "location", "city", "stateProvince",
    "country", "isoCountryCode", "creator", "copyright", "copyrightState",
    "rightsUsageTerms", "copyrightInfoUrl", "creatorUrl",
    "altTextAccessibility", "extDescrAccessibility",
}) do
    VALID_METADATA_KEYS[key] = true
end

local FORMATTED_ONLY_METADATA_KEYS = { copyName = true }

local function readMetadata(meta, key)
    -- `__`-prefixed keys are test-internal sentinels (e.g. __appliedSettings)
    -- that specs read back to assert what a handler wrote; never SDK keys.
    if key:sub(1, 2) ~= "__" and not VALID_METADATA_KEYS[key] then
        error("unsupported metadata key '" .. tostring(key)
            .. "' (add it to spec_helper VALID_METADATA_KEYS if it is a real SDK key)", 2)
    end
    return meta[key]
end

local function readRawMetadata(meta, key)
    if FORMATTED_ONLY_METADATA_KEYS[key] then
        error("unsupported raw metadata key '" .. key .. "' (Lightroom reads it only through getFormattedMetadata)", 2)
    end
    return readMetadata(meta, key)
end

local function readFormattedMetadata(meta, key)
    if FORMATTED_ONLY_METADATA_KEYS[key] then return meta[key] end
    return readMetadata(meta, key)
end

local function copiedValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = copiedValue(inner) end
    return copy
end

-- Build a fake photo with the given metadata table.
-- meta keys correspond to keys passed to getRawMetadata / getFormattedMetadata / localIdentifier.
function M.fakePhoto(meta)
    if meta.uuid == nil and not meta.__dangling then
        meta.uuid = "uuid-" .. tostring(meta.localIdentifier or meta.id or "photo-id")
    end
    local photo = {
        localIdentifier = meta.localIdentifier or meta.id or "photo-id",
        getRawMetadata = function(_, key) return readRawMetadata(meta, key) end,
        getFormattedMetadata = function(_, key) return readFormattedMetadata(meta, key) end,
        getDevelopSettings = function() return meta.developSettings or {} end,
        addKeyword = function(_, kw)
            meta.__addedKeywords = meta.__addedKeywords or {}
            table.insert(meta.__addedKeywords, kw)
        end,
        removeKeyword = function(_, kw)
            meta.__removedKeywords = meta.__removedKeywords or {}
            table.insert(meta.__removedKeywords, kw)
        end,
        setRawMetadata = function(_, key, value) meta[key] = value end,
        applyDevelopPreset = function(_, preset, plugin)
            meta.__appliedPreset = preset
            meta.__appliedPresetPlugin = plugin
            meta.developSettings = meta.developSettings or {}
            for key, value in pairs(preset:getSetting()) do
                if key == "MaskGroupBasedCorrections" then
                    local masks = copiedValue(meta.developSettings.MaskGroupBasedCorrections) or {}
                    for _, entry in ipairs(value) do masks[#masks + 1] = copiedValue(entry) end
                    meta.developSettings.MaskGroupBasedCorrections = masks
                else
                    meta.developSettings[key] = copiedValue(value)
                end
            end
        end,
        applyDevelopSettings = function(_, settings, historyName, flattenAutoNow)
            meta.developSettings = meta.developSettings or {}
            for key, value in pairs(settings) do meta.developSettings[key] = value end
            meta.__appliedSettings = settings
            meta.__appliedHistoryName = historyName
            meta.__appliedFlattenAutoNow = flattenAutoNow
        end,
    }
    -- Opt in with aiUpdate = "ok" | "error" | "nothing" | "fail" | "mixed"; absent models LrC before 13.3.
    if meta.aiUpdate then
        photo.updateAISettings = function()
            meta.__aiUpdateCalls = (meta.__aiUpdateCalls or 0) + 1
            if meta.aiUpdate == "fail" then error("AI update failed") end
            if meta.aiUpdate == "mixed" then
                for _, correction in ipairs((meta.developSettings or {}).MaskGroupBasedCorrections or {}) do
                    local first = (correction.CorrectionMasks or {})[1]
                    if first and first.What == "Mask/Image" and first.MaskDigest == nil then first.ErrorReason = 1 end
                end
                return
            end
            if meta.aiUpdate ~= "ok" and meta.aiUpdate ~= "error" then return end
            for _, correction in ipairs((meta.developSettings or {}).MaskGroupBasedCorrections or {}) do
                for _, component in ipairs(correction.CorrectionMasks or {}) do
                    if component.What == "Mask/Image" and component.MaskDigest == nil then
                        component.MaskDigest = "digest-" .. tostring(photo.localIdentifier)
                        if meta.aiUpdate == "error" then component.ErrorReason = 1 end
                    end
                end
            end
        end
    end
    return photo
end

-- Build a fake keyword. opts: parent (fake keyword), synonyms, includeOnExport,
-- photos (what getPhotos returns).
-- Registers itself with its parent so getChildren() sees it, as a keyword that
-- already exists in the catalog would be.
function M.fakeKeyword(name, opts)
    opts = opts or {}
    local children = {}
    local kw = {
        getName = function() return name end,
        getParent = function() return opts.parent end,
        getChildren = function() return children end,
        getSynonyms = function() return opts.synonyms or {} end,
        getPhotos = function() return opts.photos or {} end,
        -- Only keywordName is modelled. Like Lightroom, a rename that changes
        -- only the case is ignored. Applied at once: the fake has no
        -- transactions to defer it to.
        setAttributes = function(_, attributes)
            local newName = attributes.keywordName
            if newName and newName:lower() ~= name:lower() then
                name = newName
            end
            return true
        end,
        getAttributes = function()
            return {
                keywordName = name,
                synonyms = opts.synonyms or {},
                includeOnExport = opts.includeOnExport ~= false,
            }
        end,
        __addChild = function(_, child) table.insert(children, child) end,
    }
    if opts.parent and not opts.detached then
        opts.parent:__addChild(kw)
    end
    return kw
end

-- Counts getName() calls on each of `keywords` (fake keywords), keyed by the
-- name it had when wrapped. Reading names is what makes keyword lookup slow on
-- a large catalog, so specs count it.
function M.countNameReads(keywords)
    local reads = {}
    for _, kw in ipairs(keywords) do
        local getName = kw.getName
        local name = getName(kw)
        reads[name] = 0
        kw.getName = function(self)
            reads[name] = reads[name] + 1
            return getName(self)
        end
    end
    return reads
end

function M.fakeFolder(path, photos, children)
    return {
        getPath = function() return path end,
        getName = function() return path:match("[^/]+$") end,
        getChildren = function() return children or {} end,
        getPhotos = function(_, includeChildren)
            local result = {}
            for _, photo in ipairs(photos or {}) do table.insert(result, photo) end
            if includeChildren then
                for _, child in ipairs(children or {}) do
                    for _, photo in ipairs(child:getPhotos(true)) do table.insert(result, photo) end
                end
            end
            return result
        end,
    }
end

-- Build a fake collection.
-- opts (optional): smart = true for a smart collection.
function M.fakeCollection(name, photos, opts)
    photos = photos or {}
    opts = opts or {}
    local addedPhotos = {}
    local removedPhotos = {}
    local deleted = false
    return {
        getName = function() return name end,
        isSmartCollection = function() return opts.smart == true end,
        getPhotos = function() return photos end,
        addPhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(addedPhotos, p)
                table.insert(photos, p)
            end
        end,
        removePhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(removedPhotos, p)
                for i = #photos, 1, -1 do
                    if photos[i] == p then table.remove(photos, i) end
                end
            end
        end,
        delete = function() deleted = true end,
        getAddedPhotos = function() return addedPhotos end,
        getRemovedPhotos = function() return removedPhotos end,
        isDeleted = function() return deleted end,
    }
end

-- Build a fake collection set. opts: parent (fake set), collections, sets.
-- Registers itself with its parent so getChildCollectionSets() sees it, as a
-- set that already exists in the catalog would be, unless detached.
function M.fakeCollectionSet(name, opts)
    opts = opts or {}
    local collections = opts.collections or {}
    local sets = opts.sets or {}
    local set = {}
    -- The catalog installs __readGuard on sets it creates, to model the SDK
    -- refusing reads in the transaction that created them.
    local function read(value)
        if set.__readGuard then set.__readGuard() end
        return value
    end
    set.getName = function() return read(name) end
    set.getParent = function() return read(opts.parent) end
    set.getChildCollections = function() return read(collections) end
    set.getChildCollectionSets = function() return read(sets) end
    -- Unguarded, for the fake catalog's own bookkeeping.
    set.__name = function() return name end
    set.__childCollections = function() return collections end
    set.__childSets = function() return sets end
    if opts.parent and not opts.detached then
        table.insert(opts.parent.__childSets(), set)
    end
    return set
end

local function removeValue(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then table.remove(list, i) end
    end
end

-- Build a fake catalog. opts:
--   photos: array of fake photos
--   collections: array of fake collections
--   collectionSets: array of fake collection sets
--   keywords: array of top-level fake keywords
function M.fakeCatalog(opts)
    opts = opts or {}
    local photos = opts.photos or {}
    local collections = opts.collections or {}
    local collectionSets = opts.collectionSets or {}
    local createdCollections = {}
    local createdCollectionSets = {}
    local createdKeywords = {}
    local topKeywords = opts.keywords or {}
    local pendingKeywords = {}
    local setsCreatedInWrite = {}
    local undoInWrite = {}
    local readAccessCount = 0
    local writeAccessCount = 0
    -- Tracks whether a catalog query (getTargetPhotos/findPhotos/getAllPhotos/
    -- findPhotoByPath) was invoked while a withReadAccessDo gate was open. The Windows deadlock
    -- (#134/#124) is exactly that nesting, so handlers must keep their query
    -- OUTSIDE the gate; specs assert getQueriedInsideReadAccess() == false.
    local insideReadAccess = false
    local queriedInsideReadAccess = false
    -- Same nesting, write side. withWriteAccessDo is an EXCLUSIVE gate, so a
    -- full-catalog scan held inside it serializes every other handler behind a
    -- scan that writes nothing. Handlers must resolve their photos BEFORE
    -- opening the gate; specs assert getQueriedInsideWriteAccess() == false.
    local insideWriteAccess = false
    local queriedInsideWriteAccess = false
    local selectionCall = nil
    -- How MANY catalog scans ran, not just where. A handler that can reject bad
    -- input before scanning should prove it never scanned.
    local queryCount = 0
    local function markQuery()
        queryCount = queryCount + 1
        if insideReadAccess then queriedInsideReadAccess = true end
        if insideWriteAccess then queriedInsideWriteAccess = true end
    end

    local function photoMatches(photo, criterion)
        local crit = criterion.criteria
        local op = criterion.operation
        if crit == "filename" and op == "any" then
            local name = photo:getFormattedMetadata('fileName')
            if not name then return false end
            return name:lower():find(criterion.value:lower(), 1, true) ~= nil
        elseif crit == "rating" and op == "==" then
            return photo:getRawMetadata('rating') == criterion.value
        elseif crit == "rating" and op == ">=" then
            local r = photo:getRawMetadata('rating')
            return r ~= nil and r >= criterion.value
        elseif crit == "keywords" and op == "all" then
            local kws = photo:getRawMetadata('keywords') or {}
            local target = criterion.value:lower()
            for _, kw in ipairs(kws) do
                if kw:getName():lower() == target then return true end
            end
            return false
        elseif (crit == "camera" or crit == "lens" or crit == "isoSpeedRating" or crit == "focalLength"
            or crit == "pick" or crit == "labelColor" or crit == "fileFormat") and op == "==" then
            local keys = { camera = "cameraModel", pick = "pickStatus", labelColor = "colorNameForLabel" }
            local value = photo:getRawMetadata(keys[crit] or crit)
            if crit == "labelColor" then
                local colors = { red = 1, yellow = 2, green = 3, blue = 4, purple = 5, none = "none" }
                value = colors[value or "none"]
            end
            return value == criterion.value
        elseif crit == "hasAdjustments" and (op == "isTrue" or op == "isFalse") then
            return (photo:getRawMetadata('__hasAdjustments') == true) == (op == "isTrue")
        elseif crit == "folder" and op == "all" then
            local folder = (photo:getRawMetadata('path') or ""):match("^(.*)/[^/]+$") or ""
            folder = folder:lower()
            for word in criterion.value:lower():gmatch("%S+") do
                if not folder:find(word, 1, true) then return false end
            end
            return true
        elseif crit == "captureTime" then
            local t = photo:getRawMetadata('dateTimeOriginal')
            if not t then return false end
            if op == "in" then
                return t >= criterion.value and t <= criterion.value2
            elseif op == ">" then
                return t > criterion.value
            elseif op == "<" then
                return t < criterion.value
            end
        end
        error("fakeCatalog.findPhotos: unsupported criterion " .. tostring(crit) .. "/" .. tostring(op))
    end

    return {
        getAllPhotos = function() markQuery() return photos end,
        getPhotoByLocalId = function(_, id)
            markQuery()
            for _, photo in ipairs(photos) do
                if tostring(photo.localIdentifier) == tostring(id) then return photo end
            end
            return M.fakePhoto({ id = id, __dangling = true })
        end,
        getTargetPhotos = function() markQuery() return opts.targetPhotos or photos end,
        findPhotoByPath = function(_, path, caseSensitive)
            markQuery()
            for _, photo in ipairs(photos) do
                local candidate = photo:getRawMetadata('path')
                if candidate == path or (caseSensitive == false and candidate:lower() == path:lower()) then
                    return photo
                end
            end
            return nil
        end,
        findPhotos = function(_, opts)
            markQuery()
            local desc = opts and opts.searchDesc or {}
            local out = {}
            for _, photo in ipairs(photos) do
                local ok = true
                for _, criterion in ipairs(desc) do
                    if not photoMatches(photo, criterion) then
                        ok = false
                        break
                    end
                end
                if ok then table.insert(out, photo) end
            end
            return out
        end,
        batchGetRawMetadata = function(_, list, keys)
            local out = {}
            for _, photo in ipairs(list) do
                local values = {}
                for _, key in ipairs(keys) do values[key] = photo:getRawMetadata(key) end
                out[photo] = values
            end
            return out
        end,
        batchGetFormattedMetadata = function(_, list, keys)
            local out = {}
            for _, photo in ipairs(list) do
                local values = {}
                for _, key in ipairs(keys) do values[key] = photo:getFormattedMetadata(key) end
                out[photo] = values
            end
            return out
        end,
        getFolders = function() return opts.folders or {} end,
        getFolderByPath = function(_, path)
            markQuery()
            local function find(list)
                for _, folder in ipairs(list) do
                    if folder:getPath() == path then return folder end
                    local found = find(folder:getChildren() or {})
                    if found then return found end
                end
                return nil
            end
            return find(opts.folders or {})
        end,
        getChildCollections = function() return collections end,
        getChildCollectionSets = function() return collectionSets end,
        withReadAccessDo = function(_, fn)
            readAccessCount = readAccessCount + 1
            insideReadAccess = true
            local ok, err = pcall(fn)
            insideReadAccess = false
            if not ok then error(err, 0) end
        end,
        getQueriedInsideReadAccess = function() return queriedInsideReadAccess end,
        -- For queries that live off the catalog (a smart collection's
        -- getPhotos) and so cannot call markQuery themselves.
        isInsideReadAccess = function() return insideReadAccess end,
        setSelectedPhotos = function(_, activePhoto, selected)
            markQuery()
            selectionCall = { active = activePhoto, photos = selected }
        end,
        getSelectionCall = function() return selectionCall end,
        withWriteAccessDo = function(_, actionName, fn, timeoutParams)
            if timeoutParams and opts.writeAccessAborts and opts.writeAccessAborts(actionName) then
                return "aborted"
            end
            writeAccessCount = writeAccessCount + 1
            insideWriteAccess = true
            pendingKeywords = {}
            setsCreatedInWrite = {}
            undoInWrite = {}
            local ok, err = pcall(fn)
            insideWriteAccess = false
            setsCreatedInWrite = {}
            -- Lightroom rolls back a failed transaction, including the
            -- collections and sets it created.
            local undo = undoInWrite
            undoInWrite = {}
            if not ok then
                for i = #undo, 1, -1 do undo[i]() end
            end
            -- Keywords created in the transaction become visible once it
            -- commits; a failed transaction leaves none behind.
            local pending = pendingKeywords
            pendingKeywords = {}
            if not ok then error(err, 0) end
            for _, kw in ipairs(pending) do
                createdKeywords[#createdKeywords + 1] = kw
                if kw:getParent() then
                    kw:getParent():__addChild(kw)
                else
                    table.insert(topKeywords, kw)
                end
            end
            return "executed"
        end,
        getQueriedInsideWriteAccess = function() return queriedInsideWriteAccess end,
        createCollection = function(_, name, parent, canReturnPrior)
            if not insideWriteAccess then
                error("createCollection outside withWriteAccessDo")
            end
            local siblings = parent and parent.__childCollections() or collections
            local siblingSets = parent and parent.__childSets() or collectionSets
            -- Live Lightroom: an exact duplicate returns nil (or the prior
            -- collection), a case-only variant raises, and a sibling set of
            -- the same name returns nil.
            for _, c in ipairs(siblings) do
                if c:getName() == name then
                    if canReturnPrior then return c end
                    return nil
                end
                if c:getName():lower() == name:lower() then
                    error("name is not unique: " .. name)
                end
            end
            for _, set in ipairs(siblingSets) do
                if set.__name():lower() == name:lower() then return nil end
            end
            local c = M.fakeCollection(name, {})
            table.insert(createdCollections, c)
            table.insert(siblings, c)
            table.insert(undoInWrite, function()
                removeValue(createdCollections, c)
                removeValue(siblings, c)
            end)
            return c
        end,
        createSmartCollection = function(self, name, searchDesc, parent, canReturnPrior)
            local collection = self:createCollection(name, parent, canReturnPrior)
            if collection then
                collection.isSmartCollection = function() return true end
                collection.getSearchDescription = function() return searchDesc end
                setsCreatedInWrite[collection] = true
                for _, method in ipairs({ "getName", "isSmartCollection", "getPhotos", "getSearchDescription" }) do
                    local original = collection[method]
                    collection[method] = function(...)
                        if setsCreatedInWrite[collection] then
                            error("Smart collection is unavailable until its write gate returns")
                        end
                        return original(...)
                    end
                end
            end
            return collection
        end,
        -- Models the SDK restriction the handler has to work around: a set
        -- created in a write transaction cannot be read (name, children) until
        -- that transaction ends; Lightroom raises the error below. It can still
        -- be passed as the parent of further sets in the same transaction.
        createCollectionSet = function(_, name, parent, canReturnPrior)
            if not insideWriteAccess then
                error("createCollectionSet outside withWriteAccessDo")
            end
            local siblings = parent and parent.__childSets() or collectionSets
            local siblingCollections = parent and parent.__childCollections() or collections
            -- Live Lightroom: a case-only variant of a sibling set raises, and
            -- a sibling collection of the same name returns nil.
            for _, set in ipairs(siblings) do
                local setName = set.__name()
                if setName == name then
                    if canReturnPrior then return set end
                    return nil
                end
                if setName:lower() == name:lower() then
                    error("name is not unique: " .. name)
                end
            end
            for _, c in ipairs(siblingCollections) do
                if c:getName():lower() == name:lower() then return nil end
            end
            local set = M.fakeCollectionSet(name, { parent = parent, detached = true })
            set.__readGuard = function()
                if setsCreatedInWrite[set] then
                    error("Can't get collection information after creating collection"
                        .. " inside the same withWriteAccessDo function")
                end
            end
            setsCreatedInWrite[set] = true
            table.insert(createdCollectionSets, set)
            table.insert(siblings, set)
            table.insert(undoInWrite, function()
                removeValue(createdCollectionSets, set)
                removeValue(siblings, set)
            end)
            return set
        end,
        getKeywords = function() return topKeywords end,
        -- Models the SDK behaviour the handlers have to work around: a keyword
        -- created in a write transaction is invisible to getKeywords() and
        -- getChildren() until it commits, cannot be used as a parent before
        -- then, and creating the same name twice in one transaction asserts.
        -- returnExisting matches committed keywords ignoring case.
        createKeyword = function(_, name, synonyms, includeOnExport, parent, returnExisting)
            if not insideWriteAccess then
                error("createKeyword outside withWriteAccessDo")
            end
            for _, kw in ipairs(pendingKeywords) do
                if kw == parent then
                    error("bad argument #2 to 'format' (number expected, got string)")
                end
                if kw:getParent() == parent and kw:getName():lower() == name:lower() then
                    error("createKeyword: " .. name .. " already created in this transaction")
                end
            end
            if returnExisting then
                local siblings = parent and parent:getChildren() or topKeywords
                for _, kw in ipairs(siblings) do
                    if kw:getName():lower() == name:lower() then return kw end
                end
            end
            local kw = M.fakeKeyword(name, {
                parent = parent,
                synonyms = synonyms,
                includeOnExport = includeOnExport,
                detached = true,
            })
            table.insert(pendingKeywords, kw)
            return kw
        end,
        addPhoto = function(_, path)
            local p = M.fakePhoto({ path = path, id = path })
            table.insert(photos, p)
            return p
        end,
        getCreatedCollections = function() return createdCollections end,
        getCreatedCollectionSets = function() return createdCollectionSets end,
        getCreatedKeywords = function() return createdKeywords end,
        getReadAccessCount = function() return readAccessCount end,
        getWriteAccessCount = function() return writeAccessCount end,
        getQueryCount = function() return queryCount end,
    }
end

function M.fakeRenditions(session)
    local photos = session.photosToExport or {}
    local index = 0
    return function()
        index = index + 1
        if not photos[index] then return nil end
        local path = tostring(session.exportSettings.LR_export_destinationPathPrefix) .. "/" .. tostring(index)
        return index, {
            destinationPath = path,
            waitForRender = function() return true, path end,
        }
    end
end

local function loadPrivateJson()
    local file = assert(package.searchpath("JSON", package.path))
    return assert(loadfile(file))()
end

local privateJson = loadPrivateJson()
local plainRequire = require

local function dispatchedHandlers()
    local contract = assert(loadfile(assert(package.searchpath("Contract", package.path))))()
    local handlers = {}
    for action, target in pairs(contract.DISPATCH) do
        handlers[target[1]] = handlers[target[1]] or {}
        handlers[target[1]][target[2]] = action
    end
    return handlers
end

local DISPATCHED = dispatchedHandlers()

local function encodingResults(module, name)
    local wrapped = {}
    for key, value in pairs(module) do
        if type(value) == "function" and DISPATCHED[name][key] then
            local action = DISPATCHED[name][key]
            wrapped[key] = function(args, context, ...)
                local results = table.pack(value(args, context or M.requestContext(nil, { title = action }), ...))
                if type(results[1]) == "table" then
                    local ok, err = pcall(function() return privateJson:encode(results[1]) end)
                    if not ok then
                        error(string.format("%s.%s returned a result JSON cannot encode: %s", name, tostring(key),
                            tostring(err)), 0)
                    end
                end
                return table.unpack(results, 1, results.n)
            end
        else
            wrapped[key] = value
        end
    end
    return setmetatable(wrapped, { __index = module, __newindex = module })
end

function require(name)
    local fromDisk = package.loaded[name] == nil
    local module = plainRequire(name)
    if fromDisk and type(name) == "string" and DISPATCHED[name] and type(module) == "table"
        and getmetatable(module) == nil then
        local wrapped = encodingResults(module, name)
        package.loaded[name] = wrapped
        return wrapped
    end
    return module
end

return M
