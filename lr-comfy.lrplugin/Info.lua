-- Info.lua - Plugin Metadata Template
return {
    LrSdkVersion = 10.0,

    LrToolkitIdentifier = "com.gi1mic.lrcomfy",

    -- Display name for plugin
    LrPluginName = "LR-Comfy",

    VERSION = {
        major = 1,
        minor = 0,
        revision = 0
    },

    LrExportMenuItems = {
        {
            title = "Image Process",
            file = "ComfyUI.lua"
        }, {
            title = "Image Caption",
            file = "Caption.lua"
        }, {
            title = "Settings",
            file = "Settings.lua"
        }
    },

    LrLibraryMenuItems = {
        {
            title = "Image Process",
            file = "ComfyUI.lua"
        }, {
            title = "Image Caption",
            file = "Caption.lua"
        }, {
            title = "Settings",
            file = "Settings.lua"
        }
    }
}