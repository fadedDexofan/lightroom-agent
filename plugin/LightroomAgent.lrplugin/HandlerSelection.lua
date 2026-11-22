local LrApplication = import "LrApplication"

local Contract = require "Contract"
local Log = require "Log"
local PhotoSummary = require "PhotoSummary"

local SelectionHandler = {}

function SelectionHandler.getSelectedPhotos(args)
    local catalog = LrApplication.activeCatalog()

    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0

    -- Acquire the target set OUTSIDE withReadAccessDo. getTargetPhotos() reads
    -- the live view selection, which yields to the UI thread; called from
    -- inside the read gate on Windows it deadlocks -- the task never returns
    -- and never releases the gate, so the whole bridge wedges until the 30s
    -- server timeout (issues #134, #124).
    Log.info("getSelectedPhotos: requesting target photos")
    local matches = catalog:getTargetPhotos() or {}
    local total = #matches
    Log.info(string.format("getSelectedPhotos: getTargetPhotos returned %d", total))

    local last = math.min(offset + limit, total)
    local results = PhotoSummary.page(catalog, matches, offset + 1, last, args.include_path == true)

    Log.info(string.format("getSelectedPhotos: returning %d (offset=%d, limit=%d)", #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

return SelectionHandler
