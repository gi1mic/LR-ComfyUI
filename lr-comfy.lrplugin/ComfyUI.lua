local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local ExternalAPI = require "ExternalAPI"
local SharedLogic = require "SharedLogic"

local function readWorkflows()
    local workflows = {}
    local directory = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), "workflowsProcess")

    for path in LrFileUtils.directoryEntries(directory) do
        local filename = LrPathUtils.leafName(path)
        if filename:lower():match("%.json$") then
            local file = io.open(path, "r")
            if file then
                local content = file:read("*all")
                file:close()
                local workflowName = content:match('"workflow_name"%s*:%s*"([^"]+)"')
                table.insert(workflows, {
                    name = workflowName or filename:gsub("%.json$", ""),
                    path = path
                })
            end
        end
    end

    table.sort(workflows, function(left, right)
        return left.name:lower() < right.name:lower()
    end)
    return workflows
end

local function chooseWorkflow(functionContext, workflows)
    if #workflows == 0 then
        LrDialogs.message("ComfyUI", "No JSON workflows were found in the workflows folder.", "warning")
        return nil
    end

    local properties = LrBinding.makePropertyTable(functionContext)
    properties.workflow = 1
    properties.useRendered = true
    local factory = LrView.osFactory()
    local menuItems = {}
    for index, workflow in ipairs(workflows) do
        table.insert(menuItems, { title = workflow.name, value = index })
    end

    local result = LrDialogs.presentModalDialog({
        title = "Select a ComfyUI Workflow",
        contents = factory:column {
            bind_to_object = properties,
            spacing = factory:control_spacing(),
            factory:static_text { title = "Workflow" },
            factory:popup_menu {
                value = LrView.bind("workflow"),
                items = menuItems
            },
            factory:checkbox {
                title = "Use Lightroom-rendered image",
                value = LrView.bind("useRendered")
            }
        },
        actionVerb = "Process"
    })

    if result ~= "ok" then
        return nil
    end
    return workflows[properties.workflow], properties.useRendered
end

LrTasks.startAsyncTask(function()
    local selectedWorkflow
    local useRendered
    LrFunctionContext.callWithContext("Select ComfyUI Workflow", function(functionContext)
        selectedWorkflow, useRendered = chooseWorkflow(functionContext, readWorkflows())
    end)

    if selectedWorkflow then
        local connected, connectionMessage = ExternalAPI.testConnection()

        if not connected then
            local message = tostring(connectionMessage or connected)
            LrDialogs.message("ComfyUI Not Available", message, "warning")
        else
            local message = SharedLogic.processSelectedPhotos(selectedWorkflow.path, useRendered)
            if message ~= "" then
                LrDialogs.message("ComfyUI", message, "info")
            end
        end
    end
end)
