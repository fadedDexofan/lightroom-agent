local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'
local Reply = require 'Reply'

local DevelopBatch = {}

local function aliasesOf(resolved)
    local inputsOf, refusals = {}, {}
    for _, entry in ipairs(resolved) do
        if entry.photo then
            inputsOf[entry.photo] = inputsOf[entry.photo] or {}
            local inputs = inputsOf[entry.photo]
            inputs[#inputs + 1] = tostring(entry.id)
        end
    end
    for photo, inputs in pairs(inputsOf) do
        if #inputs > 1 then
            local listed = "listed twice, as " .. table.concat(inputs, " and ")
            refusals[photo] = {}
            for index, input in ipairs(inputs) do refusals[photo][index] = listed .. "; this is " .. input end
        end
    end
    return refusals
end

local function captionsOf(catalog, entries)
    local photos = {}
    for index, entry in ipairs(entries) do photos[index] = entry.photo end
    local read, formatted = LrTasks.pcall(function() return catalog:batchGetFormattedMetadata(photos, { "fileName" }) end)
    local captions = {}
    for _, photo in ipairs(photos) do
        local name = read and formatted and formatted[photo] and formatted[photo].fileName
        captions[photo] = name or tostring(photo.localIdentifier)
    end
    return captions
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


    local finished
    if #entries > 0 then
        DevelopSession.run(context, catalog, operation.restoreView, function(state)
            local prepared, attempted, stopped = false, 0, false
            local captions = captionsOf(catalog, entries)
            for _, entry in ipairs(entries) do
                local photoId = tostring(entry.photo.localIdentifier)
                local held = not listedTwice[entry.photo] and operation.held and operation.held(entry)
                if listedTwice[entry.photo] then
                    for _, reason in ipairs(listedTwice[entry.photo]) do failed[#failed + 1] = { photo_id = photoId, reason = reason } end
                elseif held and held.remaining then
                    remaining[#remaining + 1] = entry.id
                elseif held then
                    failed[#failed + 1] = { photo_id = photoId, reason = held.reason }
                elseif stopped or context:stopping(reserveFor(operation, attempted)) then
                    stopped = true
                    remaining[#remaining + 1] = entry.id
                else
                    context:report(attempted, #entries, captions[entry.photo])
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
