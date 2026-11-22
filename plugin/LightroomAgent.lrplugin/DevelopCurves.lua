local Contract = require "Contract"

local DevelopCurves = {}

local EXTENDED = {}
for _, key in ipairs(Contract.DEVELOP_KEYS) do
    if key.extended then EXTENDED[key.name] = key.extended end
end

function DevelopCurves.isCompanion(name)
    for _, extended in pairs(EXTENDED) do
        if extended == name then return true end
    end
    return false
end

function DevelopCurves.read(settings, key)
    local extended = EXTENDED[key]
    if extended and settings[extended] ~= nil then return settings[extended] end
    return settings[key]
end

function DevelopCurves.forWrite(settings)
    local written = {}
    for key, value in pairs(settings) do
        written[key] = value
    end
    for key, extended in pairs(EXTENDED) do
        local value = DevelopCurves.read(settings, key)
        if value ~= nil then
            written[key] = value
            written[extended] = value
        end
    end
    return written
end

return DevelopCurves
