local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local DevelopBatch = {}

local HALT = { __tostring = function(halt) return halt.message end }

function DevelopBatch.halt(message)
    error(setmetatable({ message = message }, HALT), 0)
end

local function haltOf(value)
    if type(value) == "table" and getmetatable(value) == HALT then return value.message end
    return nil
end

function DevelopBatch.run(context, catalog, operation)
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, operation.inputs)
    local results, failed, unknown, remaining = {}, {}, {}, {}

    local function attempt(entry, state)
        local photoId = tostring(entry.photo.localIdentifier)
        local ok, value = LrTasks.pcall(operation.each, entry.photo, state)
        if ok then
            value.photo_id = photoId
            results[#results + 1] = value
            return true
        end
        local halt = haltOf(value)
        if halt then
            failed[#failed + 1] = { photo_id = photoId, reason = halt }
            context:warn(halt)
            return false
        end
        local item = { photo_id = photoId, reason = Reply.messageOf(value) }
        if Reply.refusalOf(value) then
            failed[#failed + 1] = item
        else
            unknown[#unknown + 1] = item
        end
        return true
    end

    if #entries > 0 then
        DevelopSession.run(context, catalog, operation.restoreView, function(state)
            local prepared, going, attempted = false, true, 0
            for _, entry in ipairs(entries) do
                if not going or context:stopping(operation.reserveSeconds) then
                    remaining[#remaining + 1] = entry.id
                else
                    context:report(attempted, #entries,
                        entry.photo:getFormattedMetadata("fileName") or tostring(entry.photo.localIdentifier))
                    if operation.prepare and not prepared then
                        operation.prepare(entry.photo, state)
                        prepared = true
                    end
                    going = attempt(entry, state)
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
