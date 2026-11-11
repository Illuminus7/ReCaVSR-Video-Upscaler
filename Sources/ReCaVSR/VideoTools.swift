import AVFoundation
import Foundation

/// What the app needs to know about the input video. Reading it also checks that the
/// file is a video macOS can open (MP4, MOV, M4V), which the final assembly step needs.
struct VideoInfo: Sendable, Equatable {
    /// Encoded frame size (before rotation), the size ReCaVSR upscales.
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    let duration: Double
    /// Where the video track starts on the file's timeline, for keeping audio in sync.
    let videoStart: Double
    let transform: CGAffineTransform
    let hasAudio: Bool

    /// Size as it is shown, with rotation applied.
    var displaySize: CGSize {
        let rect = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func load(_ url: URL) async throws -> VideoInfo {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw AppError("“\(url.lastPathComponent)” is not a video file.")
        }
        let asset = AVURLAsset(url: url)
        let unreadable = AppError("“\(url.lastPathComponent)” can't be read. Use an MP4, MOV or M4V video.")
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { throw unreadable }
        guard let (size, rate, transform, range) = try? await track.load(.naturalSize, .nominalFrameRate,
                                                                         .preferredTransform, .timeRange) else {
            throw unreadable
        }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let duration = range.duration.seconds
        guard size.width >= 1, size.height >= 1, rate > 0, duration.isFinite, duration > 0 else { throw unreadable }
        let fps = Double(rate)
        return VideoInfo(width: Int(size.width), height: Int(size.height), fps: fps,
                         frameCount: max(1, Int((duration * fps).rounded())), duration: duration,
                         videoStart: range.start.seconds.isFinite ? range.start.seconds : 0,
                         transform: transform, hasAudio: !audio.isEmpty)
    }
}

/// Takes the video from ReCaVSR's output and adds the original audio, into one MP4. The video
/// is never re-encoded. The audio is copied as well when MP4 can hold it (AAC, ALAC, MP3…);
/// audio MP4 can't hold, such as the uncompressed PCM in many MOV files, is converted to AAC.
enum VideoAssembler {
    static func assemble(upscaled: URL, source: URL, info: VideoInfo, to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("Could not prepare the output video.")
        }
        let asset = AVURLAsset(url: upscaled)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("The upscaled video has no picture.")
        }
        let (range, size) = try await track.load(.timeRange, .naturalSize)
        try videoTrack.insertTimeRange(range, of: track, at: .zero)
        let cursor = range.duration

        // ReCaVSR upscales the frames as they are stored, without the rotation a phone video
        // carries, so the source's rotation is set on the result (scaled to its size).
        videoTrack.preferredTransform = Self.rotation(of: info.transform, size: size)

        if info.hasAudio {
            let original = AVURLAsset(url: source)
            if let audio = try await original.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await audio.load(.timeRange)
                let offset = CMTime(seconds: max(0, range.start.seconds - info.videoStart), preferredTimescale: 600)
                let length = CMTimeMinimum(range.duration, CMTimeSubtract(cursor, offset))
                if length > .zero {
                    try audioTrack.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: audio, at: offset)
                }
            }
        }

        let copiesIntoMP4 = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                     with: composition, outputFileType: .mp4)
        if copiesIntoMP4, try await audioPlaysInMP4(composition) {
            try await copyAll(composition, to: destination)
        } else {
            try await copyVideoConvertingAudio(composition, to: destination)
        }
    }

    /// The source's rotation or flip for a frame of `size`: the same rotation, moved so that
    /// the turned frame starts at the origin again.
    static func rotation(of transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        var turn = transform
        turn.tx = 0
        turn.ty = 0
        let box = CGRect(origin: .zero, size: size).applying(turn)
        turn.tx = -box.minX
        turn.ty = -box.minY
        return turn
    }

    /// Audio formats players expect in an MP4. macOS will also write uncompressed PCM into an
    /// MP4, but many players can't play that, so PCM (and anything else) is converted.
    private static let mp4AudioFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEGLayer3, kAudioFormatAC3, kAudioFormatEnhancedAC3,
        kAudioFormatAppleLossless, kAudioFormatOpus, kAudioFormatFLAC,
    ]

    private static func audioPlaysInMP4(_ composition: AVComposition) async throws -> Bool {
        guard let track = try await composition.loadTracks(withMediaType: .audio).first else { return true }
        let formats = try await track.load(.formatDescriptions)
        return !formats.isEmpty && formats.allSatisfy { mp4AudioFormats.contains(CMFormatDescriptionGetMediaSubType($0)) }
    }

    /// Everything is copied as it is.
    private static func copyAll(_ composition: AVComposition, to destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AppError("Could not prepare the output video.")
        }
        try await withTaskCancellationHandler {
            if #available(macOS 15, *) {
                try await export.export(to: destination, as: .mp4)
            } else {
                export.outputURL = destination
                export.outputFileType = .mp4
                await export.export()
                if let error = export.error { throw error }
                guard export.status == .completed else { throw CancellationError() }
            }
        } onCancel: {
            export.cancelExport()
        }
    }

    /// The video samples are copied as they are; the audio is decoded and written as AAC.
    private static func copyVideoConvertingAudio(_ composition: AVComposition, to destination: URL) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw AppError("Could not prepare the output video.")
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOutput)
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if let audioTrack = try await composition.loadTracks(withMediaType: .audio).first {
            let format = try await audioTrack.load(.formatDescriptions).first
            let description = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            // AAC is written at 44.1 or 48 kHz, where the bitrate below is valid; any other rate
            // (32 kHz, 96 kHz…) is resampled to 48 kHz on the way. At 32 kHz, for example, AAC
            // can't reach 192 kbps stereo and the writer fails with "Cannot Encode Media".
            let sampleRate = description?.mSampleRate == 44_100 ? 44_100.0 : 48_000.0
            let channels = description?.mChannelsPerFrame == 1 ? 1 : 2   // stereo, mixed down if needed
            let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                      AVSampleRateKey: sampleRate,
                                      AVNumberOfChannelsKey: channels]
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: pcm)
            reader.add(audioOutput)
            let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                      AVSampleRateKey: sampleRate,
                                      AVNumberOfChannelsKey: channels,
                                      AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            writer.add(audioInput)
            audioPair = (audioOutput, audioInput)
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? AppError("Could not write the output video.")
        }
        writer.startSession(atSourceTime: .zero)

        try await withTaskCancellationHandler {
            async let video: Void = pump(videoOutput, into: videoInput, label: "video")
            if let (audioOutput, audioInput) = audioPair {
                await pump(audioOutput, into: audioInput, label: "audio")
            }
            await video
            try Task.checkCancellation()
            if let error = reader.error ?? writer.error { throw error }
            await writer.finishWriting()
            if let error = writer.error { throw error }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    /// Feeds one reader output into one writer input until the output runs dry.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "ReCaVSR.assemble.\(label)")
        // Both are used only on `queue`, one callback at a time.
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) {
                        continue
                    }
                    finished = true
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }
}
