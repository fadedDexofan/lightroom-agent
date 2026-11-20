local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local DevelopBatch = {}

local function aliasesOf(resolved)
    local inputsOf, refusedAs = {}, {}
    for _, entry in ipairs(resolved) do
        if entry.photo then
            inputsOf[entry.photo] = inputsOf[entry.photo] or {}
            local inputs = inputsOf[entry.photo]
            inputs[#inputs + 1] = tostring(entry.id)
        end
    end
    for photo, inputs in pairs(inputsOf) do
        if #inputs > 1 then refusedAs[photo] = "listed twice, as " .. table.concat(inputs, " and ") end
    end
    return refusedAs
end

local function reserveFor(operation, started)
    if type(operation.reserveSeconds) == "function" then return operation.reserveSeconds(started) end
    return operation.reserveSeconds
end

function DevelopBatch.run(context, catalog, operation)
    local entries, notFound, resolved = PhotoLookup.resolveDistinct(catalog, operation.inputs)
    for index, entry in ipairs(resolved) do entry.index = index end
    local results, failed, unknown, remaining = {}, {}, {}, {}
    local listedTwice = operation.duplicates == "refuse" and aliasesOf(resolved) or {}

    local function attempt(entry, state)
        local photoId = tostring(entry.photo.localIdentifier)
        local ok, value, written = context.ledger:attempt(operation.each, entry.photo, state, entry)
        if ok then
            value.photo_id = photoId
            results[#results + 1] = value
            return
        end
        local class, reason = Reply.stopped(value, written)
        local list = class == "failed" and failed or unknown
        list[#list + 1] = { photo_id = photoId, reason = reason }
    end

    local function refusalOf(entry)
        return listedTwice[entry.photo] or (operation.refusal and operation.refusal(entry))
    end

    local finished
    if #entries > 0 then
        DevelopSession.run(context, catalog, operation.restoreView, function(state)
            local prepared, attempted = false, 0
            for _, entry in ipairs(entries) do
                local refusal = refusalOf(entry)
                if refusal then
                    failed[#failed + 1] = { photo_id = tostring(entry.photo.localIdentifier), reason = refusal }
                elseif #remaining > 0 or context:stopping(reserveFor(operation, attempted)) then
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
            if operation.finish then finished = operation.finish(results) end
        end)
    end

    local data = #results > 0 and { results = results } or nil
    local warnings, problem
    if finished then
        data = finished.data
        warnings = finished.warnings
        problem = finished.problem
        for _, item in ipairs(finished.failed or {}) do failed[#failed + 1] = item end
        for _, item in ipairs(finished.unknown or {}) do unknown[#unknown + 1] = item end
    end
    return Reply.parts({
        data = data,
        failed = failed,
        unknown = unknown,
        not_found = notFound,
        remaining = remaining,
        warnings = warnings,
        problem = problem,
    })
end

return DevelopBatch
