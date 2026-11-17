local LrPathUtils = import 'LrPathUtils'

local PluginFiles = {}

function PluginFiles.directory()
    return LrPathUtils.child(LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), ".config"), "lightroom-agent")
end

function PluginFiles.token()
    return LrPathUtils.child(PluginFiles.directory(), "token")
end

function PluginFiles.maskCertification()
    return LrPathUtils.child(PluginFiles.directory(), "mask-certification.json")
end

return PluginFiles
