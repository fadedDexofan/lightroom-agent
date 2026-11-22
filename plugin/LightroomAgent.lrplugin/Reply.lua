local Reply = {}

local PARTS = {}
local REFUSAL = { __tostring = function(refusal) return refusal.message end }
local NOT_FOUND = { __tostring = function(missing) return "Photo not found: " .. tostring(missing.input) end }

local LISTS = { "failed", "unknown", "not_found", "remaining" }

function Reply.parts(parts)
    for _, key in ipairs(LISTS) do
        if parts[key] ~= nil and #parts[key] == 0 then parts[key] = nil end
    end
    return setmetatable(parts, PARTS)
end

function Reply.isParts(value) return type(value) == "table" and getmetatable(value) == PARTS end

function Reply.refuse(message, cause) error(setmetatable({ message = message, cause = cause }, REFUSAL), 0) end

local function refusalOf(value)
    if type(value) == "table" and getmetatable(value) == REFUSAL then return value.message end
    return nil
end

function Reply.causeOf(value)
    if type(value) == "table" and getmetatable(value) == REFUSAL then return value.cause end
    return nil
end

function Reply.notFound(input) error(setmetatable({ input = input }, NOT_FOUND), 0) end

function Reply.notFoundOf(value)
    if type(value) == "table" and getmetatable(value) == NOT_FOUND then return value.input end
    return nil
end

function Reply.messageOf(value)
    local refusal = refusalOf(value)
    if refusal then return refusal end
    if Reply.notFoundOf(value) ~= nil then return tostring(value) end
    local message = tostring(value)
    local chunkDetail = message:match('^%[string "[^"\r\n]-%.lua"%]:%d+: (.*)$')
    if chunkDetail then return chunkDetail end
    local source, detail = message:match("^([^\r\n]-%.lua):%d+: (.*)$")
    if
        source
        and (
            source:match("^%S+%.lua$")
            or source:match("^[/\\]")
            or source:match("^%a:[/\\]")
            or source:match("^%.%.%.")
        )
    then
        return detail
    end
    return message
end

function Reply.stopped(value, written)
    local reason = Reply.messageOf(value)
    if #written == 0 then return "failed", reason end
    return "unknown", reason .. "; written before this stopped: " .. table.concat(written, ", ")
end

function Reply.outcome(ok, value, context)
    local written = context.ledger:live()
    local missing = Reply.notFoundOf(value)
    if not ok and missing ~= nil and #written == 0 then
        ok, value = true, Reply.parts({ not_found = { missing } })
    end
    if ok then
        local parts = Reply.isParts(value) and value or { data = value }
        if parts.data == nil and parts.unknown == nil and #written > 0 then parts.written = written end
        if #context.warnings > 0 then
            parts.warnings = parts.warnings or {}
            for _, warning in ipairs(context.warnings) do
                parts.warnings[#parts.warnings + 1] = warning
            end
        end
        return { result = parts }
    end
    local class, message = Reply.stopped(value, written)
    if #context.warnings > 0 then message = message .. " Warnings: " .. table.concat(context.warnings, "; ") end
    return { error = message, effect = class == "failed" and "none" or "unknown" }
end

return Reply
