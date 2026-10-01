local LrApplication = import "LrApplication"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local ExternalAPI = require "ExternalAPI"
local json = dofile(LrPathUtils.child(_PLUGIN.path, "DkJson.lua"))

local function readWorkflow(path)
    local file, errorMessage = io.open(path, "r")
    if not file then
        error("Could not open workflow: " .. tostring(errorMessage))
    end
    local content = file:read("*all")
    file:close()
    local workflow = json.decode(content)
    if not workflow then
        error("Workflow is not valid JSON: " .. path)
    end
    local prompt = workflow.prompt or workflow
    if prompt.steps then
        error("The selected workflow is a description, not a ComfyUI API workflow. Export it from ComfyUI in API format.")
    end
    return prompt
end

local function copyTable(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, nestedValue in pairs(value) do
        copy[key] = copyTable(nestedValue)
    end
    return copy
end

local function setInputImage(prompt, imageName)
    for _, node in pairs(prompt) do
        if node.class_type == "LoadImage" then
            node.inputs = node.inputs or {}
            node.inputs.image = imageName
            return true
        end
    end
    return false
end

local function writeResult(path, contents)
    local file, errorMessage = io.open(path, "wb")
    if not file then
        error("Could not write processed image: " .. tostring(errorMessage))
    end
    local success, writeError = file:write(contents)
    file:close()
    if not success then
        error("Could not write processed image: " .. tostring(writeError))
    end
end

local function quoteCommandPath(path)
    return '"' .. tostring(path):gsub('"', '\\"') .. '"'
end

local function writeArgumentFile(path, arguments)
    local file, errorMessage = io.open(path, "w")
    if not file then
        error("Could not write ExifTool argument file: " .. tostring(errorMessage))
    end
    for _, argument in ipairs(arguments) do
        file:write(argument .. "\n")
    end
    file:close()
end

local function updateImageCaptureTime(sourcePath, destinationPath)
    local executablePath = LrPathUtils.child(_PLUGIN.path, "exiftool.exe")
    local executable = io.open(executablePath, "rb")
    if executable then
        executable:close()
    else
        executablePath = LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "exiftool_files"), "exiftool.exe")
        executable = io.open(executablePath, "rb")
        if executable then
            executable:close()
        else
            error("Could not find ExifTool for image capture-time update.")
        end
    end
    local argumentPath = LrPathUtils.child(_PLUGIN.path, "lr-comfy-capture-time.args")
    writeArgumentFile(argumentPath, {
        "-m",
        "-overwrite_original",
        "-tagsFromFile", sourcePath,
        "-XMP-exif:DateTimeOriginal<DateTimeOriginal",
        "-XMP-photoshop:DateCreated<DateTimeOriginal",
        "-XMP-xmp:CreateDate<DateTimeOriginal",
        "-XMP-xmp:ModifyDate<DateTimeOriginal",
        "-FileModifyDate<DateTimeOriginal",
        destinationPath
    })
    local command = "cmd.exe /d /s /c \""
        .. quoteCommandPath(executablePath)
        .. " -@ " .. quoteCommandPath(argumentPath) .. "\""
    local result = LrTasks.execute(command)
    if result ~= 0 then
        error("Could not update the generated image capture time with ExifTool (exit code " .. tostring(result) .. ").")
    end
end

local function resultPath(sourcePath, outputFilename)
    local base = LrPathUtils.removeExtension(sourcePath) .. "-comfyui"
    local extension = LrPathUtils.extension(outputFilename or "") or LrPathUtils.extension(sourcePath) or "png"
    local path = base .. "." .. extension
    local suffix = 2
    while io.open(path, "rb") do
        path = base .. "-" .. suffix .. "." .. extension
        suffix = suffix + 1
    end
    return path
end

local function collectSelectedPhotos()
    local photos = LrApplication.activeCatalog():getTargetPhotos()
    if not photos or #photos == 0 then
        error("No photos are selected in Lightroom.")
    end
    local selected = {}
    for _, photo in ipairs(photos) do
        local path = photo:getRawMetadata("path")
        if not path or path == "" then
            error("Could not read a file path for a selected photo.")
        end
        table.insert(selected, { photo = photo, path = path })
    end
    return selected
end

local rawExtensions = {
    arw = true,
    cr2 = true,
    cr3 = true,
    dng = true,
    nef = true,
    orf = true,
    raf = true,
    rw2 = true
}

local function isRawPath(path)
    return rawExtensions[(LrPathUtils.extension(path) or ""):lower()] == true
end

local function renderPhoto(photo, index)
    local temporaryDirectory = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("temp"),
        "lightroom-comfyui"
    )
    LrFileUtils.createDirectory(temporaryDirectory)
    local exportSession = LrExportSession {
        photosToExport = { photo },
        exportSettings = {
            LR_export_destinationType = "specificFolder",
            LR_export_destinationPathPrefix = temporaryDirectory,
            LR_export_useSubfolder = false,
            LR_format = "JPEG",
            LR_jpeg_quality = 0.9,
            LR_jpeg_useLimit = false,
            LR_size_doConstrain = true,
            LR_size_maxHeight = 2000,
            LR_size_maxWidth = 2000,
            LR_size_megapixels = 2,
            LR_size_resizeType = "wh",
            LR_collisionHandling = "overwrite"
        }
    }

    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if not success then
            error("Could not render the photo for ComfyUI: " .. tostring(pathOrMessage))
        end
        local renderedPath = pathOrMessage
        if not renderedPath or renderedPath == "" then
            error("Lightroom rendered the photo without returning a file path.")
        end
        return renderedPath
    end
    error("Lightroom did not produce a rendered JPEG for selected photo " .. tostring(index) .. ".")
end

local function findKeyword(keywords, name)
    for _, keyword in ipairs(keywords or {}) do
        if keyword:getName() == name then
            return keyword
        end
    end
    return nil
end

local function ensureKeyword(catalog, keyword)
    local sourceParent = keyword:getParent()
    local targetParent
    if sourceParent then
        targetParent = ensureKeyword(catalog, sourceParent)
    end

    local siblings = targetParent and targetParent:getChildren() or catalog:getKeywords()
    local existing = findKeyword(siblings, keyword:getName())
    if existing then
        return existing
    end

    return catalog:createKeyword(
        keyword:getName(),
        keyword:getSynonyms(),
        keyword:getIncludeOnExport(),
        targetParent
    )
end

local function photoHasKeyword(keyword, photo)
    for _, keywordPhoto in ipairs(keyword:getPhotos() or {}) do
        if keywordPhoto == photo then
            return true
        end
    end
    return false
end

local function collectPhotoKeywords(keywords, photo, result)
    for _, keyword in ipairs(keywords or {}) do
        if photoHasKeyword(keyword, photo) then
            table.insert(result, keyword)
        end
        collectPhotoKeywords(keyword:getChildren(), photo, result)
    end
end

local function copyKeywords(catalog, sourcePhoto, targetPhoto)
    local keywords = {}
    collectPhotoKeywords(catalog:getKeywords(), sourcePhoto, keywords)
    for _, keyword in ipairs(keywords) do
        targetPhoto:addKeyword(ensureKeyword(catalog, keyword))
    end
end

local function addWorkflowKeyword(catalog, targetPhoto, workflowPath)
    local workflowKeywordName = "Comfy-" .. LrPathUtils.leafName(workflowPath)
    local workflowKeyword = findKeyword(catalog:getKeywords(), workflowKeywordName)
    if not workflowKeyword then
        workflowKeyword = catalog:createKeyword(workflowKeywordName, {}, true, nil)
    end
    targetPhoto:addKeyword(workflowKeyword)
end

local function processSelectedPhotos(workflowPath, useRendered)
    local sourcePaths = collectSelectedPhotos()
    local promptTemplate = readWorkflow(workflowPath)
    local catalog = LrApplication.activeCatalog()
    local progress = LrProgressScope({ title = "Processing images with ComfyUI" })
    local imported = 0
    local cancelled = false

    for index, selectedPhoto in ipairs(sourcePaths) do
        if progress:isCanceled() then
            break
        end
        progress:setCaption("Processing image " .. index .. " of " .. #sourcePaths)
        progress:setPortionComplete(index - 1, #sourcePaths)
        local sourcePath = selectedPhoto.path

        local renderedPath
        do
            local inputPath = sourcePath
            if useRendered or isRawPath(sourcePath) then
                renderedPath = renderPhoto(selectedPhoto.photo, index)
                inputPath = renderedPath
            end

            local upload = ExternalAPI.uploadImage(inputPath)
            local prompt = copyTable(promptTemplate)
            if not setInputImage(prompt, upload.name) then
                error("The selected workflow does not contain a LoadImage node.")
            end
            local job = {
                job_id = tostring(os.time()) .. "-" .. tostring(index),
                workflow_json = prompt,
                source_files = {
                    {
                        path = sourcePath,
                        file_name = LrPathUtils.leafName(sourcePath),
                        original_ext = LrPathUtils.extension(sourcePath) or "",
                        uploaded_name = upload.name
                    }
                },
                workflow_params = {
                    input_image = upload.name
                }
            }
            local jobId, queueMode = ExternalAPI.queueJob(job)
            local output = ExternalAPI.waitForJob({ jobId = jobId, queueMode = queueMode })
            if output then
                local result = ExternalAPI.downloadImage(output)
                local destination = resultPath(sourcePath, output.filename)
                writeResult(destination, result)
                updateImageCaptureTime(sourcePath, destination)

                catalog:withWriteAccessDo("Add ComfyUI result", function()
                    local targetPhoto = catalog:addPhoto(destination, selectedPhoto.photo, "above")
                    if targetPhoto then
                        copyKeywords(catalog, selectedPhoto.photo, targetPhoto)
                        addWorkflowKeyword(catalog, targetPhoto, workflowPath)
                    end
                end)
            else
                cancelled = true
            end
        end
        if renderedPath then
            LrFileUtils.delete(renderedPath)
        end
        if cancelled then
            break
        end
        imported = imported + 1
    end

    progress:setPortionComplete(#sourcePaths, #sourcePaths)
    progress:done()
    if cancelled then
        return "ComfyUI request cancelled."
    end
    return ""
    -- return "Processed " .. imported .. " of " .. #sourcePaths .. " selected image(s)."
end

local function processCaptionPhotos(workflowPath, useRendered)
    local sourcePaths = collectSelectedPhotos()
    local promptTemplate = readWorkflow(workflowPath)
    local catalog = LrApplication.activeCatalog()
    local progress = LrProgressScope({ title = "Generating captions with ComfyUI" })
    local captioned = 0
    local cancelled = false

    for index, selectedPhoto in ipairs(sourcePaths) do
        if progress:isCanceled() then
            break
        end
        progress:setCaption("Captioning image " .. index .. " of " .. #sourcePaths)
        progress:setPortionComplete(index - 1, #sourcePaths)

        local sourcePath = selectedPhoto.path
        local renderedPath
        do
            local inputPath = sourcePath
            if useRendered or isRawPath(inputPath) then
                renderedPath = renderPhoto(selectedPhoto.photo, index)
                inputPath = renderedPath
            end

            local upload = ExternalAPI.uploadImage(inputPath)
            local prompt = copyTable(promptTemplate)
            if not setInputImage(prompt, upload.name) then
                error("The selected caption workflow does not contain a LoadImage node.")
            end
            local job = {
                job_id = tostring(os.time()) .. "-caption-" .. tostring(index),
                workflow_json = prompt,
                source_files = {
                    {
                        path = selectedPhoto.path,
                        file_name = LrPathUtils.leafName(selectedPhoto.path),
                        original_ext = LrPathUtils.extension(selectedPhoto.path) or "",
                        uploaded_name = upload.name
                    }
                },
                workflow_params = { input_image = upload.name }
            }
            local jobId, queueMode = ExternalAPI.queueJob(job)
            local caption = ExternalAPI.waitForJob {
                jobId = jobId,
                queueMode = queueMode,
                returnText = true
            }
            if caption then
                catalog:withWriteAccessDo("Save ComfyUI caption", function()
                    selectedPhoto.photo:setRawMetadata("caption", caption)
                end)
            else
                cancelled = true
            end
        end
        if renderedPath then
            LrFileUtils.delete(renderedPath)
        end
        if cancelled then
            break
        end
        captioned = captioned + 1
    end

    progress:setPortionComplete(#sourcePaths, #sourcePaths)
    progress:done()
    if cancelled then
        return "ComfyUI request cancelled."
    end
    return ""
    -- return "Saved captions for " .. captioned .. " of " .. #sourcePaths .. " selected image(s)."
end

return {
    processSelectedPhotos = processSelectedPhotos,
    processCaptionPhotos = processCaptionPhotos,
    collectSelectedPhotos = collectSelectedPhotos
}
