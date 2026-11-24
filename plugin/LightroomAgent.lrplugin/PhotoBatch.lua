local LrTasks = import "LrTasks"

local PhotoLookup = require "PhotoLookup"
local Reply = require "Reply"

local PhotoBatch = {}

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
            for index, input in ipairs(inputs) do
                refusals[photo][index] = listed .. "; this is " .. input
            end
        end
    end
    return refusals
end

local function captionsOf(catalog, entries)
    local photos = {}
    for index, entry in ipairs(entries) do
        photos[index] = entry.photo
    end
    local read, formatted = LrTasks.pcall(
        function() return catalog:batchGetFormattedMetadata(photos, { "fileName" }) end
    )
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

function PhotoBatch.run(context, catalog, operation)
    local entries, notFound, resolved = PhotoLookup.resolveDistinct(catalog, operation.inputs)
    for index, entry in ipairs(resolved) do
        entry.index = index
    end
    local batch = { results = {}, failed = {}, unknown = {}, not_found = notFound, remaining = {} }
    if #entries == 0 then return batch end
    local listedTwice = operation.duplicates == "refuse" and aliasesOf(resolved) or {}
    local title = operation.progress

    local function attempt(entry)
        local photoId = tostring(entry.photo.localIdentifier)
        local ok, value, written = context.ledger:attempt(operation.each, entry.photo, entry)
        if ok then
            value.photo_id = photoId
            batch.results[#batch.results + 1] = value
            return
        end
        local class, reason = Reply.stopped(value, written)
        local list = class == "failed" and batch.failed or batch.unknown
        list[#list + 1] = { photo_id = photoId, reason = reason }
    end

    local function loop()
        local captions = title and captionsOf(catalog, entries)
        local started, stopped = 0, false
        for _, entry in ipairs(entries) do
            local photoId = tostring(entry.photo.localIdentifier)
            local held = not listedTwice[entry.photo] and operation.held and operation.held(entry)
            if listedTwice[entry.photo] then
                for _, reason in ipairs(listedTwice[entry.photo]) do
                    batch.failed[#batch.failed + 1] = { photo_id = photoId, reason = reason }
                end
            elseif held and held.remaining then
                batch.remaining[#batch.remaining + 1] = entry.id
            elseif held then
                batch.failed[#batch.failed + 1] = { photo_id = photoId, reason = held.reason }
            elseif stopped or context:stopping(reserveFor(operation, started)) then
                stopped = true
                batch.remaining[#batch.remaining + 1] = entry.id
            else
                if title then context:report(started, #entries, captions[entry.photo], title) end
                if operation.prepare and started == 0 then operation.prepare(entry.photo) end
                attempt(entry)
                started = started + 1
            end
        end
        if title and started > 0 then context:report(started, #entries, "Done", title) end
        return batch.results
    end

    if operation.around then
        operation.around(loop)
    else
        loop()
    end

    if operation.confirm then
        local verdict = operation.confirm(batch.results)
        batch.results = verdict.confirmed
        for _, item in ipairs(verdict.failed or {}) do
            batch.failed[#batch.failed + 1] = item
        end
        for _, item in ipairs(verdict.unknown or {}) do
            batch.unknown[#batch.unknown + 1] = item
        end
        batch.report = verdict.report
    end
    return batch
end

function PhotoBatch.reply(batch, dataOf, own)
    local data = #batch.results > 0 and dataOf(batch.results) or nil
    local warnings, problem = nil, own and own.problem
    if batch.report then
        local report = batch.report(data)
        data, warnings = report.data, report.warnings
        if report.problem then problem = problem and problem .. "; " .. report.problem or report.problem end
    end
    return Reply.parts({
        data = data,
        failed = batch.failed,
        unknown = batch.unknown,
        not_found = batch.not_found,
        remaining = batch.remaining,
        warnings = warnings,
        problem = problem,
    })
end

return PhotoBatch
