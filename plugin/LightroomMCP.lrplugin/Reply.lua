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

function Reply.isParts(value)
    return type(value) == "table" and getmetatable(value) == PARTS
end

function Reply.refuse(message)
    error(setmetatable({ message = message }, REFUSAL), 0)
end

function Reply.refusalOf(value)
    if type(value) == "table" and getmetatable(value) == REFUSAL then return value.message end
    return nil
end

function Reply.notFound(input)
    error(setmetatable({ input = input }, NOT_FOUND), 0)
end

function Reply.notFoundOf(value)
    if type(value) == "table" and getmetatable(value) == NOT_FOUND then return value.input end
    return nil
end

function Reply.messageOf(value)
    local refusal = Reply.refusalOf(value)
    if refusal then return refusal end
    if Reply.notFoundOf(value) ~= nil then return tostring(value) end
    local message = tostring(value)
    local chunkDetail = message:match('^%[string "[^"\r\n]-%.lua"%]:%d+: (.*)$')
    if chunkDetail then return chunkDetail end
    local source, detail = message:match("^([^\r\n]-%.lua):%d+: (.*)$")
    if source and (source:match("^%S+%.lua$") or source:match("^[/\\]")
        or source:match("^%a:[/\\]") or source:match("^%.%.%.")) then
        return detail
    end
    return message
end

return Reply
