local LrHttp = import "LrHttp"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local json = dofile(LrPathUtils.child(_PLUGIN.path, "DkJson.lua"))
local prefs = LrPrefs.prefsForPlugin()

local function urlEncode(value)
    return tostring(value):gsub("[^%w%-_%.~]", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function serverUrl(path)
    return (prefs.serverURL or "http://127.0.0.1:8188"):gsub("/$", "") .. path
end

local function isCloudServer()
    return (prefs.serverURL or ""):lower():match("cloud%.comfy%.org") ~= nil
end

local function cloudBaseUrl()
    return (prefs.serverURL or "https://cloud.comfy.org"):gsub("/api/?$", ""):gsub("/$", "")
end

local function apiUrl(path)
    if isCloudServer() then
        return cloudBaseUrl() .. "/api" .. path
    end
    return serverUrl(path)
end

local function cloudJobUrl(jobId)
    return cloudBaseUrl() .. "/api/v2/jobs" .. (jobId and ("/" .. urlEncode(jobId)) or "")
end

local function shouldContinueWaiting(jobId)
    local result = LrDialogs.confirm(
        "ComfyUI is still processing request " .. jobId .. ". Continue waiting, or cancel this Lightroom request? The ComfyUI job may continue on the server.",
        "ComfyUI Timeout",
        "Continue Waiting",
        "Cancel Request"
    )
    return result == "ok"
end

local function requestHeaders()
    local apiKey = prefs.apiKey
    if not apiKey or apiKey == "" then
        apiKey = prefs.api_key
    end
    if not apiKey or apiKey == "" then
        return nil
    end
    return {
        { field = "Authorization", value = "Bearer " .. apiKey }
    }
end

local function readFile(path, mode)
    local file, errorMessage = io.open(path, mode or "rb")
    if not file then
        error("Could not read " .. path .. ": " .. tostring(errorMessage))
    end
    local contents = file:read("*all")
    file:close()
    if not contents then
        error("Could not read " .. path)
    end
    return contents
end

local function extractText(value, depth)
    if depth > 4 then
        return nil
    end
    if type(value) == "string" then
        return value ~= "" and value or nil
    end
    if type(value) ~= "table" then
        return nil
    end

    for i, key in ipairs({ "text", "string", "texts", "value", "output" }) do
        local text = extractText(value[key], depth + 1)
        if text then
            return text
        end
    end

    for _, item in pairs(value) do
        local text = extractText(item, depth + 1)
        if text then
            return text
        end
    end

    return nil
end

local function extractCloudImage(value, depth)
    if depth > 6 or type(value) ~= "table" then
        return nil
    end
    if value.filename then
        return value
    end
    if value.url or value.uri then
        return { url = value.url or value.uri }
    end
    for _, item in pairs(value) do
        local image = extractCloudImage(item, depth + 1)
        if image then
            return image
        end
    end
    return nil
end

local function testConnection()
    local response, errorMessage = LrHttp.get(apiUrl("/system_stats"), requestHeaders())
    if not response or response == "" then
        local message = "Could not connect to ComfyUI at " .. apiUrl("")
        if errorMessage then
            message = message .. ": " .. tostring(errorMessage)
        end
        return false, message
    end

    local result = json.decode(response)
    if not result then
        local message = "ComfyUI responded with invalid data from /system_stats: %s" .. tostring(response)
        return false, message
    end

    return true
end

local function uploadImage(path)
    local filename = LrPathUtils.leafName(path)
    local boundary = "----LightroomComfyUI" .. tostring(os.time())
    local headers = requestHeaders() or {}
    table.insert(headers, 1, { field = "Content-Type", value = "multipart/form-data; boundary=" .. boundary })
    local body = "--" .. boundary .. "\r\n"
        .. "Content-Disposition: form-data; name=\"image\"; filename=\"" .. filename .. "\"\r\n"
        .. "Content-Type: application/octet-stream\r\n\r\n"
        .. readFile(path)
        .. "\r\n--" .. boundary .. "--\r\n"
    local response, errorMessage = LrHttp.post(apiUrl("/upload/image"), body, headers)
    if not response then
        error("ComfyUI image upload failed: " .. tostring(errorMessage))
    end
    local result = json.decode(response)
    if not result or not result.name then
        error("ComfyUI returned an invalid upload response. %s" .. tostring(response))
    end
    return result
end

local function queueJob(job)
    if isCloudServer() then
        local headers = requestHeaders() or {}
        table.insert(headers, 1, { field = "Content-Type", value = "application/json" })
        local response, responseHeaders = LrHttp.post(cloudJobUrl(), json.encode({
            workflow = job.workflow_json
        }), headers)
        if not response then
            error("ComfyUI Cloud job request failed: " .. tostring(responseHeaders))
        end
        local result = json.decode(response)
        local jobId = result and (result.id or result.job_id or result.jobId)
        if not jobId and result and type(result.job) == "table" then
            jobId = result.job.id or result.job.job_id or result.job.jobId
        end
        if not jobId then
            error("ComfyUI Cloud returned no job ID: " .. tostring(response))
        end
        return tostring(jobId), "cloud"
    end

    local headers = requestHeaders() or {}
    table.insert(headers, 1, { field = "Content-Type", value = "application/json" })
    local response, responseHeaders = LrHttp.post(serverUrl("/api/queue"), json.encode(job), headers)
    if not response then
        error("ComfyUI job request failed: " .. tostring(responseHeaders))
    end
    local result = json.decode(response)
    local jobId = result and (result.job_id or result.jobId or result.queue_id or result.queueId
        or result.task_id or result.taskId or result.request_id or result.requestId
        or result.uuid or result.id)
    if not jobId and result then
        local nested = result.job or result.data or result.result
        if type(nested) == "table" then
            jobId = nested.job_id or nested.jobId or nested.queue_id or nested.queueId
                or nested.task_id or nested.taskId or nested.request_id or nested.requestId
                or nested.uuid or nested.id
        end
    end
    if not jobId and type(result) == "string" then
        jobId = result
    end
    if not jobId then
        local location = responseHeaders and (responseHeaders.Location or responseHeaders.location)
        jobId = location and location:match("([^/?]+)$")
    end
    if not jobId and response == "" then
        local promptHeaders = requestHeaders() or {}
        table.insert(promptHeaders, 1, { field = "Content-Type", value = "application/json" })
        local promptResponse, promptError = LrHttp.post(serverUrl("/prompt"), json.encode({
            prompt = job.workflow_json,
            client_id = job.job_id
        }), promptHeaders)
        if not promptResponse then
            error("ComfyUI native /prompt request failed: " .. tostring(promptError))
        end
        local promptResult = json.decode(promptResponse)
        if promptResult and promptResult.prompt_id then
            return tostring(promptResult.prompt_id), "native"
        end
        error("ComfyUI returned no prompt_id from /prompt: " .. tostring(promptResponse))
    end
    if not jobId then
        error("ComfyUI returned no job ID from /api/queue: " .. tostring(response))
    end
    return tostring(jobId), "bridge"
end

local function waitForJob(options)
    local jobId = options.jobId
    local queueMode = options.queueMode
    local returnText = options.returnText == true
    local lastStatus
    local pendingSince

    if queueMode == "cloud" then
        local attemptsSincePrompt = 0
        while true do
            local response, errorMessage = LrHttp.get(cloudJobUrl(jobId), requestHeaders())
            if response and response ~= "" then
                local job = json.decode(response)
                local status = job and job.status
                if type(status) == "table" then
                    status = status.status or status.state or status.status_str
                end
                status = status and tostring(status):lower()
                if status == "failed" or status == "error" or status == "cancelled" then
                    error("ComfyUI Cloud reported an error: " .. tostring(job.error or job.message or response))
                end
                if status == "completed" or status == "succeeded" or status == "success" or status == "finished" then
                    local output = job.outputs or job.output or job.result or job.data or job
                    if returnText then
                        local text = extractText(output, 0)
                        if text then
                            return text
                        end
                    end
                    local image = extractCloudImage(output, 0)
                    if image then
                        return image
                    end
                    error("ComfyUI Cloud completed the job without a usable output: " .. tostring(response))
                end
            elseif errorMessage then
                error("Could not poll ComfyUI Cloud job: " .. tostring(errorMessage))
            end
            LrTasks.sleep(1)
            attemptsSincePrompt = attemptsSincePrompt + 1
            if attemptsSincePrompt >= 600 then
                if not shouldContinueWaiting(jobId) then
                    return nil, "cancelled"
                end
                attemptsSincePrompt = 0
            end
        end
    end

    local attemptsSincePrompt = 0
    while true do
        local statusPath = queueMode == "native"
            and ("/history/" .. urlEncode(jobId))
            or ("/api/queue/" .. urlEncode(jobId))
        if queueMode == "native" then
            local response = LrHttp.get(serverUrl(statusPath), requestHeaders())
            if response and response ~= "" then
                -- Native mode: parse response and return image or text directly
                local job = json.decode(response)
                if job and job[jobId] then
                    local history = job[jobId]
                    if history.status and history.status.status_str == "error" then
                        local messages = history.status.messages
                        error("ComfyUI reported an error while processing the image: " .. tostring(messages))
                    end
                    if returnText and history.outputs then
                        for _, nodeOutput in pairs(history.outputs) do
                            if nodeOutput.text then
                                return extractText(nodeOutput.text, 0)
                            end
                            if nodeOutput.images and nodeOutput.images[1] then
                                return nodeOutput.images[1]
                            end
                        end
                    end
                    -- Check if job is complete and return immediately if so
                    local completed = history.status and (history.status.status_str == "completed" 
                        or history.status.status_str == "finished"
                        or history.status.status_str == "success")
                    
                    -- Always set pendingSince to true on first successful status update in native mode
                    if pendingSince == nil then
                        pendingSince = true
                        lastStatus = history.status.status_str or "completed"
                    end
                    
                    -- Return results if job is complete (regardless of returnText setting)
                    if completed then
                        -- If text output was requested, extract and return it
                        if returnText and history.outputs then
                            for _, nodeOutput in pairs(history.outputs) do
                                if nodeOutput.text then
                                    return extractText(nodeOutput.text, 0)
                                end
                                if nodeOutput.images and nodeOutput.images[1] then
                                    return nodeOutput.images[1]
                                end
                            end
                        end
                        
                        -- If no text output but there are images, return the first image from the history's outputs table
                        -- Check all output nodes for images regardless of returnText setting
                        local hasImageOutput = false
                        for _, nodeOutput in pairs(history.outputs) do
                            if nodeOutput.images and #nodeOutput.images > 0 then
                                hasImageOutput = true
                                break
                            end
                        end
                        
                        -- Return the first image found from any output node
                        if hasImageOutput or #history.outputs > 0 then
                            for _, nodeOutput in pairs(history.outputs) do
                                if nodeOutput.images and #nodeOutput.images > 0 then
                                    return nodeOutput.images[1]
                                end
                            end
                        end
                    end
                end
            end  -- Close "if response" block
        else  -- Non-native mode: poll status from /api/queue/{jobId}
            local response = LrHttp.get(serverUrl(statusPath), requestHeaders())
            if response and response ~= "" then
                local job = json.decode(response)
                if job and job[jobId] then
                    local history = job[jobId]
                    if history.status and history.status.status_str == "error" then
                        local messages = history.status.messages
                        error("ComfyUI reported an error while processing the image: " .. tostring(messages))
                    end
                    if history.status.status_str ~= lastStatus then
                        lastStatus = history.status.status_str
                        if returnText and history.outputs then
                            for _, nodeOutput in pairs(history.outputs) do
                                if nodeOutput.text then
                                    return extractText(nodeOutput.text, 0)
                                end
                                if nodeOutput.images and nodeOutput.images[1] then
                                    return nodeOutput.images[1]
                                end
                            end
                        end
                    end
                end
            end  -- Close "if response" block
        end  -- Close native mode branch "else" block  
        LrTasks.sleep(1)
        attemptsSincePrompt = attemptsSincePrompt + 1
        if attemptsSincePrompt >= 600 then
            if not shouldContinueWaiting(jobId) then
                return nil, "cancelled"
            end
            attemptsSincePrompt = 0
        end
    end
end

local function downloadImage(image)
    if type(image) == "string" then
        image = { url = image }
    end
    if image.url or image.uri then
        local response, errorMessage = LrHttp.get(image.url or image.uri, requestHeaders())
        if not response then
            error("Could not download the ComfyUI result: " .. tostring(errorMessage))
        end
        return response
    end
    local query = "?filename=" .. urlEncode(image.filename)
        .. "&subfolder=" .. urlEncode(image.subfolder or "")
        .. "&type=" .. urlEncode(image.type or "output")
    local response, errorMessage = LrHttp.get(serverUrl("/view" .. query), requestHeaders())
    if not response then
        error("Could not download the ComfyUI result: " .. tostring(errorMessage))
    end
    return response
end

return {
    testConnection = testConnection,
    uploadImage = uploadImage,
    queueJob = queueJob,
    waitForJob = waitForJob,
    downloadImage = downloadImage
}
