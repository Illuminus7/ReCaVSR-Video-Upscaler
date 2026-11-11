**Download `ReCaVSR-1.0.0.dmg`**, open it and drag ReCaVSR to Applications.

**Features**
- Upscales MP4, MOV and M4V video ×2 or ×4 with ReCaVSR, a one-step streaming video super-resolution model. The result is saved next to the original as `<name> upscaled.mp4`, with the original audio, rotation and colours.
- Streams the video a block at a time, so long videos cost time and disk, not memory.
- Downloads the ReCaVSR models (about 6.5 GB: the int8 transformer, the FlashDecoder and the prompt) to a folder you choose, in four parallel resumable parts, checked by SHA-256. An existing ComfyUI models folder with a `recavsr` folder works as-is.
- Shows progress in percent and time elapsed, plus an estimate of the time left.
- Everything runs inside the app; no ComfyUI installation is needed.

**Requirements:** Apple Silicon Mac, macOS 14 or later. 32 GB of memory or more is recommended for HD video.

**First launch:** the app is not notarized by Apple, so macOS blocks it the first time. Open it once, then go to System Settings ▸ Privacy & Security and click **Open Anyway**.

SHA-256 of the DMG: `df56e279dba6c32c4ca923197aed558764b0944c4c65352ffb149199d3856b45`
