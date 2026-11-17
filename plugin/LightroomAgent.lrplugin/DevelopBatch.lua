local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local DevelopBatch = {}

function DevelopBatch.run(context, catalog, operation)
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, operation.inputs)
    local results, failed, unknown, remaining = {}, {}, {}, {}

    local function attempt(entry, state)
        local photoId = tostring(entry.photo.localIdentifier)
        local ok, value, written = context.ledger:attempt(operation.each, entry.photo, state)
        if ok then
            value.photo_id = photoId
            results[#results + 1] = value
            return
        end
        local class, reason = Reply.stopped(value, written)
        local list = class == "failed" and failed or unknown
        list[#list + 1] = { photo_id = photoId, reason = reason }
    end

    if #entries > 0 then
        DevelopSession.run(context, catalog, operation.restoreView, function(state)
            local prepared, attempted = false, 0
            for _, entry in ipairs(entries) do
                if #remaining > 0 or context:stopping(operation.reserveSeconds) then
                    remaining[#remaining + 1] = entry.id
                else
                    context:report(attempted, #entries,
                        entry.photo:getFormattedMetadata("fileName") or tostring(entry.photo.localIdentifier))
                    if operation.prepare and not prepared then
                        operation.prepare(entry.photo, state)
                        prepared = true
                    end
                    attempt(entry, state)
                    attempted = attempted + 1
                end
            end
            if attempted > 0 then context:report(attempted, #entries, "Done") end
        end)
    end

    return Reply.parts({
        data = #results > 0 and { results = results } or nil,
        failed = failed,
        unknown = unknown,
        not_found = notFound,
        remaining = remaining,
    })
end

return DevelopBatch
