local LrApplication = import "LrApplication"

local Contract = require "Contract"
local Log = require "Log"
local PhotoStack = require "PhotoStack"
local PhotoSummary = require "PhotoSummary"

local SearchHandler = {}
local FLAGS, LABELS = {}, {}
for _, flag in ipairs(Contract.PHOTO_FLAGS) do
    FLAGS[flag.name] = flag.pickStatus
end
for _, label in ipairs(Contract.COLOR_LABELS) do
    LABELS[label.name] = label.labelColor
end

local function timestampOf(value)
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
end

local function addDays(timestamp, days) return os.date("%Y-%m-%d", timestamp + (days * 86400)) end

local function buildSearchDesc(args)
    local desc = { combine = "intersect" }

    if args.filename then table.insert(desc, { criteria = "filename", operation = "any", value = args.filename }) end

    if args.rating then table.insert(desc, { criteria = "rating", operation = "==", value = args.rating }) end

    if args.keywords and #args.keywords > 0 then
        for _, kw in ipairs(args.keywords) do
            table.insert(desc, { criteria = "keywords", operation = "all", value = kw })
        end
    end

    if args.start_date and args.end_date then
        table.insert(desc, {
            criteria = "captureTime",
            operation = "in",
            value = args.start_date,
            value2 = args.end_date,
        })
    elseif args.start_date then
        table.insert(
            desc,
            { criteria = "captureTime", operation = ">", value = addDays(timestampOf(args.start_date), -1) }
        )
    elseif args.end_date then
        table.insert(
            desc,
            { criteria = "captureTime", operation = "<", value = addDays(timestampOf(args.end_date), 1) }
        )
    end

    for _, field in ipairs({ "camera", "lens", "folder" }) do
        if args[field] ~= nil then
            table.insert(
                desc,
                { criteria = field, operation = field == "folder" and "all" or "==", value = args[field] }
            )
        end
    end
    if args.iso ~= nil then table.insert(desc, { criteria = "isoSpeedRating", operation = "==", value = args.iso }) end
    if args.focal_length ~= nil then
        table.insert(desc, { criteria = "focalLength", operation = "==", value = args.focal_length })
    end
    if args.flag ~= nil then table.insert(desc, { criteria = "pick", operation = "==", value = FLAGS[args.flag] }) end
    if args.color_label ~= nil then
        table.insert(desc, { criteria = "labelColor", operation = "==", value = LABELS[args.color_label] })
    end
    if args.edited ~= nil then
        table.insert(
            desc,
            { criteria = "hasAdjustments", operation = args.edited and "isTrue" or "isFalse", value = args.edited }
        )
    end
    if args.file_type ~= nil then
        table.insert(desc, { criteria = "fileFormat", operation = "==", value = args.file_type })
    end

    return desc
end

SearchHandler.buildSearchDesc = buildSearchDesc

function SearchHandler.searchPhotos(args, context)
    local catalog = LrApplication.activeCatalog()
    local searchDesc = buildSearchDesc(args)
    local hasFilters = #searchDesc > 0

    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0

    -- Run the catalog query OUTSIDE withReadAccessDo. findPhotos() runs an
    -- async catalog search that yields; called from inside the read gate on
    -- Windows it deadlocks -- the task never returns and never releases the
    -- gate, wedging the whole bridge until the 30s server timeout (issue #124,
    -- same root cause as #134's getTargetPhotos).
    Log.info(string.format("searchPhotos: querying (hasFilters=%s)", tostring(hasFilters)))
    -- Unrated photos have nil rating; rating>=0 excludes them, so getAllPhotos()
    -- must be used when no filters are specified.
    local matches = (hasFilters and catalog:findPhotos { searchDesc = searchDesc } or catalog:getAllPhotos()) or {}

    local total = #matches
    Log.info(string.format("searchPhotos: query returned %d", total))

    local last = math.min(offset + limit, total)
    local results = PhotoSummary.page(catalog, matches, offset + 1, last, args.include_path == true)

    Log.info(
        string.format("Search matched %d photos, returning %d (offset=%d, limit=%d)", total, #results, offset, limit)
    )

    local collapsedTops = {}
    for _, row in ipairs(results) do
        if PhotoStack.isCollapsedTop(row.stack) then collapsedTops[#collapsedTops + 1] = row.photo_id end
    end
    if #collapsedTops > 0 then
        context:warn(
            "Lightroom does not search the hidden photos of a collapsed stack; these rows are the tops of"
                .. " collapsed stacks whose other photos may match too: "
                .. table.concat(collapsedTops, ", ")
                .. ". get_photo_metadata of a top photo lists its stack's member_photo_ids, which other tools"
                .. " accept by id; or expand the stacks in Lightroom and search again."
        )
    end

    if not hasFilters then
        context:warn(
            "No filters applied — scanned full catalog. Provide filename, keywords, rating, or date filters to narrow results and improve performance."
        )
    end

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

return SearchHandler
