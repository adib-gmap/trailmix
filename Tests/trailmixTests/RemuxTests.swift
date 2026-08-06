import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import trailmix

/// `Remux` swaps the session's mixed audio into the captured video, and until
/// now nothing exercised it: it needs a real video file, which needs a screen
/// and a click, so it was only ever checked by hand against one recording.
///
/// A video does not actually need a screen to exist. `AVAssetWriter` will
/// encode one from synthesized frames, which is enough to drive the real
/// composition, the real passthrough export, and the real verify-then-replace,
/// and to read back where the audio actually landed.
@Suite("Remux")
struct RemuxTests {

    private static let fps: Int32 = 30
    private static let width = 160
    private static let height = 120

    private func inTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailmix-remux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    /// A silent H.264 mp4 of `seconds` duration. Video only, which is what
    /// `SCRecordingOutput` leaves behind once the mic moved off the stream.
    private func writeVideo(to url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
            ]
        )
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        let total = Int(seconds * Double(Self.fps))
        for frame in 0 ..< total {
            var pixelBuffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            // A flat mid-grey field. Nothing here reads the pixels; they just
            // have to be real enough for the encoder.
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * Self.height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: Self.fps)
                )
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
    }

    /// An m4a of a 440 Hz tone, standing in for `mixed.m4a`.
    private func writeAudio(to url: URL, seconds: Double) throws {
        let sampleRate = 44100.0
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = Int(sampleRate * seconds)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for frame in 0 ..< frames {
            data[0][frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        try file.write(from: buffer)
    }

    private func writeMeta(to dir: URL, videoOffsetMs: Int?) throws {
        var offsets: [String: Int] = ["mic": 0, "system": 0]
        if let videoOffsetMs { offsets["video"] = videoOffsetMs }
        let meta: [String: Any] = [
            "files": ["video": SessionFiles.video, "mixed": SessionFiles.mixedAudio],
            "start_offset_ms": offsets,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    // MARK: - The offset the mix is read from

    /// The video's own `start_offset_ms`, which is what lines the mix up
    /// against the video. Absent, unreadable, or negative all mean zero, which
    /// is the behaviour every session recorded before offsets existed relies on.
    @Test("the video offset is read from meta.json, and defaults to zero")
    func videoOffsetLookup() async throws {
        try await inTemporaryDirectory { dir in
            #expect(Remux.videoOffsetMs(in: dir) == 0, "no meta.json at all")

            try writeMeta(to: dir, videoOffsetMs: nil)
            #expect(Remux.videoOffsetMs(in: dir) == 0, "no video key")

            try writeMeta(to: dir, videoOffsetMs: 250)
            #expect(Remux.videoOffsetMs(in: dir) == 250)

            try writeMeta(to: dir, videoOffsetMs: -40)
            #expect(Remux.videoOffsetMs(in: dir) == 0, "a negative offset can't shift the mix")
        }
    }

    // MARK: - The swap itself

    /// The base case: a video with no audio comes back carrying the mix, at the
    /// same duration and with the video track intact.
    @Test("the mixed audio lands in the video")
    func audioIsSwappedIn() async throws {
        try await inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await writeVideo(to: video, seconds: 2)
            try writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 2)
            try writeMeta(to: dir, videoOffsetMs: 0)

            let before = AVURLAsset(url: video)
            #expect(try await before.loadTracks(withMediaType: .audio).isEmpty)

            await Remux.mixedAudioIntoVideo(in: dir)

            let after = AVURLAsset(url: video)
            #expect(try await after.loadTracks(withMediaType: .video).count == 1)
            #expect(try await after.loadTracks(withMediaType: .audio).count == 1)
            #expect(try await after.load(.duration).seconds > 1.9)
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("remux.tmp.mp4").path
                ),
                "the temp file is cleaned up"
            )
        }
    }

    /// Audio longer than the video is clamped rather than stretching the file
    /// past its last frame.
    @Test("a longer audio tail doesn't extend the video")
    func longerAudioIsClamped() async throws {
        try await inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await writeVideo(to: video, seconds: 1)
            try writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 4)
            try writeMeta(to: dir, videoOffsetMs: 0)

            await Remux.mixedAudioIntoVideo(in: dir)

            let duration = try await AVURLAsset(url: video).load(.duration).seconds
            #expect(duration < 1.5, "the audio tail stretched the video to \(duration)s")
        }
    }

    /// The reason the offset is read at all.
    ///
    /// When system audio reaches the writer before the first video frame does,
    /// the video is not the earliest track, so `mixed.m4a`'s zero sits before
    /// the video's. Inserting the mix at its own start would put the audio
    /// ahead of the picture by that much. Reading from the video's offset means
    /// the audio track that lands is shorter than the mix by exactly the offset,
    /// which is what this measures.
    @Test("a video that started late reads the mix from its own offset")
    func lateVideoReadsFromItsOffset() async throws {
        try await inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await writeVideo(to: video, seconds: 3)
            try writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 3)
            try writeMeta(to: dir, videoOffsetMs: 1000)

            await Remux.mixedAudioIntoVideo(in: dir)

            let track = try #require(
                try await AVURLAsset(url: video).loadTracks(withMediaType: .audio).first
            )
            let seconds = try await track.load(.timeRange).duration.seconds
            #expect(
                seconds > 1.7 && seconds < 2.3,
                "expected ~2s of a 3s mix after a 1s video offset, got \(seconds)s"
            )
        }
    }

    /// A video with no mix beside it is left exactly as it was. That is the
    /// video-only session, and the audio-only one where there is nothing to
    /// remux into.
    @Test("a session with no mixed audio is left alone")
    func noMixedAudioIsANoOp() async throws {
        try await inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await writeVideo(to: video, seconds: 1)
            let before = try #require(
                (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int
            )

            await Remux.mixedAudioIntoVideo(in: dir)

            let after = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size]
                as? Int
            #expect(after == before, "the video was rewritten with nothing to add")
        }
    }

    /// A session recorded before the rename still has `screen.mov`, and has to
    /// stay a `.mov` in place rather than becoming a second file.
    @Test("a legacy screen.mov is remuxed in place and keeps its name")
    func legacyVideoStaysMov() async throws {
        try await inTemporaryDirectory { dir in
            // Written as mp4 then renamed: what matters here is the path
            // extension Remux keys the export container off, and QuickTime and
            // mp4 are close enough that the passthrough export handles both.
            let temp = dir.appendingPathComponent("staging.mp4")
            try await writeVideo(to: temp, seconds: 1)
            let legacy = dir.appendingPathComponent(SessionFiles.legacyVideo)
            try FileManager.default.moveItem(at: temp, to: legacy)
            try writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 1)

            await Remux.mixedAudioIntoVideo(in: dir)

            #expect(FileManager.default.fileExists(atPath: legacy.path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(SessionFiles.video).path
                ),
                "the legacy video became a second file"
            )
            #expect(try await AVURLAsset(url: legacy).loadTracks(withMediaType: .audio).count == 1)
        }
    }
}
