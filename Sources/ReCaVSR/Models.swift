import Foundation

/// Upscale factor. ReCaVSR uses one model for every factor; it was trained for ×4, and its
/// reference also documents ×2.
enum Scale: Int, CaseIterable, Identifiable {
    case x2 = 2
    case x4 = 4

    var id: Int { rawValue }
    var label: String { "×\(rawValue)" }
}

/// The ReCaVSR files, laid out the way the ReCaVSR nodes expect them: all three in the
/// `recavsr` folder of a ComfyUI models folder.
///
/// - The transformer is the int8 ConvRot conversion from PedroMarinhoDev/ReCaVSR-ComfyUI
///   (6.3 GB instead of the 10.6 GB bf16 release, and faster on Apple Silicon with int8-Fast).
/// - The prompt embedding and the FlashDecoder are kopper/ReCaVSR's own release files.
enum ReCaVSRModels {
    static let folder = "recavsr"

    static let transformer = ModelFile(
        name: "transformer_int8_convrot.safetensors",
        remote: "https://huggingface.co/PedroMarinhoDev/ReCaVSR-ComfyUI/resolve/main/recavsr/transformer_int8_convrot.safetensors",
        knownSize: 6_266_935_048,
        knownSHA256: "70f77ac653a29dcab8cb8d5f5300acf27d9a3a45e9baf273fa4526fa43f66c9d")

    static let prompt = ModelFile(
        name: "prompt.safetensors",
        remote: "https://huggingface.co/kopper/ReCaVSR/resolve/main/prompt.safetensors",
        knownSize: 4_194_392,
        knownSHA256: "325ee3b5ec7d8bd43bc7ab186be5272dec0877c04e7c01a46fd0893260c9c6a5")

    static let flashDecoder = ModelFile(
        name: "flashdecoder.safetensors",
        remote: "https://huggingface.co/kopper/ReCaVSR/resolve/main/flashdecoder.safetensors",
        knownSize: 228_723_776,
        knownSHA256: "f4feb3e7b0b65f98e15bb709a1ba28dfaada7c06bf7fc0ce4cdbcb58803034e8")

    /// Every file the app needs, smallest first, so a quick download proves the connection.
    static let all = [prompt, flashDecoder, transformer]
}

/// One model file and where it comes from on Hugging Face.
///
/// `knownSize` and `knownSHA256` are the published values when this app was built. A download
/// is checked against the hash Hugging Face reports at download time, and falls back to these.
struct ModelFile: Hashable {
    let name: String
    let remote: String
    let knownSize: Int64
    let knownSHA256: String

    var folder: String { ReCaVSRModels.folder }
    var relativePath: String { "\(folder)/\(name)" }
    var remoteURL: URL { URL(string: remote)! }
    var approxSizeGB: Double { Double(knownSize) / 1_000_000_000 }

    func localURL(in modelsFolder: URL) -> URL {
        modelsFolder.appendingPathComponent(relativePath)
    }

    /// True when the file is in the folder and is not obviously truncated. The bound is loose
    /// (90%) so that a newer upstream version of the file is still accepted.
    func isPresent(in modelsFolder: URL) -> Bool {
        let path = localURL(in: modelsFolder).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else {
            return false
        }
        return size >= knownSize * 9 / 10
    }
}
