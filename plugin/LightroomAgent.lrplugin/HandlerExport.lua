local LrApplication = import "LrApplication"
local LrDate = import "LrDate"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local CatalogWrite = require "CatalogWrite"
local Contract = require "Contract"
local JSON = require "JSON"
local CatalogFolders = require "CatalogFolders"
local PathForms = require "PathForms"
local PhotoLookup = require "PhotoLookup"
local Log = require "Log"
local ExportPresets = require "ExportPresets"
local PhotoRecord = require "PhotoRecord"
local Reply = require "Reply"

local ExportHandler = {}

-- Lightroom's default collision handling is "ask", which opens a modal
-- ("The following files already exist") and blocks the export task until a
-- human clicks. Over the bridge that hangs the request until the server
-- timeout and queues every later request behind it, so re-exporting the same
-- photo to the same folder wedged the plugin. Never prompt.
local COLLISION_HANDLING = {
    rename = "rename",
    overwrite = "overwrite",
    skip = "skip",
}
local DEFAULT_COLLISION_HANDLING = "rename"
local DEFAULT_JPEG_QUALITY = 90
-- Lightroom's largest exported edge; leaves an edge nobody limited unconstrained.
local MAX_EXPORT_EDGE = 65000

local EXPORT_FORMATS = {
    jpeg = "JPEG",
    png = "PNG",
    tiff = "TIFF",
    original = "ORIGINAL",
}

local STANDARD_FOLDER_DESTINATIONS = { desktop = true, home = true, documents = true, pictures = true }

local function exportFolderOf(photo, exportSettings, fixedFolder)
    if fixedFolder then return fixedFolder end
    local destinationType = exportSettings.LR_export_destinationType
    local base
    if destinationType == "sourceFolder" then
        base = LrPathUtils.parent(photo:getRawMetadata("path"))
    elseif STANDARD_FOLDER_DESTINATIONS[destinationType] then
        base = LrPathUtils.getStandardFilePath(destinationType)
    end
    if not base then return nil end
    local suffix = exportSettings.LR_export_destinationPathSuffix
    if exportSettings.LR_export_useSubfolder and type(suffix) == "string" and suffix ~= "" then
        return LrPathUtils.child(base, suffix)
    end
    return base
end

local function isCatalogFolder(known, folder)
    return CatalogFolders.spellingsOf(known, folder) ~= nil
        or CatalogFolders.spellingsOf(known, LrPathUtils.standardizePath(folder)) ~= nil
end

local function refuseOverwriteIntoCatalogFolders(catalog, photos, exportSettings, fixedFolder)
    local known = CatalogFolders.of(catalog)
    for _, photo in ipairs(photos) do
        local folder = exportFolderOf(photo, exportSettings, fixedFolder)
        if folder and isCatalogFolder(known, folder) then
            error(
                string.format(
                    "on_existing overwrite would export into %s, a folder of this catalog, and could"
                        .. " replace a cataloged photo's file; choose a folder outside the catalog or on_existing rename"
                        .. " or skip",
                    folder
                ),
                0
            )
        end
        if fixedFolder then return end
    end
end

local function requireFormat(requestedFormat) return EXPORT_FORMATS[requestedFormat or "jpeg"] end

-- Lightroom's jpeg_quality is 0-1; the tool's quality is 0-100.
local function jpegQuality(quality) return quality / 100 end

-- Export settings when no preset is given: the tool's own defaults.
local function defaultSettings(args)
    local settings = {
        LR_jpeg_quality = jpegQuality(args.quality or DEFAULT_JPEG_QUALITY),
    }
    local format = requireFormat(args.format)
    settings.LR_format = format
    if format == "JPEG" then
        settings.LR_export_colorSpace = "sRGB"
    elseif format == "TIFF" then
        settings.LR_tiff_compressionMethod = "compressionMethod_LZW"
    end
    return settings
end

-- Export settings from a saved preset, with only the arguments the caller
-- passed layered on top: the preset's sharpening, renaming, metadata and
-- watermark settings survive a quality or size override.
local function presetSettings(preset, args)
    local settings = preset.settings
    if args.format ~= nil then settings.LR_format = requireFormat(args.format) end
    if args.quality ~= nil then
        settings.LR_jpeg_quality = jpegQuality(args.quality)
        -- Lightroom ignores the quality while a file size limit is on.
        settings.LR_jpeg_useLimitSize = false
    end
    -- Opening another application would leave it waiting for a user.
    settings.LR_export_postProcessing = "doNothing"
    settings.LR_reimportExportedPhoto = false
    return settings
end

-- width and height limit each edge in pixels. 'wh' is the only resize type that
-- reads them that way: 'longEdge' ignores width and treats height as the long
-- edge. A preset's other edge survives only if it already means the same thing.
local function applySizeLimit(settings, args)
    if not args.width and not args.height then return end
    local keepsOtherEdge = settings.LR_size_doConstrain
        and settings.LR_size_resizeType == "wh"
        and (settings.LR_size_units == nil or settings.LR_size_units == "pixels")
    settings.LR_size_maxWidth = args.width or (keepsOtherEdge and settings.LR_size_maxWidth) or MAX_EXPORT_EDGE
    settings.LR_size_maxHeight = args.height or (keepsOtherEdge and settings.LR_size_maxHeight) or MAX_EXPORT_EDGE
    settings.LR_size_doConstrain = true
    settings.LR_size_resizeType = "wh"
    settings.LR_size_units = "pixels"
    settings.LR_size_doNotEnlarge = true
end

-- Lightroom's export session ignores size_percentage and truncates
-- size_megapixels to a whole number (0.5 writes no file), so these sizes are
-- turned into a long edge for each photo.
local function scaleForPhoto(settings, dimensions)
    if settings.LR_size_resizeType == "percentage" then return settings.LR_size_percentage / 100 end
    return math.sqrt(settings.LR_size_megapixels * 1000000 / (dimensions.width * dimensions.height))
end

local function needsProportionalSize(settings)
    if not settings.LR_size_doConstrain then return false end
    local megapixels = settings.LR_size_megapixels
    return settings.LR_size_resizeType == "percentage"
        or (settings.LR_size_resizeType == "megapixels" and megapixels ~= math.floor(megapixels))
end

-- Each photo gets its own session so a batch can be cancelled between photos,
-- so what Lightroom would count across one session is set for each photo here.
-- Returns nil and a reason when the photo's size cannot be worked out.
local function settingsForPhoto(baseSettings, photo, index, total)
    local settings = {}
    for key, value in pairs(baseSettings) do
        settings[key] = value
    end
    settings.LR_initialSequenceNumber = (settings.LR_initialSequenceNumber or 1) + index - 1
    if type(settings.LR_tokens) == "string" then
        settings.LR_tokens = settings.LR_tokens:gsub(
            "{{naming_sequenceTotal_(%d)Digits?}}",
            function(digits) return string.format("%0" .. digits .. "d", total) end
        )
    end
    if needsProportionalSize(settings) then
        local dimensions = photo:getRawMetadata("croppedDimensions")
        if type(dimensions) ~= "table" or not dimensions.width or not dimensions.height then
            return nil, "Lightroom reported no dimensions for this photo"
        end
        local edge = math.max(dimensions.width, dimensions.height) * scaleForPhoto(settings, dimensions)
        edge = math.max(1, math.floor(edge + 0.5))
        settings.LR_size_resizeType = "longEdge"
        settings.LR_size_units = "pixels"
        settings.LR_size_maxWidth = edge
        settings.LR_size_maxHeight = edge
    end
    return settings
end

local EXPORT_PHOTO_RESERVE_SECONDS = 60

local function prepareExport(context, args, catalog)
    local preset
    if args.export_preset ~= nil then preset = ExportPresets.resolve(args.export_preset, args.export_preset_folder) end

    local destination
    if args.destination ~= nil then
        destination = PathForms.absolute(args.destination, "destination")
    else
        local destinationType = preset.settings.LR_export_destinationType
        if
            not ExportPresets.FIXED_DESTINATION_TYPES[destinationType]
            or (destinationType == "specificFolder" and not preset.settings.LR_export_destinationPathPrefix)
        then
            error(
                "Export preset '"
                    .. preset.name
                    .. "' has no fixed destination ("
                    .. tostring(destinationType)
                    .. "); pass destination"
            )
        end
    end

    -- Every argument is checked before the folder is created, so a rejected
    -- call leaves nothing behind.
    local collisionHandling = args.on_existing or DEFAULT_COLLISION_HANDLING

    local exportSettings = preset and presetSettings(preset, args) or defaultSettings(args)
    exportSettings.LR_collisionHandling = COLLISION_HANDLING[collisionHandling]

    applySizeLimit(exportSettings, args)

    -- Resolved without read access: the lookup runs catalog queries, which
    -- must not nest inside withReadAccessDo. Never hold read access across
    -- the export either: doExportOnCurrentTask() can run for minutes on a
    -- large batch, and holding it for that span blocks every other handler
    -- (list_collections, get_selected_photos, ...) and on macOS wedged the
    -- bridge until a manual restart (issue #128). LrExportSession acquires
    -- its own catalog access during rendering.
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    local plan = {
        entries = entries,
        notFound = notFound,
        preset = preset,
        exportSettings = exportSettings,
        collisionHandling = collisionHandling,
    }
    if #entries == 0 then return plan end

    local photos = {}
    for index, entry in ipairs(entries) do
        photos[index] = entry.photo
    end

    local presetFolder
    if not destination and exportSettings.LR_export_destinationType == "specificFolder" then
        presetFolder = ExportPresets.specificFolderPath(
            exportSettings.LR_export_destinationPathPrefix,
            exportSettings.LR_export_useSubfolder,
            exportSettings.LR_export_destinationPathSuffix
        )
    end

    local exportFolder = destination or presetFolder
    if collisionHandling == "overwrite" then
        refuseOverwriteIntoCatalogFolders(catalog, photos, exportSettings, exportFolder)
    end
    if exportFolder then
        -- Lightroom refuses a missing folder with its own error, in the UI
        -- language; create it as export_photo_metadata and export_develop_preset do.
        local existing = LrFileUtils.exists(exportFolder)
        if existing == false then
            CatalogWrite.createFolder(context, exportFolder)
            if LrFileUtils.exists(exportFolder) ~= "directory" then
                error("could not create destination folder: " .. exportFolder)
            end
        elseif existing ~= "directory" then
            error("destination is not a directory: " .. exportFolder)
        end
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. Without a destination argument the
    -- preset's own destination (type, folder, subfolder) is kept.
    if destination then
        exportSettings.LR_export_destinationType = "specificFolder"
        exportSettings.LR_export_destinationPathPrefix = destination
        exportSettings.LR_export_useSubfolder = false
    else
        destination = presetFolder or exportSettings.LR_export_destinationType
    end
    plan.destination = destination
    return plan
end

local EXPORT_LEAVES = { "one Export history step", "the exported mark" }

local function renderSession(context, exportSession, plan, photoId)
    CatalogWrite.invoke(
        context,
        "Export photo " .. photoId .. " (" .. table.concat(EXPORT_LEAVES, " and ") .. ")",
        function() exportSession:doExportOnCurrentTask() end
    )
    local outcome = { files = {}, failures = {} }
    local renditionCount = 0
    for _, rendition in exportSession:renditions() do
        renditionCount = renditionCount + 1
        local rendered, pathOrMessage = rendition:waitForRender()
        if rendered and LrFileUtils.exists(pathOrMessage) then
            local relative = plan.destination and PathForms.relative(plan.destination, pathOrMessage)
            outcome.files[#outcome.files + 1] = {
                photo_id = photoId,
                path = relative and LrPathUtils.child(plan.destination, relative) or pathOrMessage,
            }
        else
            outcome.failures[#outcome.failures + 1] = rendered and "Lightroom wrote no file" or tostring(pathOrMessage)
        end
    end
    if renditionCount == 0 then
        if plan.collisionHandling == "skip" then
            outcome.skipped = true
        else
            outcome.failures[#outcome.failures + 1] = "Lightroom rendered no file"
        end
    end
    return outcome
end

local function exportOne(context, plan, photo, index, total)
    local photoId = tostring(photo.localIdentifier)
    local photoSettings, settingsError = plan.exportSettings, nil
    if plan.preset then
        photoSettings, settingsError = settingsForPhoto(plan.exportSettings, photo, index, total)
    end
    if not photoSettings then return { failed = settingsError } end
    local exportSession = LrExportSession {
        photosToExport = { photo },
        exportSettings = photoSettings,
    }
    local ran, outcome = LrTasks.pcall(renderSession, context, exportSession, plan, photoId)
    if not ran then return { files = {}, failures = { Reply.messageOf(outcome) } } end
    return outcome
end

local function runExport(args, context, run)
    local catalog = LrApplication.activeCatalog()
    local prepared, plan = LrTasks.pcall(prepareExport, context, args, catalog)
    if not prepared then Reply.refuse(Reply.messageOf(plan)) end
    if #plan.entries == 0 then return Reply.parts({ not_found = plan.notFound }) end

    local files, skipped, failed, unknown, remaining = {}, {}, {}, {}, {}
    local lastName
    for index, entry in ipairs(plan.entries) do
        local photo = entry.photo
        if #remaining > 0 or context:stopping(EXPORT_PHOTO_RESERVE_SECONDS) then
            remaining[#remaining + 1] = entry.id
        else
            run.lastPhotoAt = LrDate.currentTime()
            local photoId = tostring(photo.localIdentifier)
            local name = photo:getFormattedMetadata("fileName") or photoId
            context:report(#files, #plan.entries, name)
            local mark = context.ledger:mark()
            local function stopped(problem)
                local class, reason = Reply.stopped(problem, context.ledger:since(mark))
                local list = class == "failed" and failed or unknown
                list[#list + 1] = { photo_id = photoId, reason = reason }
            end
            local exported, outcome = LrTasks.pcall(exportOne, context, plan, photo, index, #plan.entries)
            if not exported then
                stopped(outcome)
            elseif outcome.failed then
                stopped(outcome.failed)
            else
                for _, file in ipairs(outcome.files) do
                    files[#files + 1] = file
                end
                for _, reason in ipairs(outcome.failures) do
                    stopped(reason)
                end
                if outcome.skipped then skipped[#skipped + 1] = photoId end
            end
            lastName = name
        end
    end
    if lastName then context:report(#files, #plan.entries, lastName) end

    Log.info(
        string.format(
            "Exported %d photos to: %s (skipped %d, failed %d, unknown %d)",
            #files,
            plan.destination,
            #skipped,
            #failed,
            #unknown
        )
    )

    local preset = plan.preset
    return Reply.parts({
        data = (#files > 0 or #skipped > 0) and {
            files = files,
            skipped = #skipped > 0 and skipped or nil,
            destination = plan.destination,
            preset = preset and {
                name = preset.name,
                folder = preset.folder,
                scope = preset.scope,
                file = preset.file,
            } or nil,
        } or nil,
        failed = #failed > 0 and failed or nil,
        unknown = #unknown > 0 and unknown or nil,
        not_found = #plan.notFound > 0 and plan.notFound or nil,
        remaining = #remaining > 0 and remaining or nil,
    })
end

-- Parallel export sessions wrote no file at all (6 calls, empty folder, LrC 15.6).
local currentRun = nil
-- An export session can hang without an error and never return. Without a limit
-- that one call would refuse every later export until the plug-in reloads.
local STALE_PHOTO_SECONDS = 300

local function withExportLock(tool, body)
    local now = LrDate.currentTime()
    if currentRun and now - currentRun.lastPhotoAt < STALE_PHOTO_SECONDS then
        Reply.refuse(currentRun.tool .. " is already running; wait for it to finish, then call again")
    end
    local run = { lastPhotoAt = now, tool = tool }
    currentRun = run
    local ok, result = LrTasks.pcall(body, run)
    if currentRun == run then currentRun = nil end
    if not ok then error(result, 0) end
    return result
end

function ExportHandler.exportPhotos(args, context)
    return withExportLock("export_photos", function(run) return runExport(args, context, run) end)
end

local detailRenders = 0

local function removeDirectory(directory)
    for file in LrFileUtils.files(directory) do
        LrFileUtils.delete(file)
    end
    LrFileUtils.delete(directory)
end

local function newDetailDirectory()
    detailRenders = detailRenders + 1
    local base = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), Contract.DETAIL_RENDER_FOLDER)
    local startedMs = math.floor(LrDate.currentTime() * 1000)
    if LrFileUtils.exists(base) == "directory" then
        for entry in LrFileUtils.directoryEntries(base) do
            local entryStartedMs = tonumber(LrPathUtils.leafName(entry):match("^(%d+)%-%d+$"))
            if entryStartedMs and startedMs - entryStartedMs >= STALE_PHOTO_SECONDS * 1000 then
                removeDirectory(entry)
            end
        end
    end
    return LrPathUtils.child(base, string.format("%d-%d", startedMs, detailRenders))
end

local function detailSettings(directory)
    return {
        LR_format = "JPEG",
        LR_jpeg_quality = 1,
        LR_export_colorSpace = "sRGB",
        LR_size_doConstrain = false,
        LR_outputSharpeningOn = false,
        LR_embeddedMetadataOption = "copyrightOnly",
        LR_removeLocationMetadata = true,
        LR_reimportExportedPhoto = false,
        LR_collisionHandling = "overwrite",
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = directory,
        LR_export_useSubfolder = false,
    }
end

local function renditionSettings(directory, edge)
    local settings = detailSettings(directory)
    settings.LR_jpeg_quality = Contract.RENDITION_JPEG_QUALITY / 100
    settings.LR_size_doConstrain = true
    settings.LR_size_resizeType = "longEdge"
    settings.LR_size_units = "pixels"
    settings.LR_size_maxWidth = edge
    settings.LR_size_maxHeight = edge
    settings.LR_size_doNotEnlarge = true
    return settings
end

local function discardRender(context, render)
    if LrFileUtils.exists(render.directory) == "directory" then removeDirectory(render.directory) end
    if render.created ~= render.directory and LrFileUtils.exists(render.created) == "directory" then
        LrFileUtils.delete(render.created)
    end
    if not LrFileUtils.exists(render.created) then context.ledger:undone(render.beforeFolder, render.afterFolder) end
end

local function renderToFile(context, photo, run, settingsOf)
    local render = { directory = newDetailDirectory(), beforeFolder = context.ledger:mark() }
    render.created = CatalogWrite.createFolder(context, render.directory) or render.directory
    render.afterFolder = context.ledger:mark()
    run.lastPhotoAt = LrDate.currentTime()
    local plan = { exportSettings = settingsOf(render.directory), collisionHandling = "overwrite" }
    local rendered, outcome = LrTasks.pcall(exportOne, context, plan, photo, 1, 1)
    if rendered and #outcome.files == 1 and #outcome.failures == 0 then return outcome.files[1].path end
    discardRender(context, render)
    return nil, not rendered and outcome or outcome.failures[1] or "Lightroom rendered no file", render.beforeFolder
end

function ExportHandler.renderSource(args, context)
    return withExportLock(args.tool, function(run)
        local photo = PhotoLookup.resolveOne(LrApplication.activeCatalog(), args.photo_id)
        if not photo then return Reply.parts({ not_found = { args.photo_id } }) end
        local photoId = tostring(photo.localIdentifier)
        local settingsOf = detailSettings
        if args.long_edge then
            settingsOf = function(directory) return renditionSettings(directory, args.long_edge) end
        end
        local path, problem, mark = renderToFile(context, photo, run, settingsOf)
        if not path then
            local class, reason = Reply.stopped(problem, context.ledger:since(mark))
            return Reply.parts({ [class] = { { photo_id = photoId, reason = reason } } })
        end
        return { photo_id = photoId, path = path, source = "export", left_on_photo = EXPORT_LEAVES }
    end)
end

-- Lists the export presets saved on disk, including ones that cannot run over
-- the bridge (other export services) with the reason, so a failed lookup in
-- export_photos can be explained.
function ExportHandler.listExportPresets(args)
    local presets = ExportPresets.list(args.folder)
    return {
        presets = presets,
        count = #presets,
    }
end

-- Same cap as an explicit photo_ids list. The selection has none of its own:
-- with nothing selected getTargetPhotos() is the whole filmstrip, which can
-- outlast the server timeout and hold the read gate throughout.
local MAX_METADATA_PHOTOS = 1000
local RECORD_RAW_KEYS = PhotoRecord.rawKeys({
    "uuid",
    "path",
    "fileFormat",
    "isVirtualCopy",
    "dateTimeOriginalISO8601",
    "dimensions",
    "croppedDimensions",
})
local RECORD_FORMATTED_KEYS = PhotoRecord.formattedKeys({ "fileName", "title", "caption" })

local function sizeOf(dimensions)
    if type(dimensions) ~= "table" then return nil end
    return { width = dimensions.width, height = dimensions.height }
end

local function prepareMetadataExport(args, catalog)
    local destination = PathForms.absolute(args.destination, "destination")
    -- Refuse to replace a file unless asked, like export_photos: the path can
    -- come from text an attacker controls (a caption), and any .json the
    -- Lightroom process can write would otherwise be clobbered.
    local function checkDestination()
        local existing = LrFileUtils.exists(destination)
        if existing == "directory" then error("destination is a directory: " .. destination) end
        if existing and args.overwrite ~= true then
            error("destination already exists: " .. destination .. " (pass overwrite: true to replace it)")
        end
        return existing
    end
    checkDestination()

    -- Both lookups run OUTSIDE the read gate: getTargetPhotos() yields to the
    -- UI thread and deadlocks inside it on Windows (#124/#134).
    local photos = {}
    local missingIds = {}
    if args.photo_ids then
        local entries
        entries, missingIds = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
        for i, entry in ipairs(entries) do
            photos[i] = entry.photo
        end
    else
        photos = catalog:getTargetPhotos() or {}
        if #photos > MAX_METADATA_PHOTOS then
            error(
                string.format(
                    "%d photos are selected (or in the filmstrip); export at most %d "
                        .. "at a time by selecting fewer or passing photo_ids",
                    #photos,
                    MAX_METADATA_PHOTOS
                )
            )
        end
    end

    if #photos == 0 and #missingIds == 0 then error("No photos found to export metadata for") end
    return { destination = destination, photos = photos, missingIds = missingIds, checkDestination = checkDestination }
end

function ExportHandler.exportPhotoMetadata(args, context)
    local catalog = LrApplication.activeCatalog()
    local prepared, plan = LrTasks.pcall(prepareMetadataExport, args, catalog)
    if not prepared then Reply.refuse(Reply.messageOf(plan)) end
    local destination, photos, missingIds, checkDestination =
        plan.destination, plan.photos, plan.missingIds, plan.checkDestination
    if #photos == 0 then return Reply.parts({ not_found = missingIds }) end

    local raw = catalog:batchGetRawMetadata(photos, RECORD_RAW_KEYS) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, RECORD_FORMATTED_KEYS) or {}
    local records = {}
    catalog:withReadAccessDo(function()
        local readKeywords = PhotoRecord.keywordReader()
        for _, photo in ipairs(photos) do
            local r = raw[photo] or {}
            local f = formatted[photo] or {}
            records[#records + 1] = PhotoRecord.merged({
                photo_id = tostring(photo.localIdentifier),
                uuid = r.uuid,
                path = r.path,
                filename = f.fileName,
                file_format = r.fileFormat,
                is_virtual_copy = r.isVirtualCopy,
                capture_time = r.dateTimeOriginalISO8601,
                dimensions = sizeOf(r.dimensions),
                cropped_dimensions = sizeOf(r.croppedDimensions),
                title = f.title,
                caption = f.caption,
            }, PhotoRecord.shared(r, f, readKeywords))
        end
    end)

    -- Encoded before the file is opened, so an encoding error leaves nothing
    -- behind, and checked again: a file may have appeared while photos were read.
    local text = JSON:encode({ version = 2, count = #records, photos = records })
    local checked, existedBefore = LrTasks.pcall(checkDestination)
    if not checked then Reply.refuse(Reply.messageOf(existedBefore)) end
    local parent = LrPathUtils.parent(destination)
    if parent then CatalogWrite.createFolder(context, parent) end

    local beforeFile = context.ledger:mark()
    local file, openError = CatalogWrite.invoke(context, destination, io.open, destination, "w")
    if not file then
        if not existedBefore and not LrFileUtils.exists(destination) then context.ledger:undone(beforeFile) end
        error("Could not write " .. destination .. ": " .. tostring(openError))
    end
    local written, writeError = file:write(text)
    local closed, closeError = file:close()
    if not written or not closed then
        -- A partial file this call created would make every retry fail with
        -- "already exists"; one it replaced was given up by overwrite: true.
        if not existedBefore then
            LrFileUtils.delete(destination)
            if not LrFileUtils.exists(destination) then context.ledger:undone(beforeFile) end
        end
        error(
            "Could not write " .. destination .. " (the file may be incomplete): " .. tostring(writeError or closeError)
        )
    end

    Log.info(string.format("Exported metadata for %d photos to: %s", #records, destination))

    return Reply.parts({
        data = { exported = #records, destination = destination },
        not_found = #missingIds > 0 and missingIds or nil,
    })
end

return ExportHandler
