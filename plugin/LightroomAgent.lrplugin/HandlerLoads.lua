local HandlerLoads = {}

local first = {}

function HandlerLoads.resolve(module)
    local record = first[module]
    if record == nil then
        local loaded, value = pcall(require, module)
        record = { loaded = loaded, value = loaded and value or ("Could not load " .. module .. ": " .. tostring(value)) }
        first[module] = record
    end
    if not record.loaded then error(record.value, 0) end
    return record.value
end

function HandlerLoads.loadAll(dispatch)
    local problems, seen = {}, {}
    for _, target in pairs(dispatch) do
        local module = target[1]
        if not seen[module] then
            seen[module] = true
            local loaded, problem = pcall(HandlerLoads.resolve, module)
            if not loaded then problems[#problems + 1] = problem end
        end
    end
    table.sort(problems)
    return problems
end

return HandlerLoads
