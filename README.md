# LR-Comfy

LR-Comfy is a Lightroom Classic plug-in for sending selected photos to ComfyUI for processing with an AI workflow.

## USE

The plugin makes available two types of AI processing tasks:

- **Image Process** runs a workflow to process an image and import the newly generated image back into into lightroom.
- **Image Caption** runs a workflow that saves text from the workflow into the Caption field of the selected image.


## Warning

- Take a catalog backup before testing new workflows.
- This plugin comes with no warranty at all.
- Please read the instructions before using it.
- This plugin has been developed and tested on Lightroom Classic 13 running on Windows 11. It may not work with other versions or operative systems. (The program has a dependency on exiftool.exe but there is a cross platform Perl version of exiftool)
- The plugin has been tested with a local ComfyUI Desktop implementation. Code has been added to support comfy cloud servers but this has not been tested as the free comfyui cloud accounts dont allow API access.


## Examples

This section shows example images demonstrating LR-Comfy's (**i.e. comfy's**) capabilities:

| Original | Pencil Sketch | Photo Restore | Colour Colorize |
|----------|---------------|---------------|-----------------|
| ![1915.jpg](pics/1915.jpg) | ![Pencil Sketch](pics/1915-pencil.jpg) | ![Photo Restore](pics/1915-photo-restore.jpg) | ![Colour Colorize](pics/1915-sketch.jpg) |

**Images overview:**

- `1915.jpg` - The original photo
- `1915-pencil.jpg` - Created with `image_to_pencil_sketch.json` workflow
- `1915-photo-restore.jpg` - Created with `PhotoRestore_Colorize.json` workflow
- `1915-sketch.jpg` - Created with `image_to_sketch.json` workflow

 Caption workflows save text to the Lightroom Caption field without creating new images. The provided workflow generates the caption 'A black and white photo of a group of soldiers' when run against the 1915.jpg photo.

 Remember you can create your own image processing workflows just as long as they are API compatible. You can also modify the provided workfows to create very different results by just by changing the text prompts embedded within them.

 You should keep in mind that AI's have a tendency to make stuff up when they get confused i.e. images can change in very unexpected ways (a moustache may disappear because the AI thought it was a shadow or someone sticking their tongue out may end up with a very distorted mouth because the AI has not seen that type of expression before). Faces can also be changed in subtle ways making them look similar but different to people who know them well; more like a brother or sister of the person rather than the actual person. 


## Requirements

- Lightroom Classic with plug-in support.
- A reachable ComfyUI server with developer/API access enabled.
- ComfyUI API-format workflows with a `LoadImage` node.
- The custom nodes as required depending on the workflows you use.


## Installation

### Comfy Desktop (not required if you are using cloud services)
Install comfy desktop `https://comfy.org/` and enable developer mode in the setting page (this enables local network API support). 

I recommend openning the provided JSON workflows using comfy desktop to verify there are no missing dependencies. 

### Plugin
Install this plugin like any other Lightroom Classic plugin

1. Download or clone the git repository
2. Keep `lr-comfy.lrplugin`, `workflowsProcess`, and `workflowsCaption` together.
3. In Lightroom Classic, open **File > Plug-in Manager**.
4. Select **Add**, choose `lr-comfy.lrplugin`, and enable it.
5. Open **Settings** from the plug-in menu and enter the ComfyUI server URL and API key if required.

The default URL is `http://localhost:8188` for a comfyui desktop installation running on the local machine.


## Image Process

1. Select one or more photos in the Library module.
2. Choose **Library > Plug-in Extras > Image Process**. The same command is available under **File > Plug-in Extras**.
3. Choose a workflow from `workflowsProcess`.
4. The plug-in uploads each image, waits for ComfyUI to process it then downloads the result, and adds it beside the original before copying the capture date to the newly processed image. 

The plugin uses the original filename with a `-comfyui` extension to ensure existing files are not overwritten; a auto incrementing numeric suffix is added if necessary. The processed image receives the source photo's Lightroom keywords plus a top-level keyword in the form `Comfy-<workflow filename>` so processed files can be identifed later.

Each processed image is added to the same folder as its original and placed above it in a Lightroom stack.

Raw files with the extensions ARW, CR2, CR3, DNG, NEF, ORF, RAF, and RW2 are rendered to JPEG before processing. When selecting a workflow, enable **Use Lightroom-rendered image** to apply Lightroom's current develop settings to any source photo before it is uploaded. This option is available for both processing and captioning.

Images sent to comfy are limited/downscaled to 2000x2000 pixels in code. This was done to reduce processing overhead in comfy. You can use an upscaler workflow to increase the resolution of a processed image but this will require a lot of memory.

## Image Caption

1. Select one or more photos in the Library module.
2. Choose **Library > Plug-in Extras > Image Caption**.
3. Choose a workflow from `workflowsCaption`.
4. The plug-in uploads each photo, waits for a text result, and writes that text to the source photo's Lightroom Metadata Caption field.

Caption workflows must expose their result through a text output node. The included `workflowsCaption/image2caption.json` uses the third party `ApiTextOutputNode` which can be found at https://github.com/AabhasTech/ComfyUI_Fast_Preview.

No new image is created for captioning.

## Long-running requests

If a ComfyUI job is still running after 10 minutes, the plug-in offers **Continue Waiting** or **Cancel Request**. Choosing to continue keeps waiting, and the prompt appears again every 10 minutes. Canceling stops the current Lightroom batch, but does not cancel the job on the ComfyUI server; it may continue running there.

## Workflows

Export workflows from ComfyUI in **API format**, not the regular UI workflow format. The plug-in changes the first `LoadImage` node to use the uploaded filename.

The files in both workflow folders are examples. Check their custom-node requirements by loading them manually into ComfyUI before running them via the plugin. When creating or editing a workflow, export the updated API version into the appropriate folder.

Note the provided workflows leave copies of images in the comfy input and output directories which are under `%AppData%\Local\Comfy-Desktop\ComfyUI-Shared` on MS windows. You will need to manually delete these once in a while!!!

## Metadata

The plug-in currently copies Lightroom keywords to processed images and writes caption results to the selected photos' Caption field. It does not copy EXIF/IPTC data, or XMP sidecars.

## Troubleshooting

- Use **Settings > Test Connection** to check the server URL.
- Make sure photos are selected before starting either action.
- Confirm the workflow contains a `LoadImage` node and is exported in API format.
- For captions, confirm the workflow has a text output node.
- Check the ComfyUI console for missing custom nodes, workflow errors, or memory errors.

## Third party tools

This plugin uses the very useful [ExifTool](lr-comfy.lrdevplugin/README.txt)

## Repository layout

```text
lr-comfy.lrdevplugin/   Lightroom Classic plug-in
workflowsProcess/       Image-processing workflows
workflowsCaption/       Caption workflows
lightroom-comfyui.md    Development notes
```
