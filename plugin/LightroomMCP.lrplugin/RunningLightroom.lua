local LrApplication = import 'LrApplication'

local JsonValue = require 'JsonValue'

local RunningLightroom = {}

function RunningLightroom.describe()
    local version = LrApplication.versionTable()
    local label = tostring(version.major) .. "." .. tostring(version.minor)
    local build
    if version.build ~= nil then
        build = string.format("%s.%s build %s", label, tostring(version.revision or 0), tostring(version.build))
    end
    return { version = label, build = build, version_table = JsonValue.of(version) }
end

return RunningLightroom
