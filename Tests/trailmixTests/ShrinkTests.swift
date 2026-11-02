import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import trailmix

/// `Shrink` re-encodes a finished recording smaller. The fixture video is
/// 320×240, so these ask for 120 pixels tall to make it actually shrink.
@Suite("Shrink")
struct ShrinkTests {
    private let small = Shrink.Settings(maxHeight: 360, videoKbps: 200, audioKbps: 64)

    /// A session that asked for shrinking at stop, the way `RecordingSession`
    /// writes it, with `maxHeight` lowered below the 360 floor by hand.
    private func writeMeta(to dir: URL, request: [String: Int]?, mixed: Bool, pausedMs: [[Int]]? = nil) throws {
        var files = ["video": SessionFiles.video]
        if mixed { files["mixed"] = SessionFiles.mixedAudio }
        try SessionFixtures.writeMeta(to: dir, files: files, offsets: ["video": 0], pausedMs: pausedMs)
        guard let request else { return }
        var meta = try SessionFixtures.readMeta(in: dir)
        meta[Shrink.requestKey] = request
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    private func height(of url: URL) async throws -> Int {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return Int(try await track.load(.naturalSize).height)
    }

    @Test("target size fits the height, keeps the aspect, never upscales, stays even")
    func targetSize() {
        #expect(Shrink.targetSize(width: 3840, height: 2160, maxHeight: 1440) == (2560, 1440))
        #expect(Shrink.targetSize(width: 3456, height: 2234, maxHeight: 1440) == (2228, 1440))
        #expect(Shrink.targetSize(width: 1920, height: 1080, maxHeight: 1440) == (1920, 1080))
        #expect(Shrink.targetSize(width: 1001, height: 999, maxHeight: 1440) == (1002, 1000))
    }

    @Test("settings are clamped and default per missing key")
    func settingsFromJSON() {
        #expect(Shrink.Settings(json: [:]) == .default)
        let odd = Shrink.Settings(json: ["max_height": 10, "video_kbps": 1, "audio_kbps": 9999])
        #expect(odd == Shrink.Settings(maxHeight: 360, videoKbps: 200, audioKbps: 320))
    }

    @Test("a file is re-encoded smaller with its audio and length intact")
    func encodeShrinks() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 3)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 3)
            try writeMeta(to: dir, request: nil, mixed: true)
            await Remux.mixedAudioIntoVideo(in: dir)

            var settings = small
            settings.maxHeight = 120
            let out = dir.appendingPathComponent("out.mp4")
            #expect(try await Shrink.encode(video, to: out, settings: settings) == .written)
            #expect(try await height(of: out) == 120)
            #expect(await SessionFixtures.hasPlayableAudio(out))
            let seconds = try await AVURLAsset(url: out).load(.duration).seconds
            #expect(abs(seconds - 3) < 0.2)
        }
    }

    @Test("a file already small enough is left alone")
    func alreadySmall() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 2)
            let out = dir.appendingPathComponent("out.mp4")
            let roomy = Shrink.Settings(maxHeight: 1440, videoKbps: 50_000, audioKbps: 128)
            #expect(try await Shrink.encode(video, to: out, settings: roomy) == .alreadySmall)
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test("a session that didn't ask is never touched")
    func unrequestedSessionUntouched() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 2)
            try writeMeta(to: dir, request: nil, mixed: false)
            let before = try Data(contentsOf: video)
            await Shrink.run(in: dir)
            #expect(try Data(contentsOf: video) == before)
            #expect(try SessionFixtures.readMeta(in: dir)[Shrink.doneKey] == nil)
        }
    }

    @Test("a session waits for its mix to be swapped in before shrinking")
    func waitsForRemux() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 2)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 2)
            try writeMeta(to: dir, request: ["max_height": 360], mixed: true)
            await Shrink.run(in: dir)
            #expect(try SessionFixtures.readMeta(in: dir)[Shrink.doneKey] == nil)
        }
    }

    /// The whole stop path: mix swapped in with a pause cut out, then shrunk.
    /// The cut must survive the re-encode (the reader applies the edit list).
    @Test("after remux with a pause, the shrunk session keeps the cut length and is marked")
    func sessionAfterPauseCut() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 4)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 3)
            // 1 s paused, at least 1 s from the start so it is mid-GOP.
            try writeMeta(to: dir, request: ["max_height": 360, "video_kbps": 200], mixed: true, pausedMs: [[1300, 2300]])
            await Remux.finalize(in: dir)
            #expect(Remux.alreadySwapped(in: dir))
            let cut = try await AVURLAsset(url: video).load(.duration).seconds

            // The fixture is under 360 tall, so it shrinks only on bitrate if
            // at all; either outcome must be marked done and keep the length.
            await Shrink.run(in: dir)
            #expect(Shrink.done(in: dir))
            let after = try await AVURLAsset(url: video).load(.duration).seconds
            #expect(abs(after - cut) < 0.2)
            #expect(abs(after - 3) < 0.2)
            #expect(await SessionFixtures.hasPlayableAudio(video))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("shrink.tmp.mp4").path))
        }
    }

    /// Same as above but forced to re-encode, so the edit list really goes
    /// through the reader.
    @Test("a forced re-encode of a pause-cut video keeps the cut length")
    func encodeAfterPauseCut() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 4)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 3)
            try writeMeta(to: dir, request: nil, mixed: true, pausedMs: [[1300, 2300]])
            await Remux.finalize(in: dir)

            var settings = small
            settings.maxHeight = 120
            let out = dir.appendingPathComponent("out.mp4")
            #expect(try await Shrink.encode(video, to: out, settings: settings) == .written)
            let seconds = try await AVURLAsset(url: out).load(.duration).seconds
            #expect(abs(seconds - 3) < 0.2)
            #expect(try await height(of: out) == 120)
        }
    }
}
