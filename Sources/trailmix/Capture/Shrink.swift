import AVFoundation
import ArgumentParser
import CoreMedia
import Foundation
import VideoToolbox

/// Re-encodes a finished recording smaller: at most `max_height` pixels tall
/// (1440 by default), HEVC at a fixed average bitrate, AAC audio at a fixed
/// bitrate.
///
/// ScreenCaptureKit records a Retina display at its full pixel size (a 5K
/// monitor comes out 3840×2160) and `SCRecordingOutput` picks the bitrate
/// itself, with no setting to lower it: about 4 Mbit/s averaged over a long
/// session, 3.3 GB for 1 h 45 min. Measured 2026-11-02 on such a recording,
/// 2560×1440 at 1.5 Mbit/s kept browser text indistinguishable from the
/// original at roughly a third of the size. The audio was 250 kbit/s stereo,
/// a few percent of the file; 128 kbit/s is plenty for speech.
///
/// Runs after `Remux.finalize`, so it reads a video that already carries the
/// mix and has its pauses cut out. The reader applies the file's edit list, so
/// the cut is baked in and the result has none. Only sessions whose meta.json
/// carries a `shrink` request are touched: the request is written at stop when
/// the config has shrinking on, which keeps launch-time recovery (it walks
/// every session folder) from re-encoding recordings made before this existed.
/// `video_shrunk` marks it done, the same pattern as `mixed_audio_in_video`.
///
/// The new file is written beside the original, read back, and swapped in with
/// `replaceItemAt`, so an interrupted or failed shrink leaves the original
/// exactly as it was, unmarked, and the next launch tries again.
enum Shrink {
    struct Settings: Sendable, Equatable {
        var maxHeight: Int
        var videoKbps: Int
        var audioKbps: Int

        static let `default` = Settings(maxHeight: 1440, videoKbps: 1500, audioKbps: 128)

        init(maxHeight: Int, videoKbps: Int, audioKbps: Int) {
            // Clamped rather than rejected: a typo in the config should give a
            // usable file, not a 50 kbit/s smear or a failed encode.
            self.maxHeight = min(max(maxHeight, 360), 4320)
            self.videoKbps = min(max(videoKbps, 200), 50_000)
            self.audioKbps = min(max(audioKbps, 64), 320)
        }

        /// From a config or meta.json dictionary; missing keys take the defaults.
        init(json: [String: Any]) {
            func int(_ key: String, _ fallback: Int) -> Int {
                (json[key] as? NSNumber)?.intValue ?? fallback
            }
            self.init(
                maxHeight: int("max_height", Self.default.maxHeight),
                videoKbps: int("video_kbps", Self.default.videoKbps),
                audioKbps: int("audio_kbps", Self.default.audioKbps)
            )
        }

        var json: [String: Int] {
            ["max_height": maxHeight, "video_kbps": videoKbps, "audio_kbps": audioKbps]
        }
    }

    enum Outcome: Equatable {
        /// Already no taller than asked and no higher in bitrate; left alone.
        case alreadySmall
        case written
    }

    enum ShrinkError: Error, CustomStringConvertible {
        case noVideoTrack
        case cannotRead(String)
        case cannotWrite(String)
        case verificationFailed(String)
        case metaUnreadable

        var description: String {
            switch self {
            case .noVideoTrack: return "the recording has no video track"
            case .cannotRead(let why): return "can't read the video: \(why)"
            case .cannotWrite(let why): return "can't write the smaller video: \(why)"
            case .verificationFailed(let why): return "the smaller video didn't check out: \(why)"
            case .metaUnreadable: return "can't read \(SessionFiles.meta) to record the shrink"
            }
        }
    }

    static let requestKey = "shrink"
    static let doneKey = "video_shrunk"

    /// The settings this session asked for at stop, or nil when it didn't.
    static func requested(in dir: URL) -> Settings? {
        guard let json = readMeta(in: dir), let request = json[requestKey] as? [String: Any]
        else { return nil }
        return Settings(json: request)
    }

    static func done(in dir: URL) -> Bool {
        readMeta(in: dir)?[doneKey] as? Bool ?? false
    }

    // MARK: - Session step

    /// Shrink the session's video if it asked to be and hasn't been yet. Waits
    /// for `Remux`: a mix not yet swapped in, or pauses not yet cut, means the
    /// video will be rewritten again, so this leaves it for a later pass.
    static func run(in dir: URL) async {
        guard
            let settings = requested(in: dir),
            !done(in: dir),
            let video = SessionFiles.video(in: dir)
        else { return }

        let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
        if FileManager.default.fileExists(atPath: mixed.path) {
            guard Remux.alreadySwapped(in: dir) else { return }
        } else if !Remux.pausedRanges(in: dir).isEmpty, !Remux.pausesRemoved(in: dir) {
            return
        }

        let temp = dir.appendingPathComponent("shrink.tmp.\(video.pathExtension)")
        let before = fileSize(video)
        let clock = Date()
        let outcome: Outcome
        do {
            outcome = try await encode(video, to: temp, settings: settings)
            if outcome == .written {
                _ = try FileManager.default.replaceItemAt(video, withItemAt: temp)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Log.warn("\(dir.lastPathComponent): can't shrink \(video.lastPathComponent): \(error)")
            return
        }

        do {
            try patchMeta(in: dir) { $0[doneKey] = true }
        } catch {
            Log.warn(
                "\(dir.lastPathComponent): \(video.lastPathComponent) was shrunk, but "
                    + "\(SessionFiles.meta) didn't record it: \(error). it will be checked again"
            )
            return
        }
        switch outcome {
        case .alreadySmall:
            Log.info("\(dir.lastPathComponent): \(video.lastPathComponent) already small, left as is")
        case .written:
            let after = fileSize(video)
            Log.info(
                "\(dir.lastPathComponent): \(video.lastPathComponent) shrunk "
                    + "\(megabytes(before)) → \(megabytes(after)) in \(Int(Date().timeIntervalSince(clock))) s"
            )
        }
    }

    // MARK: - Encode

    /// Write a smaller copy of `source` to `dest`, read it back, and say what
    /// happened. `source` is never modified. On `.alreadySmall` nothing is
    /// written.
    static func encode(_ source: URL, to dest: URL, settings: Settings) async throws -> Outcome {
        try? FileManager.default.removeItem(at: dest)

        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        else { throw ShrinkError.noVideoTrack }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let dataRate = try await videoTrack.load(.estimatedDataRate)
        let sourceDuration = try await asset.load(.duration)

        let size = targetSize(width: Int(natural.width), height: Int(natural.height), maxHeight: settings.maxHeight)
        // Margin so a file this already wrote isn't re-encoded for being a
        // hair over its own target.
        if size.height >= Int(natural.height), Double(dataRate) <= Double(settings.videoKbps) * 1000 * 1.1 {
            return .alreadySmall
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ShrinkError.cannotRead("\(error)")
        }
        let videoOut = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ShrinkError.cannotRead("video output refused") }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        var audioFormat: (rate: Double, channels: Int) = (48_000, 2)
        if let audioTrack {
            if let desc = try await audioTrack.load(.formatDescriptions).first,
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
            {
                audioFormat = (asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000, max(1, min(2, Int(asbd.mChannelsPerFrame))))
            }
            let out = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioFormat.rate,
                    AVNumberOfChannelsKey: audioFormat.channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            )
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw ShrinkError.cannotRead("audio output refused") }
            reader.add(out)
            audioOut = out
        }

        let isMP4 = dest.pathExtension.lowercased() == "mp4"
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: dest, fileType: isMP4 ? .mp4 : .mov) } catch {
            throw ShrinkError.cannotWrite("\(error)")
        }
        let videoIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                // The writer scales the decoded frames to the output size.
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.videoKbps * 1000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalDurationKey: 4,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    // Not a live encode: lets the encoder yield to a recording
                    // started while this runs, which is real-time.
                    kVTCompressionPropertyKey_RealTime as String: false,
                ] as [String: Any],
            ]
        )
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard writer.canAdd(videoIn) else { throw ShrinkError.cannotWrite("video input refused") }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioFormat.rate,
                    AVNumberOfChannelsKey: audioFormat.channels,
                    AVEncoderBitRateKey: settings.audioKbps * 1000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ShrinkError.cannotWrite("audio input refused") }
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else {
            throw ShrinkError.cannotRead(reader.error.map { "\($0)" } ?? "reader did not start")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ShrinkError.cannotWrite(writer.error.map { "\($0)" } ?? "writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        // Both tracks at once: the writer interleaves, so it stops taking one
        // track while the other falls behind, and a single pump would stall.
        let pumps = [Pump(videoOut, videoIn, writer, "video")] + (audioOut.map { [Pump($0, audioIn!, writer, "audio")] } ?? [])
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
        }

        if reader.status == .failed || writer.status == .failed || pumps.contains(where: { $0.appendFailed }) {
            let why = writer.error.map { "\($0)" } ?? reader.error.map { "\($0)" } ?? "append failed"
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw ShrinkError.cannotWrite(why)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw ShrinkError.cannotWrite(writer.error.map { "\($0)" } ?? "writer did not complete")
        }

        // Read back before it is trusted with the only copy.
        let check = AVURLAsset(url: dest)
        let hasVideo = try await !check.loadTracks(withMediaType: .video).isEmpty
        let hasAudio = try await !check.loadTracks(withMediaType: .audio).isEmpty
        let duration = try await check.load(.duration).seconds
        let expected = sourceDuration.seconds
        let problem: String? =
            !hasVideo ? "no video track"
            : (audioTrack != nil && !hasAudio) ? "the audio track went missing"
            : !(duration > 0) ? "zero length"
            : abs(duration - expected) > max(1.0, expected * 0.01)
                ? String(format: "length %.1f s against %.1f s", duration, expected) : nil
        if let problem {
            try? FileManager.default.removeItem(at: dest)
            throw ShrinkError.verificationFailed(problem)
        }
        return .written
    }

    /// Fit inside `maxHeight`, never upscale, keep the aspect ratio, even
    /// dimensions (the encoder wants them).
    static func targetSize(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let scale = min(1.0, Double(maxHeight) / Double(height))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    // MARK: - Helpers

    /// Moves samples from one reader output to one writer input until the
    /// reader runs dry or the writer refuses one.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
        let queue: DispatchQueue
        private(set) var appendFailed = false
        /// Touched only on `queue`.
        private var finished = false

        init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ label: String) {
            self.output = output
            self.input = input
            self.writer = writer
            self.queue = DispatchQueue(label: "trailmix.shrink.\(label)", qos: .utility)
        }

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard writer.status == .writing, let sample = output.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        if !input.append(sample) {
                            appendFailed = true
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    private static func readMeta(in dir: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func patchMeta(in dir: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard var json = readMeta(in: dir) else { throw ShrinkError.metaUnreadable }
        change(&json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.2f GB", Double(bytes) / 1e9)
            : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}

/// `trailmix shrink in.mp4 out.mp4`: the same re-encode a recording gets after
/// stop, on any file, writing a new one. For checking size and quality on a
/// real recording, and for shrinking recordings made before this existed.
struct ShrinkFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shrink",
        abstract: "Write a smaller copy of a video (what a recording gets after stop). The input is not changed."
    )

    @Argument(help: "The video to read.")
    var input: String

    @Argument(help: "Where to write the smaller copy.")
    var output: String

    @Option(name: .long, help: "Maximum height in pixels.")
    var maxHeight: Int = Shrink.Settings.default.maxHeight

    @Option(name: .long, help: "Video bitrate in kbit/s.")
    var videoKbps: Int = Shrink.Settings.default.videoKbps

    @Option(name: .long, help: "Audio bitrate in kbit/s.")
    var audioKbps: Int = Shrink.Settings.default.audioKbps

    func run() throws {
        final class Box: @unchecked Sendable { var result: Result<Shrink.Outcome, Error>? }
        let box = Box()
        let settings = Shrink.Settings(maxHeight: maxHeight, videoKbps: videoKbps, audioKbps: audioKbps)
        let src = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let dst = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let started = Date()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await Shrink.encode(src, to: dst, settings: settings)) } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case .success(.written):
            print(String(format: "written in %.1f s: %@", Date().timeIntervalSince(started), dst.path))
        case .success(.alreadySmall):
            print("already small, nothing written")
        case .failure(let error):
            print("failed: \(error)")
            throw ExitCode(1)
        case nil:
            throw ExitCode(1)
        }
    }
}
