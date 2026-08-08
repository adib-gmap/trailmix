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

    private func writeMeta(to dir: URL, videoOffsetMs: Int?) throws {
        var offsets: [String: Int] = ["mic": 0, "system": 0]
        if let videoOffsetMs { offsets["video"] = videoOffsetMs }
        try SessionFixtures.writeMeta(
            to: dir,
            files: ["video": SessionFiles.video, "mixed": SessionFiles.mixedAudio],
            offsets: offsets
        )
    }

    // MARK: - The offset the mix is read from

    /// The video's own `start_offset_ms`, which is what lines the mix up
    /// against the video. Absent, unreadable, or negative all mean zero, which
    /// is the behaviour every session recorded before offsets existed relies on.
    @Test("the video offset is read from meta.json, and defaults to zero")
    func videoOffsetLookup() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
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
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 2)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 2)
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
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 1)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 4)
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
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 3)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 3)
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
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 1)
            let before = try #require(
                (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int
            )

            await Remux.mixedAudioIntoVideo(in: dir)

            let after = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size]
                as? Int
            #expect(after == before, "the video was rewritten with nothing to add")
        }
    }

    /// A mix that isn't readable audio must not be swapped in.
    ///
    /// The swap replaces the video's audio wholesale, so a source with no
    /// usable track would exchange the system audio the recording came off the
    /// stream with for silence, and `replaceItemAt` would make that the only
    /// copy. Failing leaves the original exactly as it was.
    @Test("a mix with no audio track leaves the video alone")
    func unreadableMixIsRefused() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 1)
            // The right name, the wrong bytes: what a mixdown killed partway
            // through leaves behind.
            try Data("not audio".utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.mixedAudio))
            let before = try #require(
                (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int
            )

            await Remux.mixedAudioIntoVideo(in: dir)

            let after = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size]
                as? Int
            #expect(after == before, "the video was rewritten from an unreadable mix")
            #expect(!Remux.alreadySwapped(in: dir), "a failed swap was marked done")
        }
    }

    /// A mix that ends before the video's own start offset has nothing to
    /// contribute, and inserting nothing is the same silent swap as inserting a
    /// track that isn't there.
    @Test("a mix that ends before the video starts is refused")
    func mixEndingBeforeTheVideoIsRefused() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 2)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 1)
            try writeMeta(to: dir, videoOffsetMs: 3000)

            await Remux.mixedAudioIntoVideo(in: dir)

            #expect(try await AVURLAsset(url: video).loadTracks(withMediaType: .audio).isEmpty)
            #expect(!Remux.alreadySwapped(in: dir))
        }
    }

    /// The marker recovery reads to decide whether a session still needs the
    /// swap. Without it, `mixed.m4a` stood for both halves of the job, and a
    /// session that crashed between the mixdown and the swap looked finished
    /// forever with a video that never got the microphone.
    @Test("a completed swap is recorded in meta.json")
    func swapIsRecorded() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            let video = dir.appendingPathComponent(SessionFiles.video)
            try await SessionFixtures.writeVideo(to: video, seconds: 1)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 1)
            try writeMeta(to: dir, videoOffsetMs: 0)
            #expect(!Remux.alreadySwapped(in: dir), "unmixed sessions must not read as done")

            await Remux.mixedAudioIntoVideo(in: dir)

            #expect(Remux.alreadySwapped(in: dir))
            // The patch is read-modify-write, so it must not cost the rest of
            // the file: the offsets are what the next repair pass reads.
            let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta))
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect((json["files"] as? [String: String])?["video"] == SessionFiles.video)
            #expect((json["start_offset_ms"] as? [String: Int])?["mic"] == 0)
        }
    }

    /// A session recorded before the rename still has `screen.mov`, and has to
    /// stay a `.mov` in place rather than becoming a second file.
    @Test("a legacy screen.mov is remuxed in place and keeps its name")
    func legacyVideoStaysMov() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            // Written as mp4 then renamed: what matters here is the path
            // extension Remux keys the export container off, and QuickTime and
            // mp4 are close enough that the passthrough export handles both.
            let temp = dir.appendingPathComponent("staging.mp4")
            try await SessionFixtures.writeVideo(to: temp, seconds: 1)
            let legacy = dir.appendingPathComponent(SessionFiles.legacyVideo)
            try FileManager.default.moveItem(at: temp, to: legacy)
            try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 1)

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
