import AppKit
import Foundation
import SwiftUI

/// One video waiting in the batch queue, with the factor it was added at.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let info: VideoInfo
    let scale: Scale
    /// Why the last batch could not upscale it. A failed video stays in the queue, and the
    /// next Go tries it again.
    var failure: String?
}

@MainActor
final class AppModel: ObservableObject {
    enum Mode: Hashable, CaseIterable {
        case single, batch

        var label: String {
            switch self {
            case .single: return "Single Upscale Mode"
            case .batch: return "Batch Upscale Mode"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case notice(String)
        case cancelled
        case downloading(String, Double)
        case working(String, Double?)
        /// The saved file, and how long the upscaling took.
        case finished(URL, TimeInterval)
        /// A batch ran to its end: how many videos were upscaled and failed, how long it took,
        /// and the last file saved.
        case batchFinished(done: Int, failed: Int, took: TimeInterval, last: URL?)
        case failed(String)
    }

    /// Every launch starts in single mode; the queue is kept while the app runs, in both modes.
    @Published var mode: Mode = .single
    @Published private(set) var queue: [QueueItem] = []
    /// True from Go until the batch ends or is stopped.
    @Published private(set) var isBatchRunning = false
    /// The queue item being upscaled now.
    @Published private(set) var runningItemID: UUID?

    @Published private(set) var videoURL: URL?
    @Published private(set) var videoInfo: VideoInfo?
    /// Every launch starts at ×2; the choice is not remembered.
    @Published var scale: Scale = .x2
    @Published private(set) var modelsFolder: URL?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var missingModels: [ModelFile] = []
    /// When the running upscale started (after any model downloads), for the elapsed time.
    @Published private(set) var upscaleStartedAt: Date?
    let engineReady = EngineLocation.bundled.isReady

    private let defaults = UserDefaults.standard
    private let engine = ComfyEngine(location: .bundled)
    private var jobTask: Task<Void, Never>?
    /// The running job. Progress from any other (finished) job is ignored, so a late update
    /// can never overwrite the final state.
    private var jobID: UUID?
    private var videoCheck: UUID?
    private var idleStopTask: Task<Void, Never>?

    /// The engine stays loaded this long after a job, so the next job starts quickly.
    private static let engineIdleSeconds: UInt64 = 300

    private enum Keys {
        static let modelsFolder = "modelsFolder"
    }

    init() {
        modelsFolder = defaults.string(forKey: Keys.modelsFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }

        // Clear what an earlier run may have left after a crash or a quit mid-job:
        // engine processes first, then the work files they were using.
        ComfyEngine.killOrphans(location: .bundled)
        AppPaths.cleanWorkFolders()
        if let folder = modelsFolder {
            for file in allModelFiles { ModelDownloader.removeLeftoverJoin(of: file, in: folder) }
        }
        refreshMissingModels()

        // Runs synchronously on the main thread before the app exits, so the engine is
        // stopped (and not left running) when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
    }

    // MARK: - Derived state

    var isBusy: Bool {
        switch phase {
        case .downloading, .working: return true
        default: return false
        }
    }

    var canUpscale: Bool { videoInfo != nil && modelsFolder != nil && engineReady && !isBusy }

    /// Videos can be added to the queue at any time, also while a batch runs.
    var canAddToQueue: Bool { videoInfo != nil }

    var canStartBatch: Bool { !queue.isEmpty && modelsFolder != nil && engineReady && !isBusy }

    /// The video and factor can be changed when nothing runs, and during a batch (to queue more).
    var canEditSelection: Bool { !isBusy || isBatchRunning }

    /// Progress (0…1) of the video being upscaled now, once known.
    var currentFraction: Double? {
        if case .working(_, let fraction) = phase { return fraction }
        return nil
    }

    /// Every model file. One set serves every factor.
    private var allModelFiles: [ModelFile] { ReCaVSRModels.all }

    // MARK: - Selection

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            setVideo(url)
        }
    }

    /// Accepts the file only if macOS can read it as a video.
    func setVideo(_ url: URL) {
        guard canEditSelection else { return }
        let check = UUID()
        videoCheck = check
        Task {
            do {
                let info = try await VideoInfo.load(url)
                guard videoCheck == check else { return }
                videoURL = url
                videoInfo = info
                // During a batch the status area shows its progress; leave it.
                if !isBusy { phase = .idle }
            } catch {
                guard videoCheck == check else { return }
                if isBusy {
                    NSSound.beep()
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where the ReCaVSR models are stored"
        panel.message = "Pick a ComfyUI models folder (the one holding recavsr), or an empty folder for the downloads."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        let (folder, note) = normalizedModelsFolder(picked)
        modelsFolder = folder
        defaults.set(folder.path, forKey: Keys.modelsFolder)
        refreshMissingModels()
        phase = note.map { .notice($0) } ?? .idle
    }

    /// ComfyUI needs the files in `recavsr/` under the chosen folder. Common mistakes are
    /// corrected here, so they don't trigger a 6.5 GB download.
    private func normalizedModelsFolder(_ url: URL) -> (URL, String?) {
        let fm = FileManager.default
        let sub = ReCaVSRModels.folder
        func hasLayout(_ folder: URL) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent(sub).path)
        }
        let name = url.lastPathComponent
        if name == sub {
            let parent = url.deletingLastPathComponent()
            return (parent, "Using “\(parent.lastPathComponent)”, the folder that holds \(sub).")
        }
        let nested = url.appendingPathComponent("models", isDirectory: true)
        if !hasLayout(url) && hasLayout(nested) {
            return (nested, "Using the models folder inside “\(name)”.")
        }
        if allModelFiles.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0.name).path) }) {
            return (url, "Model files sit directly in this folder. They must be in its \(sub) subfolder; move them there to avoid downloading them again.")
        }
        return (url, nil)
    }

    func refreshMissingModels() {
        guard let folder = modelsFolder else {
            missingModels = allModelFiles
            return
        }
        missingModels = allModelFiles.filter { !$0.isPresent(in: folder) }
    }

    // MARK: - Actions

    func downloadModels() {
        guard !isBusy, let folder = modelsFolder else { return }
        let id = beginJob()
        jobTask = Task { [self] in
            do {
                try await ensureModels(in: folder, job: id)
                endJob(id, .idle)
            } catch is CancellationError {
                endJob(id, .cancelled)
            } catch {
                endJob(id, .failed(error.localizedDescription))
            }
        }
    }

    func startUpscale() {
        guard canUpscale, let video = videoURL, let info = videoInfo, let folder = modelsFolder else { return }
        let chosenScale = scale
        let id = beginJob()

        jobTask = Task { [self] in
            do {
                try await ensureModels(in: folder, job: id)
                let started = Date()
                upscaleStartedAt = started
                let output = try await Upscaler.run(input: video, info: info, scale: chosenScale,
                                                    modelsFolder: folder, engine: engine) { [weak self] text, fraction in
                    Task { @MainActor in self?.update(id, .working(text, fraction)) }
                }
                endJob(id, .finished(output, Date().timeIntervalSince(started)))
            } catch is CancellationError {
                endJob(id, .cancelled)
            } catch {
                endJob(id, .failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        jobTask?.cancel()
    }

    // MARK: - Batch queue

    /// Adds the video in the video box, at the chosen factor, to the end of the queue.
    func addToQueue() {
        guard let url = videoURL, let info = videoInfo else { return }
        queue.append(QueueItem(url: url, info: info, scale: scale))
        if !isBusy { phase = .idle }
    }

    /// The running video can't be removed; Stop ends the batch instead.
    func removeFromQueue(_ id: UUID) {
        guard id != runningItemID else { return }
        queue.removeAll { $0.id == id }
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    /// Upscales the queue from the top, each video at its own factor. A finished video leaves
    /// the queue; one that fails stays, marked, and the batch goes on with the next. The queue
    /// can change while it runs: each next video is the first one this batch hasn't tried yet.
    func startBatch() {
        guard canStartBatch, let folder = modelsFolder else { return }
        for index in queue.indices { queue[index].failure = nil }
        let id = beginJob()
        isBatchRunning = true

        jobTask = Task { [self] in
            let started = Date()
            var tried = Set<UUID>()
            var done = 0, failed = 0
            var last: URL?
            do {
                try await ensureModels(in: folder, job: id)
                while let item = queue.first(where: { !tried.contains($0.id) }) {
                    try Task.checkCancellation()
                    let total = tried.count + queue.filter { !tried.contains($0.id) }.count
                    let prefix = "\(tried.count + 1) of \(total) · "
                    tried.insert(item.id)
                    runningItemID = item.id
                    upscaleStartedAt = Date()
                    update(id, .working(prefix + "Starting…", nil))
                    do {
                        let output = try await Upscaler.run(input: item.url, info: item.info, scale: item.scale,
                                                            modelsFolder: folder, engine: engine) { [weak self] text, fraction in
                            Task { @MainActor in self?.update(id, .working(prefix + text, fraction)) }
                        }
                        queue.removeAll { $0.id == item.id }
                        done += 1
                        last = output
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        failed += 1
                        if let index = queue.firstIndex(where: { $0.id == item.id }) {
                            queue[index].failure = error.localizedDescription
                        }
                    }
                    runningItemID = nil
                }
                endJob(id, .batchFinished(done: done, failed: failed, took: Date().timeIntervalSince(started), last: last))
            } catch is CancellationError {
                endJob(id, .cancelled)
            } catch {
                endJob(id, .failed(error.localizedDescription))
            }
        }
    }

    /// Cancels a running job and stops the engine when the app quits.
    func shutDown() {
        jobTask?.cancel()
        idleStopTask?.cancel()
        engine.stop()
    }

    // MARK: - Jobs

    private func beginJob() -> UUID {
        idleStopTask?.cancel()
        let id = UUID()
        jobID = id
        return id
    }

    private func update(_ id: UUID, _ newPhase: Phase) {
        guard jobID == id else { return }
        phase = newPhase
    }

    private func endJob(_ id: UUID, _ finalPhase: Phase) {
        guard jobID == id else { return }
        jobID = nil
        upscaleStartedAt = nil
        isBatchRunning = false
        runningItemID = nil
        phase = finalPhase
        refreshMissingModels()
        scheduleIdleStop()
    }

    /// Stops the engine after a few idle minutes, to give its memory back.
    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        guard engine.isRunning else { return }
        let engine = self.engine
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.engineIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled, self?.jobID == nil else { return }
            await Task.detached { engine.stop() }.value
        }
    }

    private func ensureModels(in folder: URL, job id: UUID) async throws {
        for file in allModelFiles where !file.isPresent(in: folder) {
            let name = file.name
            update(id, .downloading(name, 0))
            try await ModelDownloader.download(file, into: folder) { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .progress(let fraction):
                        self?.update(id, .downloading(name, fraction))
                    case .joining:
                        self?.update(id, .working("Joining and checking \(name)…", nil))
                    }
                }
            }
        }
    }
}
