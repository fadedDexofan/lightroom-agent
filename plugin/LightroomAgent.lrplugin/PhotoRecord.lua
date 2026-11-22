local KeywordTree = require "KeywordTree"
local PhotoMarks = require "PhotoMarks"

local PhotoRecord = {}

local SHARED_RAW_KEYS = PhotoMarks.withRawKeys({ "keywords", "gps", "gpsAltitude" })
local SHARED_FORMATTED_KEYS = { "location", "city", "stateProvince", "country", "isoCountryCode" }

local function joined(...)
    local all = {}
    for _, list in ipairs({ ... }) do
        for _, key in ipairs(list) do
            all[#all + 1] = key
        end
    end
    return all
end

function PhotoRecord.rawKeys(extra) return joined(extra, SHARED_RAW_KEYS) end

function PhotoRecord.formattedKeys(extra) return joined(extra, SHARED_FORMATTED_KEYS) end

function PhotoRecord.nonEmptyGroup(fields)
    for _, v in pairs(fields) do
        if v ~= nil and v ~= "" then return fields end
    end
    return nil
end

function PhotoRecord.keywordReader()
    local known = {}
    local function entryOf(keyword)
        if not known[keyword] then
            local name = keyword:getName()
            local parent = keyword:getParent()
            known[keyword] = {
                name = name,
                path = parent and KeywordTree.join({ entryOf(parent).path, name }) or name,
            }
        end
        return known[keyword]
    end
    return function(keywords)
        local names, paths = {}, {}
        for _, keyword in ipairs(keywords or {}) do
            local entry = entryOf(keyword)
            names[#names + 1] = entry.name
            paths[#paths + 1] = entry.path
        end
        return names, paths
    end
end

function PhotoRecord.shared(raw, formatted, readKeywords)
    local keywords, keywordPaths = readKeywords(raw.keywords)
    local marks = PhotoMarks.of(raw)
    return {
        rating = marks.rating,
        flag = marks.flag,
        color_label = marks.color_label,
        keywords = keywords,
        keyword_paths = keywordPaths,
        gps = raw.gps and PhotoRecord.nonEmptyGroup({
            latitude = raw.gps.latitude,
            longitude = raw.gps.longitude,
            altitude = raw.gpsAltitude,
        }) or nil,
        location = PhotoRecord.nonEmptyGroup({
            sublocation = formatted.location,
            city = formatted.city,
            state_province = formatted.stateProvince,
            country = formatted.country,
            iso_country_code = formatted.isoCountryCode,
        }),
    }
end

function PhotoRecord.merged(record, shared)
    for key, value in pairs(shared) do
        record[key] = value
    end
    return record
end

return PhotoRecord
