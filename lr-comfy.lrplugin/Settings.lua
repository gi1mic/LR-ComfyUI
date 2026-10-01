local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"
local LrHttp = import "LrHttp"

local prefs = LrPrefs.prefsForPlugin()

if not prefs.serverURL then
    prefs.serverURL = "http://localhost:8188"
end

local function showDialog()
    local f = LrView.osFactory()
    local c = f:column {
        bind_to_object = prefs,
        f:static_text {
            title = "ComfyUI Configuration",
            font = "<system/bold>"
        },
        f:separator { fill_horizontal = 1 },
        f:static_text {
            title = "Server Configuration",
            font = "<system/bold>"
        },
        f:row {
            f:static_text { title = "Server URL:" },
            f:edit_field {
                value = LrView.bind("serverURL"),
                width_in_chars = 30,
                placeholder = "https://example.com:8188"
            }
        },
        f:separator { fill_horizontal = 1 },
        f:static_text { title = "API Authentication" },
        f:row {
            f:static_text { title = "API Key:" },
            f:edit_field {
                value = LrView.bind("apiKey"),
                width_in_chars = 100,
                placeholder = "your-api-key-here"
            }
        },
        f:separator { fill_horizontal = 1 },
        f:static_text {
            title = "Feature Settings",
            font = "<system/bold>"
        },
        f:separator { fill_horizontal = 1 },
        f:row {
            f:push_button {
                title = "Test Connection",
                action = function()
                    if prefs.serverURL and prefs.serverURL ~= "" then
                        LrTasks.startAsyncTask(function()
                            local body, errorCode = LrHttp.get(prefs.serverURL)
                            if body ~= nil then
                                LrDialogs.message("Connection Test", "Successfully connected to server at " .. prefs.serverURL, "info")
                            else
                                LrDialogs.message("Connection Test", "Failed to connect to server.\nError Code: " .. tostring(errorCode), "warning")
                            end
                        end)
                    else
                        LrDialogs.message("Connection Test", "Please enter a server URL first.", "warning")
                    end
                end
            },
            f:push_button {
                title = "Save Settings",
                action = function()
                    LrDialogs.message("Settings Saved", "Configuration has been saved successfully.", "info")
                end
            }
        }
    }

    LrDialogs.presentModalDialog {
        title = "ComfyUI Settings",
        contents = c
    }
end

-- Set default API key if none exists
if not prefs.apiKey then
    prefs.apiKey = ""
end

showDialog()
