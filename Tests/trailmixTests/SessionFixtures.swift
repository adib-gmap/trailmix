import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import trailmix

/// Synthesized session files: a video, an audio track, a meta.json.
///
/// A recording ordinarily needs a screen, a microphone and a click, which is
/// why everything downstream of one went untested for so long. None of it
/// actually needs a *capture*, though. AVAssetWriter will encode an mp4 from
/// frames nobody looked at, and AVAudioFile will write a tone, and that is
/// enough to drive the real compositions, the real exports and the real
/// verify-then-replace in `Remux` and `Mixdown`.
///
/// Shared rather than per-suite because there is one right way to fake a
/// session and several tempting wrong ones; a second copy of this drifts.
enum SessionFixtures {

    private static let fps: Int32 = 30
    private static let width = 160
    private static let height = 120

    static func inTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailmix-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    /// A silent H.264 mp4 of `seconds` duration. Video only, which is what
    /// `SCRecordingOutput` leaves behind once the mic moved off the stream.
    static func writeVideo(to url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        let total = Int(seconds * Double(fps))
        for frame in 0 ..< total {
            var pixelBuffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            // A flat mid-grey field. Nothing here reads the pixels; they just
            // have to be real enough for the encoder.
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
                )
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
    }

    /// A 440 Hz tone, in whichever format the extension asks for: AAC in m4a
    /// for a stand-in `mixed.m4a`, uncompressed in caf for the raw tracks the
    /// capture path writes.
    static func writeAudio(to url: URL, seconds: Double) throws {
        let sampleRate = 44100.0
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        settings[AVFormatIDKey] =
            url.pathExtension.lowercased() == "caf"
            ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
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

    /// meta.json as the session would have written it, minus whatever the test
    /// is about: leave `mixed` out of `files` to describe a session that never
    /// got its mixdown recorded.
    static func writeMeta(
        to dir: URL,
        files: [String: String],
        offsets: [String: Int] = [:]
    ) throws {
        let meta: [String: Any] = ["files": files, "start_offset_ms": offsets]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    /// What `meta.json` currently says, for the tests that assert on markers.
    static func readMeta(in dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Whether a file has audio anyone can play, which is the only question
    /// worth asking of a mix. Every serious bug in this project has produced a
    /// file of plausible size holding nothing.
    static func hasPlayableAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
            let duration = try? await asset.load(.duration), duration.seconds > 0
        else { return false }
        return true
    }
}
