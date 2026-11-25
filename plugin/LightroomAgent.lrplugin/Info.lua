return {
    LrSdkVersion = 15.0,
    LrSdkMinimumVersion = 15.0,

    LrToolkitIdentifier = "io.github.fadeddexofan.lightroomagent",
    LrPluginName = "Lightroom Agent",

    LrPluginInfoUrl = "https://github.com/fadedDexofan/lightroom-agent",

    VERSION = { major = 0, minor = 2, revision = 1, build = 0 },

    LrPluginInfoProvider = "PluginInfoProvider.lua",
    LrInitPlugin = "PluginInit.lua",
    LrMetadataProvider = "AiMetadataDefinition.lua",
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item — see LrLibraryMenuItems
    -- below. Adobe's own remote_control_socket sample uses this pattern.
    LrForceInitPlugin = true,
    LrShutdownPlugin = "PluginShutdown.lua",
    LrShutdownApp = "PluginShutdown.lua",

    LrLibraryMenuItems = {
        {
            title = "Lightroom Agent — Show Status",
            file = "MenuShowStatus.lua",
        },
    },
}
