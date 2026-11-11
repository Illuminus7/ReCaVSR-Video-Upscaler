import Foundation

/// The ReCaVSR graph for a whole video, in ComfyUI's API format. It is the ComfyUI-ReCaVSR
/// example workflow with the scale set:
///
///   LoadVideo ─────────────────┐
///   ReCaVSRLoader (int8) ──> ReCaVSRUpscale (FlashDecoder) ──> SaveVideo
///
/// ReCaVSR streams: it reads the video a block at a time (21 frames, then 8) and encodes each
/// upscaled block as soon as it is decoded, so a long video costs disk, not memory, and the
/// whole video is one run. The original audio is added again afterwards, untouched.
enum ReCaVSRWorkflow {
    /// The node whose progress bar counts the blocks done.
    static let upscaleNode = "4"

    static func graph(inputFileName: String, scale: Scale, outputPrefix: String) -> [String: Any] {
        [
            "1": node("LoadVideo", [
                "file": inputFileName,
            ]),
            "3": node("ReCaVSRLoader", [
                "transformer": ReCaVSRModels.transformer.name,
            ]),
            upscaleNode: node("ReCaVSRUpscale", [
                "model": link("3", 0),
                "video": link("1", 0),
                "scale": Double(scale.rawValue),
                "color_fix": "none",
                "seed": 42,
                "decoder": "flashdecoder",
                "kernels": "fast",
                "kv_offload": false,
                "encoder": "h264",
            ]),
            "6": node("SaveVideo", [
                "video": link(upscaleNode, 0),
                "filename_prefix": outputPrefix,
                // MP4, copying ReCaVSR's H.264 stream as it is.
                "format": "auto",
            ]),
        ]
    }

    private static func node(_ classType: String, _ inputs: [String: Any]) -> [String: Any] {
        ["class_type": classType, "inputs": inputs]
    }

    private static func link(_ nodeID: String, _ output: Int) -> [Any] {
        [nodeID, output]
    }
}
