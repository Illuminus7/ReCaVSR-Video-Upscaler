**Download `ReCaVSR-1.2.0.dmg`**, open it and drag ReCaVSR to Applications.

**What's new in 1.2.0**
- Batch Upscale Mode, next to the Single Upscale Mode you know. In batch mode a queue opens beside the window: add videos with their own factor (×2, ×3 or ×4), drag to reorder, remove with ×, and press Go. Each finished video leaves the queue; Stop ends the batch and keeps what is left. Videos can be added while a batch runs.
- A video that fails stays in the queue with the reason, and the batch goes on with the next; Go tries it again.
- The queue is kept when you switch back to single mode, where Upscale always uses the video in the video box.

**New in 1.1.0**
- A ×3 upscale, between ×2 and ×4.
- Clearer advice when a video doesn't fit in memory: at ×3 or ×4 the app suggests a lower factor; when a video is too big even at ×2, it points to [RelayVSR Video Upscaler](https://github.com/Illuminus7/RelayVSR-Video-Upscaler), which upscales in parts that fit in memory. The message no longer suggests ×2 to a job that already ran at ×2.

**Features**
- Upscales MP4, MOV and M4V video ×2, ×3 or ×4 with ReCaVSR, one at a time or as a batch queue, a one-step streaming video super-resolution model. The result is saved next to the original as `<name> upscaled.mp4`, with the original audio, rotation and colours.
- Streams the video a block at a time, so long videos cost time and disk, not memory.
- Downloads the ReCaVSR models (about 6.5 GB: the int8 transformer, the FlashDecoder and the prompt) to a folder you choose, in four parallel resumable parts, checked by SHA-256. An existing ComfyUI models folder with a `recavsr` folder works as-is.
- Shows progress in percent and time elapsed, plus an estimate of the time left.
- Everything runs inside the app; no ComfyUI installation is needed.

**Requirements:** Apple Silicon Mac, macOS 14 or later. 32 GB of memory or more is recommended for HD video.

**First launch:** the app is not notarized by Apple, so macOS blocks it the first time. Open it once, then go to System Settings ▸ Privacy & Security and click **Open Anyway**.

SHA-256 of the DMG: `2cbe218c0c04f778664df5edb8e27894f3a34c0e83341cd678ecba6e8fe077f9`
