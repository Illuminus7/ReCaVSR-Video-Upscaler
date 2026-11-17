**Download `ReCaVSR-1.1.0.dmg`**, open it and drag ReCaVSR to Applications.

**What's new in 1.1.0**
- A ×3 upscale, between ×2 and ×4.
- Clearer advice when a video doesn't fit in memory: at ×3 or ×4 the app suggests a lower factor; when a video is too big even at ×2, it points to [RelayVSR Video Upscaler](https://github.com/Illuminus7/RelayVSR-Video-Upscaler), which upscales in parts that fit in memory. The message no longer suggests ×2 to a job that already ran at ×2.

**Features**
- Upscales MP4, MOV and M4V video ×2, ×3 or ×4 with ReCaVSR, a one-step streaming video super-resolution model. The result is saved next to the original as `<name> upscaled.mp4`, with the original audio, rotation and colours.
- Streams the video a block at a time, so long videos cost time and disk, not memory.
- Downloads the ReCaVSR models (about 6.5 GB: the int8 transformer, the FlashDecoder and the prompt) to a folder you choose, in four parallel resumable parts, checked by SHA-256. An existing ComfyUI models folder with a `recavsr` folder works as-is.
- Shows progress in percent and time elapsed, plus an estimate of the time left.
- Everything runs inside the app; no ComfyUI installation is needed.

**Requirements:** Apple Silicon Mac, macOS 14 or later. 32 GB of memory or more is recommended for HD video.

**First launch:** the app is not notarized by Apple, so macOS blocks it the first time. Open it once, then go to System Settings ▸ Privacy & Security and click **Open Anyway**.

SHA-256 of the DMG: `799cb5a03f92ef34ceba774c43a435b0c4cf79eeca09819272212c7694acb8b3`
