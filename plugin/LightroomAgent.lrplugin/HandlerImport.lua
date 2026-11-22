local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

local CatalogFolders = require "CatalogFolders"
local CatalogWrite = require "CatalogWrite"
local CollectionsHandler = require "HandlerCollections"
local Log = require "Log"
local PathForms = require "PathForms"
local PhotoLookup = require "PhotoLookup"
local Reply = require "Reply"

local ImportHandler = {}

local JPEG_SIDECAR_RAW_EXTENSIONS = {}
local IMPORTABLE_EXTENSIONS = {}
for ext in
    ([[
    3fr ari arw bay cap cr2 cr3 crw dcr dcs drf eip erf fff gpr iiq k25 kdc mdc mef mos mrw
    nef nrw orf ori pef ptx pxn raf raw rw2 rwl sr2 srf srw x3f
]]):gmatch("%S+")
do
    JPEG_SIDECAR_RAW_EXTENSIONS[ext] = true
    IMPORTABLE_EXTENSIONS[ext] = true
end
for ext in
    ([[
    dng avif heic heif hif jpe jpeg jpg jxl png psb psd tif tiff
]]):gmatch("%S+")
do
    IMPORTABLE_EXTENSIONS[ext] = true
end

local JPEG_EXTENSIONS = { jpe = true, jpeg = true, jpg = true }
local PACKAGE_EXTENSIONS = { lrdata = true, lrlibrary = true, photoslibrary = true }

local function lowerExtension(path) return LrPathUtils.extension(path):lower() end

local function withoutSidecarJpegs(files)
    local rawStems = {}
    for _, file in ipairs(files) do
        if JPEG_SIDECAR_RAW_EXTENSIONS[lowerExtension(file)] then rawStems[LrPathUtils.removeExtension(file)] = true end
    end
    local kept = {}
    local sidecars = {}
    for _, file in ipairs(files) do
        if JPEG_EXTENSIONS[lowerExtension(file)] and rawStems[LrPathUtils.removeExtension(file)] then
            sidecars[#sidecars + 1] = file
        else
            kept[#kept + 1] = file
        end
    end
    return kept, sidecars
end

local function insidePackage(file)
    for folder in file:gmatch("([^/\\]+)[/\\]") do
        local extension = folder:match("%.([^.]+)$")
        if extension and PACKAGE_EXTENSIONS[extension:lower()] then return true end
    end
    return false
end

local function sameContent(left, right)
    local leftSize = LrFileUtils.fileAttributes(left).fileSize
    if leftSize == nil or leftSize ~= LrFileUtils.fileAttributes(right).fileSize then return false end
    local content = LrFileUtils.readFile(left)
    return content ~= nil and content == LrFileUtils.readFile(right)
end

local function copiedTarget(context, source, relativePath, folder, companions)
    local target = LrPathUtils.child(folder, relativePath)
    CatalogWrite.createFolder(context, LrPathUtils.parent(target))
    if not (LrFileUtils.exists(target) == "file" and sameContent(source, target)) then
        if LrFileUtils.exists(target) then target = LrFileUtils.chooseUniqueFileName(target) end
        CatalogWrite.copyFile(context, source, target)
    end
    local targetStem = LrPathUtils.removeExtension(target)
    for _, companion in ipairs(companions) do
        local companionTarget = targetStem .. "." .. LrPathUtils.extension(companion)
        if not LrFileUtils.exists(companionTarget) then CatalogWrite.copyFile(context, companion, companionTarget) end
    end
    return target
end

local function firstExistingBeside(stem, extensions)
    for _, extension in ipairs(extensions) do
        if LrFileUtils.exists(stem .. "." .. extension) == "file" then return stem .. "." .. extension end
    end
    return nil
end

local function companionsBeside(source, separateJpegs)
    local companions = {}
    local stem = LrPathUtils.removeExtension(source)
    companions[#companions + 1] = firstExistingBeside(stem, { "xmp", "XMP" })
    if not separateJpegs and JPEG_SIDECAR_RAW_EXTENSIONS[lowerExtension(source)] then
        companions[#companions + 1] = firstExistingBeside(stem, { "jpg", "JPG", "jpeg", "JPEG" })
    end
    return companions
end

local function nameKey(name) return PathForms.isAscii(name) and name or PathForms.toNfd(name) end

-- The name the directory lists for `path`'s leaf: the exact bytes if present,
-- else the same name in another Unicode form (the volume ignores the form),
-- else one that differs in case too. Returns nil when the listing has none.
local function leafSpelledOnDisk(path, entries)
    local leaf = LrPathUtils.leafName(path)
    local key = nameKey(leaf)
    local sameName, foldedName = nil, nil
    for _, entry in ipairs(entries) do
        local entryLeaf = LrPathUtils.leafName(entry)
        if entryLeaf == leaf then return leaf end
        local entryKey = nameKey(entryLeaf)
        if entryKey == key then
            sameName = entryLeaf
        elseif entryKey:lower() == key:lower() then
            foldedName = entryLeaf
        end
    end
    return sameName or foldedName
end

local function rawFileProbedBeside(path, entries)
    local stem = LrPathUtils.removeExtension(path)
    local probedExtensions = {}
    for _, entry in ipairs(entries) do
        local ext = LrPathUtils.extension(entry)
        if JPEG_SIDECAR_RAW_EXTENSIONS[ext:lower()] and not probedExtensions[ext] then
            probedExtensions[ext] = true
            local candidate = stem .. "." .. ext
            if LrFileUtils.exists(candidate) == "file" then return candidate end
        end
    end
    return nil
end

local function rawFileBeside(path)
    local entries = {}
    for entry in LrFileUtils.directoryEntries(LrPathUtils.parent(path)) do
        entries[#entries + 1] = entry
    end
    local leafOnDisk = leafSpelledOnDisk(path, entries)
    if not leafOnDisk then return rawFileProbedBeside(path, entries) end
    local stem = nameKey(LrPathUtils.removeExtension(leafOnDisk))
    for _, entry in ipairs(entries) do
        if
            JPEG_SIDECAR_RAW_EXTENSIONS[lowerExtension(entry)]
            and nameKey(LrPathUtils.leafName(LrPathUtils.removeExtension(entry))) == stem
            and LrFileUtils.exists(entry) == "file"
        then
            return entry
        end
    end
    return nil
end

local function distinctOnDisk(existing, folder)
    if not LrFileUtils.exists(folder) then return LrFileUtils.exists(existing) == "directory" end
    local parent = LrPathUtils.parent(existing)
    if not parent or not PathForms.same(parent, LrPathUtils.parent(folder) or "") then return false end
    local first, second = nameKey(LrPathUtils.leafName(existing)), nameKey(LrPathUtils.leafName(folder))
    local seenFirst, seenSecond = false, false
    for entry in LrFileUtils.directoryEntries(parent) do
        local leaf = nameKey(LrPathUtils.leafName(entry))
        seenFirst = seenFirst or leaf == first
        seenSecond = seenSecond or leaf == second
        if seenFirst and seenSecond then return true end
    end
    return false
end

local function eachAncestor(directory)
    local current = directory
    return function()
        local this = current
        if not this or this == "" then return nil end
        local parent = LrPathUtils.parent(this)
        current = parent ~= this and parent or nil
        return this
    end
end

-- Lightroom files a photo under an existing folder that differs only in case,
-- so on a case-sensitive volume a file in dir2 lands in Dir2 as a duplicate
-- record of its own path, and a later import of the folder never answers (#473).
-- Returns the folder spelled differently on disk from `directory`, or nil and
-- the folders of `directory` to remember once its file is in the catalog.
local function caseVariantFolder(known, directory)
    local fresh = {}
    for folder in eachAncestor(directory) do
        local spellings = CatalogFolders.spellingsOf(known, folder)
        if spellings then
            local own = false
            for _, spelling in ipairs(spellings) do
                own = own or PathForms.same(spelling, folder)
            end
            if not own then
                for _, spelling in ipairs(spellings) do
                    if distinctOnDisk(spelling, folder) then return spelling end
                end
            end
        end
        fresh[#fresh + 1] = folder
    end
    return nil, fresh
end

-- findPhotoByPath ignores case even when asked not to, so on a case-sensitive
-- volume a.jpg beside the catalog's A.jpg found A.jpg and was counted as
-- already imported (#470). A hit whose path differs from the requested one is
-- the same file only when the parent folder lists a single spelling. When it
-- lists both they are two files, and Lightroom cannot hold both: its file
-- table ignores case, and addPhoto fails with "failed to import photo" (live
-- check on 15.6), so the second is refused here before addPhoto is called.
-- `beforeCopy` is for a copy_to target that does not exist yet: the catalog
-- file exists and the target does not, so the volume tells them apart.
-- Returns the photo already in the catalog, or nil and the path it clashes with.
local function catalogPhotoAt(catalog, path, beforeCopy)
    local found = PhotoLookup.findByPath(catalog, path, false)
    if not found then return nil end
    local foundPath = found:getRawMetadata("path")
    if foundPath == nil or PathForms.same(foundPath, path) then return found end
    local separate
    if beforeCopy then
        separate = LrFileUtils.exists(foundPath) == "file" and not LrFileUtils.exists(path)
    else
        separate = distinctOnDisk(foundPath, path)
    end
    if not separate then return found end
    -- The catalog may hold this spelling too (imported before this check).
    local folder = catalog:getFolderByPath(LrPathUtils.parent(path))
    for _, photo in ipairs(folder and folder:getPhotos(false) or {}) do
        local candidate = photo:getRawMetadata("path")
        if candidate ~= nil and PathForms.same(candidate, path) then return photo end
    end
    return nil, foundPath
end

local function refuseCaseVariantFile(path, clash)
    error(
        string.format(
            "%s: differs only in case from %s, which is in the catalog; "
                .. "Lightroom keeps file names case-insensitively and cannot hold both",
            path,
            clash
        ),
        0
    )
end

local function describeSkipped(skipped)
    local names = {}
    for ext in pairs(skipped) do
        names[#names + 1] = ext
    end
    table.sort(names)
    local parts = {}
    for _, ext in ipairs(names) do
        parts[#parts + 1] = string.format("%s: %d", ext == "" and "(none)" or ext, skipped[ext])
    end
    return table.concat(parts, ", ")
end

local IMPORT_PHOTO_RESERVE_SECONDS = 60

local function prepareImport(args, catalog)
    args.source_path = PathForms.absolute(args.source_path, "source_path")
    if args.copy_to then args.copy_to = PathForms.absolute(args.copy_to, "copy_to") end
    -- LrFileUtils.exists returns 'file' / 'directory' / false. Use it for the
    -- directory check too: LrFileUtils.isDirectory is absent on some Lightroom
    -- Classic runtimes (nil there, e.g. 15.3.1 -- issue #129), whereas exists
    -- is stable across supported versions.
    local sourceKind = LrFileUtils.exists(args.source_path)
    if not sourceKind then error("Source path does not exist: " .. args.source_path) end

    -- Enumerate source files OUTSIDE any catalog lock; the filesystem walk
    -- needs no catalog access.
    local photosToImport = {}
    local skippedByExtension = {}
    local skippedCount = 0
    local sidecarJpegCount = 0
    local packageFileCount = 0
    local companionsOf = {}
    local function addCompanion(file)
        local stem = LrPathUtils.removeExtension(file)
        companionsOf[stem] = companionsOf[stem] or {}
        table.insert(companionsOf[stem], file)
    end
    if sourceKind == "directory" then
        -- Import all photos from directory, including nested subfolders.
        -- LrFileUtils.files lists only the immediate directory.
        for file in LrFileUtils.recursiveFiles(args.source_path) do
            local ext = lowerExtension(file)
            if insidePackage(file) then
                packageFileCount = packageFileCount + 1
            elseif IMPORTABLE_EXTENSIONS[ext] then
                table.insert(photosToImport, file)
            else
                if ext == "xmp" then addCompanion(file) end
                skippedByExtension[ext] = (skippedByExtension[ext] or 0) + 1
                skippedCount = skippedCount + 1
            end
        end
        if not args.separate_jpegs then
            local sidecars
            photosToImport, sidecars = withoutSidecarJpegs(photosToImport)
            sidecarJpegCount = #sidecars
            for _, sidecar in ipairs(sidecars) do
                addCompanion(sidecar)
            end
        end
    else
        -- Import single photo
        if not args.separate_jpegs and JPEG_EXTENSIONS[lowerExtension(args.source_path)] then
            local rawFile = rawFileBeside(args.source_path)
            if rawFile then
                error(
                    string.format(
                        "%s has a raw file of the same name. Import %s instead; Lightroom keeps the JPEG as its sidecar. "
                            .. "To add the JPEG as a separate photo, set separate_jpegs to true.",
                        args.source_path,
                        rawFile
                    )
                )
            end
        end
        table.insert(photosToImport, args.source_path)
    end

    if #photosToImport == 0 then
        if packageFileCount > 0 then
            error("No photos found to import; files inside Lightroom or Photos library packages are not imported")
        end
        if skippedCount > 0 then
            error("No photos found to import; skipped files by extension: " .. describeSkipped(skippedByExtension))
        end
        error("No photos found to import")
    end

    local function requireTargetCollection()
        return CollectionsHandler.findOneRegularCollection(catalog, args.collection_name)
    end
    if args.collection_name then catalog:withReadAccessDo(requireTargetCollection) end
    return {
        sourceKind = sourceKind,
        photosToImport = photosToImport,
        companionsOf = companionsOf,
        requireTargetCollection = requireTargetCollection,
        skippedByExtension = skippedByExtension,
        skippedCount = skippedCount,
        sidecarJpegCount = sidecarJpegCount,
        packageFileCount = packageFileCount,
    }
end

function ImportHandler.importPhotos(args, context)
    local catalog = LrApplication.activeCatalog()
    local prepared, plan = LrTasks.pcall(prepareImport, args, catalog)
    if not prepared then Reply.refuse(Reply.messageOf(plan)) end
    local sourceKind, photosToImport, companionsOf = plan.sourceKind, plan.photosToImport, plan.companionsOf
    local requireTargetCollection = plan.requireTargetCollection
    local importedCount = 0

    -- Add each photo in its OWN write transaction rather than holding the
    -- exclusive catalog write lock across the whole batch. A large import
    -- runs for minutes, and one batch-wide withWriteAccessDo would block
    -- every other handler (reads included) for that entire span.
    -- addPhoto cannot acquire its own isolated access the way
    -- LrExportSession does, so a per-photo lock is the bounded-hold
    -- equivalent: the lock is released between photos, letting queued
    -- handlers interleave.
    local collectionPhotos = {}
    local failed, unknown = {}, {}
    local remaining = {}
    local alreadyInCatalogCount = 0
    local processed = 0
    local knownFolders = nil
    local function refuseCaseVariantFolder(path)
        knownFolders = knownFolders or CatalogFolders.of(catalog)
        local directory = LrPathUtils.parent(path)
        local other, fresh = caseVariantFolder(knownFolders, directory)
        if other then
            error(
                string.format(
                    "%s: folder %s differs only in case from %s, which is in the catalog or earlier in this import; "
                        .. "Lightroom would file the photo under %s",
                    path,
                    directory,
                    other,
                    other
                ),
                0
            )
        end
        return function()
            for _, folder in ipairs(fresh) do
                CatalogFolders.remember(knownFolders, folder)
            end
        end
    end
    for index, filePath in ipairs(photosToImport) do
        if context:stopping(IMPORT_PHOTO_RESERVE_SECONDS) then
            for nextIndex = index, #photosToImport do
                remaining[#remaining + 1] = photosToImport[nextIndex]
            end
            break
        end
        context:report(processed, #photosToImport, filePath)
        local imported, importError, written = context.ledger:attempt(function()
            local photoPath = filePath
            local rememberFolders
            if args.copy_to then
                local relativePath = sourceKind == "directory" and PathForms.relative(args.source_path, filePath)
                    or LrPathUtils.leafName(filePath)
                local companions = companionsOf[LrPathUtils.removeExtension(filePath)]
                    or (sourceKind ~= "directory" and companionsBeside(filePath, args.separate_jpegs))
                    or {}
                local target = LrPathUtils.child(args.copy_to, relativePath)
                rememberFolders = refuseCaseVariantFolder(target)
                local _, targetClash = catalogPhotoAt(catalog, target, true)
                if targetClash then refuseCaseVariantFile(target, targetClash) end
                photoPath = copiedTarget(context, filePath, relativePath, args.copy_to, companions)
            else
                rememberFolders = refuseCaseVariantFolder(photoPath)
            end
            local existing, clash = catalogPhotoAt(catalog, photoPath)
            if clash then refuseCaseVariantFile(photoPath, clash) end
            if existing then
                table.insert(collectionPhotos, existing)
                alreadyInCatalogCount = alreadyInCatalogCount + 1
                rememberFolders()
                return
            end
            local beforeImport = context.ledger:mark()
            local added, addError = LrTasks.pcall(CatalogWrite.run, context, catalog, "Import Photo", function()
                local photo = CatalogWrite.call(context, catalog, "addPhoto", photoPath)
                if not photo then error("Lightroom did not add the photo") end
                table.insert(collectionPhotos, photo)
                importedCount = importedCount + 1
            end)
            if not added then
                if catalogPhotoAt(catalog, photoPath) == nil then context.ledger:undone(beforeImport) end
                error(addError, 0)
            end
            rememberFolders()
        end)
        if not imported then
            if sourceKind ~= "directory" then error(filePath .. ": " .. Reply.messageOf(importError), 0) end
            local class, reason = Reply.stopped(importError, written)
            local list = class == "failed" and failed or unknown
            list[#list + 1] = { path = filePath, reason = reason }
        end
        processed = processed + 1
    end
    if processed > 0 then context:report(processed, #photosToImport, photosToImport[processed]) end

    -- Add to collection if specified, in its own short write transaction.
    local addedToCollection = 0
    local problem
    if args.collection_name and #collectionPhotos > 0 then
        local ok, outcome = LrTasks.pcall(
            CatalogWrite.run,
            context,
            catalog,
            "Add Imported Photos to Collection",
            function() CatalogWrite.call(context, requireTargetCollection(), "addPhotos", collectionPhotos) end
        )
        if not ok then
            problem = "the photos were not added to collection "
                .. args.collection_name
                .. ": "
                .. Reply.messageOf(outcome)
        else
            addedToCollection = #collectionPhotos
            Log.info(string.format("Added %d photos to collection: %s", addedToCollection, args.collection_name))
        end
    end

    Log.info(
        string.format(
            "Imported %d photos from: %s (skipped %d, sidecar JPEGs %d, already in catalog %d)",
            importedCount,
            args.source_path,
            plan.skippedCount,
            plan.sidecarJpegCount,
            alreadyInCatalogCount
        )
    )

    return Reply.parts({
        data = (importedCount > 0 or alreadyInCatalogCount > 0) and {
            imported = importedCount,
            already_in_catalog = alreadyInCatalogCount > 0 and alreadyInCatalogCount or nil,
            added_to_collection = args.collection_name and addedToCollection or nil,
            skipped_package_files = plan.packageFileCount > 0 and plan.packageFileCount or nil,
            skipped_by_extension = plan.skippedCount > 0 and plan.skippedByExtension or nil,
            skipped_sidecar_jpegs = plan.sidecarJpegCount > 0 and plan.sidecarJpegCount or nil,
        } or nil,
        failed = #failed > 0 and failed or nil,
        unknown = #unknown > 0 and unknown or nil,
        remaining = #remaining > 0 and remaining or nil,
        problem = problem,
    })
end

return ImportHandler
