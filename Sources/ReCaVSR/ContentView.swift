import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false
    /// Height of the main column, which the queue panel matches in batch mode.
    @State private var mainHeight: CGFloat = 0

    /// Warm coral, for highlights on the dark red background.
    private let accent = Color(red: 1.0, green: 0.56, blue: 0.50)
    /// Crimson, for the Upscale button.
    private let crimson = Color(red: 0.82, green: 0.12, blue: 0.22)
    /// Bright red, for the queue's Go button.
    private let goRed = Color(red: 0.90, green: 0.10, blue: 0.13)

    private static let queueWidth: CGFloat = 360

    var body: some View {
        // The window takes the content's own size. In batch mode the queue panel is added on
        // the right, as tall as the main column, so the window only grows wider. The gradient
        // is a background, so it never adds space of its own.
        HStack(alignment: .top, spacing: 0) {
            mainColumn
            if model.mode == .batch {
                queuePanel
                    .frame(width: Self.queueWidth, height: max(mainHeight - 48, 200))
                    .padding(.vertical, 24)
                    .padding(.trailing, 24)
            }
        }
        .fixedSize()
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.03, blue: 0.05),
                                    Color(red: 0.10, green: 0.015, blue: 0.025),
                                    Color(red: 0.045, green: 0.008, blue: 0.012)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .background(FixedWindow())
    }

    // MARK: - Sections

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            modePicker
            videoCard
            scaleCard
            modelsCard
            actionArea
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MainHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(MainHeightKey.self) { mainHeight = $0 }
    }

    private var header: some View {
        Text("ReCaVSR Video Upscaler")
            .font(.system(size: 28, weight: .bold, design: .rounded))
    }

    /// Single or batch. Locked while a job runs; the queue is kept in both modes.
    private var modePicker: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(AppModel.Mode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        .labelsHidden()
        .disabled(model.isBusy)
    }

    private var videoCard: some View {
        Card(title: "Video") {
            if let url = model.videoURL {
                HStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(videoDetails(url))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Button("Change…") { model.chooseVideo() }
                        .disabled(!model.canEditSelection)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26))
                        .foregroundStyle(dropTargeted ? accent : .white.opacity(0.5))
                    Text("Drop a video here")
                        .font(.headline)
                    Button("Choose Video…") { model.chooseVideo() }
                        .disabled(!model.canEditSelection)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? accent : .clear, lineWidth: 2)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private var scaleCard: some View {
        Card(title: "Upscale factor") {
            Picker("Upscale factor", selection: $model.scale) {
                ForEach(Scale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.canEditSelection)
        }
    }

    private var modelsCard: some View {
        Card(title: "Model files") {
            // Fixed height, so the box stays the same size whether or not the download button shows.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.modelsFolder?.path ?? "No folder chosen")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(model.modelsFolder == nil ? .white.opacity(0.5) : .white)
                    Text(modelStatus)
                        .font(.caption)
                        .foregroundStyle(model.missingModels.isEmpty && model.modelsFolder != nil ? accent : .white.opacity(0.6))
                }
                Spacer()
                VStack(spacing: 6) {
                    if model.modelsFolder != nil && !model.missingModels.isEmpty {
                        Button("Download models") { model.downloadModels() }
                            .buttonStyle(AccentTextButtonStyle(color: accent))
                            .disabled(model.isBusy)
                    }
                    Button("Choose Folder…") { model.chooseModelsFolder() }
                        .disabled(model.isBusy)
                }
                .controlSize(.small)
            }
            .frame(height: 46)
        }
    }

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusView
            HStack(spacing: 12) {
                if model.mode == .batch && !(model.isBusy && !model.isBatchRunning) {
                    // Batch mode: the video and factor go to the queue; Go in the queue starts it.
                    Button { model.addToQueue() } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(crimson)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAddToQueue)
                } else if model.isBusy {
                    Button(role: .cancel) { model.cancel() } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button { model.startUpscale() } label: {
                        Label("Upscale ×\(model.scale.rawValue)", systemImage: "wand.and.stars")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(crimson)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canUpscale || !model.engineReady)
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .idle where model.mode == .batch:
            if !model.engineReady {
                hint("The engine is missing from this app. Rebuild it with the build scripts.")
            } else if model.modelsFolder == nil {
                hint("Choose a folder for the model files.")
            } else if model.videoInfo == nil {
                hint("Choose a video and a factor, then add it to the queue.")
            } else if model.queue.isEmpty {
                hint("Add videos to the queue, then press Go.")
            } else {
                hint(model.missingModels.isEmpty
                     ? "Add more videos, or press Go to upscale the queue."
                     : "Press Go to upscale the queue. The model files will be downloaded first.")
            }
        case .idle:
            if model.videoInfo == nil {
                hint("Choose a video to begin")
            } else if !model.engineReady {
                hint("The engine is missing from this app. Rebuild it with the build scripts.")
            } else if model.modelsFolder == nil {
                hint("Choose a folder for the model files.")
            } else {
                hint(model.missingModels.isEmpty ? "Ready." : "The model files will be downloaded first.")
            }
        case .downloading(let name, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading \(name)…").font(.callout)
                ProgressView(value: fraction).tint(accent)
            }
        case .working(let text, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    HStack {
                        Text(text).font(.callout).lineLimit(1)
                        Spacer()
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    ProgressView(value: fraction).tint(accent)
                } else {
                    progressRow(text)
                }
                if let start = model.upscaleStartedAt {
                    // Redrawn every second.
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("Elapsed \(Self.clock(context.date.timeIntervalSince(start)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        case .notice(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(let url, let took):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Upscaling finished: \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Took \(Self.clock(took))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case .batchFinished(let done, let failed, let took, let last):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(done == 1 ? "Batch finished: 1 video upscaled" : "Batch finished: \(done) videos upscaled",
                          systemImage: failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failed == 0 ? .green : .orange)
                    Text(failed == 0
                         ? "Took \(Self.clock(took))"
                         : "Took \(Self.clock(took)) · \(failed) failed and \(failed == 1 ? "is" : "are") still in the queue")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let last {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([last])
                    }
                }
            }
        case .cancelled:
            if !model.missingModels.isEmpty {
                hint("Cancelled. Partial downloads are kept and will resume next time.")
            } else if model.mode == .batch && !model.queue.isEmpty {
                hint(model.queue.count == 1 ? "Stopped. 1 video is left in the queue."
                                            : "Stopped. \(model.queue.count) videos are left in the queue.")
            } else {
                hint("Cancelled.")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Something went wrong", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(6)
                    .textSelection(.enabled)
                if message.contains(Upscaler.relayVSR.absoluteString) {
                    Link("Open RelayVSR Video Upscaler", destination: Upscaler.relayVSR)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    // MARK: - Queue

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("QUEUE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !model.queue.isEmpty {
                    Text(model.queue.count == 1 ? "1 video" : "\(model.queue.count) videos")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if model.queue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("The queue is empty")
                        .font(.headline)
                    Text("Choose a video and a factor, then press Add to Queue.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.queue) { item in
                        queueRow(item)
                            .moveDisabled(item.id == model.runningItemID)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { model.moveQueue(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Text("Drag to reorder.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            goButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func queueRow(_ item: QueueItem) -> some View {
        let running = item.id == model.runningItemID
        return HStack(alignment: .top, spacing: 10) {
            Text(item.scale.label)
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                Text(queueDetails(item))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                if running {
                    if let fraction = model.currentFraction {
                        ProgressView(value: fraction).tint(accent).controlSize(.small)
                    } else {
                        ProgressView(value: 0).tint(accent).controlSize(.small)
                    }
                } else if let failure = item.failure {
                    Text("Failed: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .help(failure)
                }
            }
            Spacer(minLength: 0)
            if running {
                ProgressView().controlSize(.small)
            } else {
                Button { model.removeFromQueue(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Remove from the queue")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(running ? accent.opacity(0.14) : Color.white.opacity(0.05))
        )
        .contextMenu {
            Button("Remove from Queue") { model.removeFromQueue(item.id) }
                .disabled(running)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    /// Big red Go; Stop while the batch runs.
    private var goButton: some View {
        Button {
            if model.isBatchRunning { model.cancel() } else { model.startBatch() }
        } label: {
            Label(model.isBatchRunning ? "Stop" : "Go",
                  systemImage: model.isBatchRunning ? "stop.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isBatchRunning ? Color(white: 0.38) : goRed)
        .controlSize(.large)
        .disabled(!model.isBatchRunning && !model.canStartBatch)
    }

    /// "1920×1080 · 0:15 · /path/to/folder"
    private func queueDetails(_ item: QueueItem) -> String {
        let size = item.info.displaySize
        return "\(Int(size.width))×\(Int(size.height)) · \(Self.clock(item.info.duration.rounded())) · "
            + item.url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Helpers

    private var modelStatus: String {
        guard model.modelsFolder != nil else {
            return "Choose a folder. Missing model files download there."
        }
        if model.missingModels.isEmpty {
            return "All ReCaVSR model files are present."
        }
        let size = model.missingModels.reduce(0) { $0 + $1.approxSizeGB }
        return String(format: "%d file(s) to download, about %.1f GB.", model.missingModels.count, size)
    }

    /// "1920×1080 · 29.97 fps · 1:05 · /path/to/folder"
    private func videoDetails(_ url: URL) -> String {
        guard let info = model.videoInfo else { return url.deletingLastPathComponent().path }
        let size = info.displaySize
        let fps = info.fps.rounded() == info.fps ? String(Int(info.fps)) : String(format: "%.2f", info.fps)
        let total = Int(info.duration.rounded())
        let length = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        return "\(Int(size.width))×\(Int(size.height)) · \(fps) fps · \(length) · \(url.deletingLastPathComponent().path)"
    }

    /// 0:42, 12:05, 1:02:09
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.6))
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in model.setVideo(url) }
        }
        return true
    }
}

/// Height of the main column, measured so the queue panel can match it.
private struct MainHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Removes the resize handle from the hosting window, so it keeps the size its content needs.
private struct FixedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.styleMask.remove(.resizable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.styleMask.remove(.resizable)
        }
    }
}

/// Looks like a standard small bordered button, but keeps its label in the accent colour.
private struct AccentTextButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? color : color.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// A rounded panel used for each section.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
