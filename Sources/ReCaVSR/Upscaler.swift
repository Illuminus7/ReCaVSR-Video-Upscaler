import Foundation

/// Runs one upscale job end to end and returns the finished file's URL.
///
/// ReCaVSR streams the video through itself a block at a time, so the whole video is one
/// ComfyUI run whatever its length. The upscaled video is then saved, with the original audio,
/// as "<name> upscaled.mp4" next to the original.
enum Upscaler {
    static func run(input: URL,
                    info: VideoInfo,
                    scale: Scale,
                    modelsFolder: URL,
                    engine: ComfyEngine,
                    report: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let ext = input.pathExtension.lowercased()

        // The engine reads only from its input folder. A hard link avoids copying gigabytes;
        // a copy is the fallback when the video is on another volume. Removed when the job ends,
        // and at the next launch if the app quits before that.
        try fm.createDirectory(at: AppPaths.input, withIntermediateDirectories: true)
        let inputName = "recavsr-\(token).\(ext.isEmpty ? "mp4" : ext)"
        let linkedInput = AppPaths.input.appendingPathComponent(inputName)
        do {
            try fm.linkItem(at: input, to: linkedInput)
        } catch {
            report("Preparing the video…", nil)
            try fm.copyItem(at: input, to: linkedInput)
        }
        defer { try? fm.removeItem(at: linkedInput) }

        report("Starting engine…", nil)
        try await engine.start(modelsFolder: modelsFolder)
        let clientID = UUID().uuidString
        let prefix = "recavsr-\(token)"
        let graph = ReCaVSRWorkflow.graph(inputFileName: inputName, scale: scale, outputPrefix: prefix)

        let client = ComfyClient(baseURL: engine.baseURL)
        let monitor = ProgressMonitor(baseURL: engine.baseURL, clientID: clientID)
        defer { monitor.close() }
        // ReCaVSR encodes the upscaled video into the engine's temp folder (ComfyUI adds "temp"
        // to the folder it is given) as it goes; Save Video then copies it to the output folder.
        // Both copies go when the job ends.
        defer { try? fm.removeItem(at: AppPaths.temp.appendingPathComponent("temp/recavsr", isDirectory: true)) }
        let promptID = try await client.queue(graph, clientID: clientID)

        // Progress counts from the first block, so the estimate leaves out loading the models.
        var firstBlockAt: Date?
        var firstBlockFraction = 0.0
        let upscaled: URL
        do {
            upscaled = try await waitForOutput(client: client, engine: engine, promptID: promptID,
                                               prefix: prefix, scale: scale, info: info) {
                guard let blocks = monitor.fraction(promptID: promptID, node: ReCaVSRWorkflow.upscaleNode) else {
                    report("Loading ReCaVSR…", nil)
                    return
                }
                if firstBlockAt == nil {
                    firstBlockAt = Date()
                    firstBlockFraction = blocks
                }
                // The last 2% is saving the file.
                let fraction = blocks * 0.98
                report(progressText(scale: scale, blocks: blocks, from: firstBlockFraction, since: firstBlockAt!),
                       fraction)
            }
        } catch is CancellationError {
            await client.interrupt()
            throw CancellationError()
        }
        defer { try? fm.removeItem(at: upscaled) }

        report("Saving…", 0.98)
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let destination = uniqueDestination(in: folder, baseName: "\(base) upscaled", ext: "mp4")
        do {
            try await VideoAssembler.assemble(upscaled: upscaled, source: input, info: info, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        report("Done", 1)
        return destination
    }

    /// "Upscaling ×2 — about 12 min left". The estimate appears once a fifth of the blocks are
    /// done, when it has settled.
    private static func progressText(scale: Scale, blocks: Double, from start: Double, since date: Date) -> String {
        let text = "Upscaling ×\(scale.rawValue)"
        let done = blocks - start
        guard blocks >= 0.2, done > 0 else { return text + "…" }
        let elapsed = Date().timeIntervalSince(date)
        return text + " — " + formatRemaining(elapsed * (1 - blocks) / done)
    }

    private static func formatRemaining(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "about a minute left" }
        if minutes < 90 { return "about \(minutes) min left" }
        return String(format: "about %.1f h left", seconds / 3600)
    }

    /// Polls the history until the prompt finishes, then returns the saved video's path.
    private static func waitForOutput(client: ComfyClient, engine: ComfyEngine,
                                      promptID: String, prefix: String,
                                      scale: Scale, info: VideoInfo,
                                      tick: () -> Void) async throws -> URL {
        while true {
            try Task.checkCancellation()
            tick()
            // An engine that died mid-run was almost always stopped by macOS for using too much memory.
            guard engine.isRunning else { throw outOfMemory(info: info, scale: scale, engine: engine) }
            let entry: [String: Any]?
            do {
                entry = try await client.history(for: promptID)
            } catch {
                if !engine.isRunning { throw outOfMemory(info: info, scale: scale, engine: engine) }
                throw error
            }
            if let entry, let status = entry["status"] as? [String: Any] {
                if (status["status_str"] as? String) == "error" {
                    throw explain(describeError(entry), info: info, scale: scale)
                }
                if (status["completed"] as? Bool) == true {
                    return try locateOutput(in: entry, prefix: prefix)
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func outOfMemory(info: VideoInfo, scale: Scale, engine: ComfyEngine) -> AppError {
        engine.stoppedError("The engine stopped during the upscale, most likely because a \(info.width)×\(info.height) "
                            + "video at ×\(scale.rawValue) needs more memory than this Mac has free. "
                            + "Close other apps, or try ×2 or a smaller video.")
    }

    /// Turns ReCaVSR's own size check, which speaks of a graphics card's VRAM, into Mac terms.
    private static func explain(_ detail: String, info: VideoInfo, scale: Scale) -> AppError {
        if detail.contains("needs about") && detail.contains("VRAM") {
            return AppError("A \(info.width)×\(info.height) video is too large for this Mac's memory at ×\(scale.rawValue). "
                            + (scale == .x4 ? "Try ×2, or a smaller video." : "Try a smaller video."))
        }
        if detail.localizedCaseInsensitiveContains("out of memory") {
            return AppError("This Mac ran out of memory upscaling a \(info.width)×\(info.height) video at ×\(scale.rawValue). "
                            + "Close other apps, or try ×2 or a smaller video.")
        }
        return AppError("The upscale failed inside ComfyUI. \(detail)")
    }

    private static func locateOutput(in entry: [String: Any], prefix: String) throws -> URL {
        let outputs = entry["outputs"] as? [String: Any] ?? [:]
        for (_, nodeOutput) in outputs {
            guard let fields = nodeOutput as? [String: Any] else { continue }
            for (_, value) in fields {
                guard let items = value as? [[String: Any]] else { continue }
                for item in items {
                    // LoadVideo also echoes its input; only "output" items count.
                    guard (item["type"] as? String) == "output",
                          let filename = item["filename"] as? String, filename.hasPrefix(prefix) else { continue }
                    let subfolder = item["subfolder"] as? String ?? ""
                    var url = AppPaths.output
                    if !subfolder.isEmpty {
                        url = url.appendingPathComponent(subfolder, isDirectory: true)
                    }
                    url = url.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        throw AppError("ComfyUI finished, but the upscaled video was not found in the output folder.")
    }

    private static func describeError(_ entry: [String: Any]) -> String {
        let status = entry["status"] as? [String: Any] ?? [:]
        let messages = status["messages"] as? [[Any]] ?? []
        for message in messages {
            if message.count > 1, let payload = message[1] as? [String: Any],
               let text = payload["exception_message"] as? String {
                let node = (payload["node_type"] as? String).map { "(\($0)) " } ?? ""
                return node + text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// "<base>.<ext>" if free, otherwise "<base> 2.<ext>", "<base> 3.<ext>", and so on.
    private static func uniqueDestination(in folder: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
