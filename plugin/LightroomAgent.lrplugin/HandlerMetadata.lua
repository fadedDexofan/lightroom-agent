local LrApplication = import "LrApplication"

local PhotoRecord = require "PhotoRecord"
local PhotoStack = require "PhotoStack"
local PhotoLookup = require "PhotoLookup"
local PhotoWrites = require "PhotoWrites"
local Log = require "Log"
local Reply = require "Reply"

local MetadataHandler = {}

local TEXT_FIELDS = {
    { arg = "title", key = "title" },
    { arg = "caption", key = "caption" },
    { arg = "headline", key = "headline" },
    { arg = "creator", key = "creator" },
    { arg = "copyright", key = "copyright" },
    { arg = "rights_usage_terms", key = "rightsUsageTerms" },
    { arg = "copyright_info_url", key = "copyrightInfoUrl" },
    { arg = "creator_url", key = "creatorUrl" },
    { arg = "alt_text", key = "altTextAccessibility", accessibility = true },
    { arg = "extended_description", key = "extDescrAccessibility", accessibility = true },
}

local ACCESSIBILITY_KEYS = {}
for _, field in ipairs(TEXT_FIELDS) do
    if field.accessibility then ACCESSIBILITY_KEYS[#ACCESSIBILITY_KEYS + 1] = field.key end
end
local RAW_KEYS = PhotoRecord.rawKeys(PhotoStack.withRawKeys({
    "path",
    "fileFormat",
    "isVirtualCopy",
    "masterPhoto",
    "virtualCopies",
    "stackInFolderMembers",
}))
local FORMATTED_KEYS = PhotoRecord.formattedKeys({
    "fileName",
    "title",
    "caption",
    "headline",
    "copyName",
    "dateTimeOriginal",
    "dateTimeDigitized",
    "cameraMake",
    "cameraModel",
    "cameraSerialNumber",
    "lens",
    "isoSpeedRating",
    "focalLength",
    "focalLength35mm",
    "aperture",
    "shutterSpeed",
    "exposureBias",
    "exposureProgram",
    "meteringMode",
    "flash",
    "dimensions",
    "fileSize",
    "artist",
    "software",
    "creator",
    "copyright",
    "copyrightState",
    "rightsUsageTerms",
    "copyrightInfoUrl",
    "creatorUrl",
})

local function nonEmptyText(value)
    if value == "" then return nil end
    return value
end

local function photoIdOf(photo) return photo and tostring(photo.localIdentifier) end

local function photoIds(photos)
    if not photos or #photos == 0 then return nil end
    local ids = {}
    for i, photo in ipairs(photos) do
        ids[i] = photoIdOf(photo)
    end
    return ids
end

local function virtualCopyMetadata(r, f)
    if r.isVirtualCopy == true then
        return PhotoRecord.nonEmptyGroup({
            master_photo_id = photoIdOf(r.masterPhoto),
            copy_name = nonEmptyText(f.copyName),
        })
    end
    return PhotoRecord.nonEmptyGroup({ copy_photo_ids = photoIds(r.virtualCopies) })
end

local function rawRows(catalog, photos)
    local keys = {}
    for _, list in ipairs({ RAW_KEYS, ACCESSIBILITY_KEYS }) do
        for _, key in ipairs(list) do
            keys[#keys + 1] = key
        end
    end
    return catalog:batchGetRawMetadata(photos, keys) or {}
end

local function photoRecord(photo, r, f, readKeywords)
    return PhotoRecord.merged({
        photo_id = photoIdOf(photo),
        is_virtual_copy = r.isVirtualCopy == true,
        virtual_copy = virtualCopyMetadata(r, f),
        stack = PhotoStack.of(r, r.isInStackInFolder and r.stackInFolderMembers),
        path = r.path,
        filename = f.fileName,
        title = f.title,
        caption = f.caption,
        headline = f.headline,
        accessibility = PhotoRecord.nonEmptyGroup({
            alt_text = nonEmptyText(r.altTextAccessibility),
            extended_description = nonEmptyText(r.extDescrAccessibility),
        }),
        date_time_original = f.dateTimeOriginal,
        date_time_digitized = f.dateTimeDigitized,
        camera_make = f.cameraMake,
        camera_model = f.cameraModel,
        camera_serial_number = f.cameraSerialNumber,
        lens = f.lens,
        iso_speed_rating = f.isoSpeedRating,
        focal_length = f.focalLength,
        focal_length_35mm = f.focalLength35mm,
        aperture = f.aperture,
        shutter_speed = f.shutterSpeed,
        exposure_bias = f.exposureBias,
        exposure_program = f.exposureProgram,
        metering_mode = f.meteringMode,
        flash = f.flash,
        dimensions = f.dimensions,
        file_size = f.fileSize,
        file_format = r.fileFormat,
        artist = f.artist,
        software = f.software,
        copyright = PhotoRecord.nonEmptyGroup({
            creator = f.creator,
            notice = f.copyright,
            status = f.copyrightState,
            rights_usage_terms = f.rightsUsageTerms,
            info_url = f.copyrightInfoUrl,
            creator_url = f.creatorUrl,
        }),
    }, PhotoRecord.shared(r, f, readKeywords))
end

function MetadataHandler.getPhotoMetadata(args)
    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    local found, missing = {}, {}
    for _, entry in ipairs(resolved) do
        if entry.photo then
            found[#found + 1] = entry.photo
        else
            missing[#missing + 1] = entry.id
        end
    end
    local raw = #found > 0 and rawRows(catalog, found) or {}
    local formatted = #found > 0 and (catalog:batchGetFormattedMetadata(found, FORMATTED_KEYS) or {}) or {}
    local photos = {}
    catalog:withReadAccessDo(function()
        local readKeywords = PhotoRecord.keywordReader()
        for i, photo in ipairs(found) do
            photos[i] = photoRecord(photo, raw[photo] or {}, formatted[photo] or {}, readKeywords)
        end
    end)

    Log.info(string.format("Retrieved metadata for %d photos (%d ids not found)", #photos, #missing))
    return Reply.parts({
        data = #photos > 0 and { photos = photos } or nil,
        not_found = #missing > 0 and missing or nil,
    })
end

-- Writes a GPS position (decimal degrees) to photos, replacing any position
-- they already have. Altitude is only touched when given or cleared.
function MetadataHandler.setGps(args, context)
    local clearAltitude = args.clear_altitude == true

    return PhotoWrites.each(context, LrApplication.activeCatalog(), {
        photo_ids = args.photo_ids,
        title = "Set GPS",
        write = function(call)
            call("setRawMetadata", "gps", { latitude = args.latitude, longitude = args.longitude })
            if args.altitude ~= nil then
                call("setRawMetadata", "gpsAltitude", args.altitude)
            elseif clearAltitude then
                call("setRawMetadata", "gpsAltitude", nil)
            end
        end,
    })
end

-- "Sublocation" is the SDK `location` field.
local LOCATION_FIELDS = {
    { arg = "sublocation", key = "location" },
    { arg = "city", key = "city" },
    { arg = "state_province", key = "stateProvince" },
    { arg = "country", key = "country" },
    { arg = "iso_country_code", key = "isoCountryCode" },
}

-- Writes the IPTC location fields of photos. Fields left out are unchanged;
-- an empty string clears a field. GPS is set_gps's job and is not touched.
function MetadataHandler.setLocation(args, context)
    local changes = {}
    for _, field in ipairs(LOCATION_FIELDS) do
        local value = args[field.arg]
        if value ~= nil then
            -- An empty string is passed through: it is what clears the
            -- field. Lightroom stores nil on these fields as the text "nil".
            changes[#changes + 1] = { arg = field.arg, key = field.key, value = value }
        end
    end
    local fields = {}
    for i, change in ipairs(changes) do
        fields[i] = change.arg
    end

    return PhotoWrites.each(context, LrApplication.activeCatalog(), {
        photo_ids = args.photo_ids,
        title = "Set Location",
        data = { fields = fields },
        write = function(call)
            for _, change in ipairs(changes) do
                call("setRawMetadata", change.key, change.value)
            end
        end,
    })
end

-- Writes IPTC description and rights fields of photos. Fields left out are
-- unchanged; an empty string clears a field. Copyright status is left out on
-- purpose: Lightroom accepted "copyrighted" for copyrightState but rolled the
-- whole write back for "unknown" and "public domain", after reporting success.
function MetadataHandler.setMetadata(args, context)
    local changes = {}
    local fields = {}
    for _, field in ipairs(TEXT_FIELDS) do
        local value = args[field.arg]
        if value ~= nil then
            -- An empty string is passed through: it is what clears the
            -- field. Lightroom stores nil on these fields as the text "nil".
            changes[#changes + 1] = { key = field.key, value = value }
            fields[#fields + 1] = field.arg
        end
    end

    return PhotoWrites.each(context, LrApplication.activeCatalog(), {
        photo_ids = args.photo_ids,
        title = "Set Metadata",
        data = { fields = fields },
        write = function(call)
            for _, change in ipairs(changes) do
                call("setRawMetadata", change.key, change.value)
            end
        end,
    })
end

return MetadataHandler
