local PhotoMarks = require "PhotoMarks"
local PhotoStack = require "PhotoStack"

local PhotoSummary = {}

local RAW_KEYS = PhotoStack.withRawKeys(PhotoMarks.withRawKeys({ "path" }))
local FORMATTED_KEYS = { "fileName", "dateTimeOriginal" }

function PhotoSummary.rows(catalog, photos, includePath)
    local rows = {}
    if #photos == 0 then return rows end
    local raw = catalog:batchGetRawMetadata(photos, RAW_KEYS) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, FORMATTED_KEYS) or {}
    for i, photo in ipairs(photos) do
        local r = raw[photo] or {}
        local f = formatted[photo] or {}
        local marks = PhotoMarks.of(r)
        rows[i] = {
            photo_id = tostring(photo.localIdentifier),
            filename = f.fileName,
            rating = marks.rating,
            flag = marks.flag,
            color_label = marks.color_label,
            date_time_original = f.dateTimeOriginal,
            stack = PhotoStack.of(r),
        }
        if includePath then rows[i].path = r.path end
    end
    return rows
end

function PhotoSummary.page(catalog, photos, first, last, includePath)
    local slice = {}
    for i = first, last do
        slice[#slice + 1] = photos[i]
    end
    return PhotoSummary.rows(catalog, slice, includePath)
end

return PhotoSummary
