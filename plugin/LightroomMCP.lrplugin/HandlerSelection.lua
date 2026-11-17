local LrApplication = import 'LrApplication'

local Contract = require 'Contract'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'
local PhotoSummary = require 'PhotoSummary'
local Reply = require 'Reply'

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

    Log.info(string.format("getSelectedPhotos: returning %d (offset=%d, limit=%d)",
        #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

-- Test-only: kept out of server/src/tool-contracts.ts so it is reachable from
-- the raw TCP probe but never from an MCP client, which must not be able to
-- reorder the user's filmstrip. Lets the e2e playbook stage the selection that
-- get_selected_photos reads back, instead of a human clicking in Lightroom.
function SelectionHandler.setSelection(args, context)
    local ids = args.photo_ids
    if type(ids) ~= "table" or ids[1] == nil then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local entries, missing = PhotoLookup.resolveDistinct(catalog, ids)
    local photos = {}
    for i, entry in ipairs(entries) do photos[i] = entry.photo end
    local selectedCount = #photos

    if selectedCount == 0 then
        return Reply.parts({ not_found = missing })
    end

    -- Yields to the UI thread, so it must stay OUTSIDE withReadAccessDo for the
    -- same reason getTargetPhotos does (#134/#124). First arg becomes active.
    Log.info(string.format("setSelection: selecting %d (missing %d)", selectedCount, #missing))
    catalog:setSelectedPhotos(photos[1], photos)

    -- Lightroom ignores photos outside the current view source and leaves the
    -- old selection in place, reporting nothing. Read the selection back so a
    -- caller is never told a selection happened that did not.
    local requested = {}
    for _, photo in ipairs(photos) do
        requested[photo] = true
    end
    local actualCount = 0
    for _, photo in ipairs(catalog:getTargetPhotos() or {}) do
        if requested[photo] then
            actualCount = actualCount + 1
        end
    end

    if actualCount < selectedCount then
        context:warn(string.format(
            "Lightroom selected %d of %d photos: the rest are not in the current view source. "
            .. "Switch Lightroom to a source that contains them, such as All Photographs.",
            actualCount, selectedCount))
    end
    return Reply.parts({
        data = {
            selected = actualCount,
            requested = selectedCount,
            active_photo_id = tostring(photos[1].localIdentifier),
        },
        not_found = #missing > 0 and missing or nil,
    })
end

return SelectionHandler
