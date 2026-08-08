import AVFoundation
import Foundation
import Testing

@testable import trailmix

/// What `resumePending` does with a session that already has a transcript.
///
/// The recovery pipeline has three markers, one per step, and the point of
/// keeping them separate is that any one step can fail on its own. This suite
/// covers the case where the *last* one succeeded and an earlier one didn't:
/// transcription writes `transcript.json` whether or not the mixdown and the
/// remux ever ran, and treating that file as "session finished" is what made a
/// failed remux permanent. Every launch would see the transcript, skip the
/// folder, and leave `mixed.mp4` with the system audio it came off the stream
/// with and no microphone in it, forever.
///
/// These drive the real `Mixdown` and `Remux` against synthesized media, so
/// they cost a couple of seconds and no model: a session that already has a
/// transcript must never be queued, and `queuedCount` is the assertion that
/// says so.
@Suite("resumePending")
struct ResumePendingTests {

    /// A finished-looking transcript. The contents don't matter here, only
    /// that the file is there and parses, which is what marks the session
    /// transcribed.
    private func writeTranscript(in dir: URL) throws {
        let transcript = Transcript(
            engine: "parakeet",
            model: "test",
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: [
                Transcript.Segment(speaker: "mic", start_ms: 0, end_ms: 500, text: "hello")
            ]
        )
        try transcript.write(to: dir)
    }

    private func session(in root: URL, named name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a transcribed session still gets the mix it never got")
    func transcribedSessionIsStillMixed() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let dir = try session(in: root, named: "2026-08-07-100000")
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.mic), seconds: 1
            )
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.system), seconds: 1
            )
            try SessionFixtures.writeMeta(
                to: dir,
                files: ["mic": SessionFiles.mic, "system": SessionFiles.system],
                offsets: ["mic": 0, "system": 0]
            )
            try writeTranscript(in: dir)

            let coordinator = TranscriptionCoordinator()
            await coordinator.resumePending(root: root)

            #expect(
                await SessionFixtures.hasPlayableAudio(
                    dir.appendingPathComponent(SessionFiles.mixedAudio)
                ),
                "the mix is missing and nothing else will ever build it"
            )
            #expect(await coordinator.queuedCount == 0, "it already has a transcript")
        }
    }

    /// The mix guard belongs to `Mixdown.run` alone. `repairMixedFiles` used to
    /// keep its own copy, testing existence where the real one tests
    /// readability, and a duplicated guard that disagrees is worse than no
    /// guard: the debris of an interrupted export never reached the code that
    /// would have rebuilt it, so `Remux` refused it on every launch, correctly
    /// and forever. Driven through `resumePending` rather than `Mixdown.run`,
    /// because calling the mixdown directly is exactly what missed this.
    @Test("a corrupt mix is rebuilt by a rescan, not just by Mixdown")
    func corruptMixIsRebuiltByRecovery() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let dir = try session(in: root, named: "2026-08-07-130000")
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.mic), seconds: 1
            )
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.system), seconds: 1
            )
            // Present, unrecorded, unreadable: an export that died partway.
            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            try Data(repeating: 0, count: 4096).write(to: mixed)
            try SessionFixtures.writeMeta(
                to: dir,
                files: ["mic": SessionFiles.mic, "system": SessionFiles.system],
                offsets: ["mic": 0, "system": 0]
            )
            try writeTranscript(in: dir)

            let coordinator = TranscriptionCoordinator()
            await coordinator.resumePending(root: root)

            #expect(
                await SessionFixtures.hasPlayableAudio(mixed),
                "the half-written mix survived a rescan"
            )
            let files = try SessionFixtures.readMeta(in: dir)["files"] as? [String: String]
            #expect(files?["mixed"] == SessionFiles.mixedAudio)
            #expect(await coordinator.queuedCount == 0)
        }
    }

    @Test("a transcribed session still gets the remux it never got")
    func transcribedSessionIsStillRemuxed() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let dir = try session(in: root, named: "2026-08-07-110000")
            try await SessionFixtures.writeVideo(
                to: dir.appendingPathComponent(SessionFiles.video), seconds: 1
            )
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.mic), seconds: 1
            )
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.mixedAudio), seconds: 1
            )
            try SessionFixtures.writeMeta(
                to: dir,
                files: [
                    "mic": SessionFiles.mic,
                    "video": SessionFiles.video,
                    "mixed": SessionFiles.mixedAudio,
                ],
                offsets: ["mic": 0, "video": 0]
            )
            try writeTranscript(in: dir)
            #expect(!Remux.alreadySwapped(in: dir), "the fixture must start unswapped")

            let coordinator = TranscriptionCoordinator()
            await coordinator.resumePending(root: root)

            #expect(Remux.alreadySwapped(in: dir), "the swap was skipped on account of the transcript")
            #expect(await coordinator.queuedCount == 0)
        }
    }

    /// The repair is guarded per step, so a session that got all the way
    /// through must come out of a rescan byte for byte identical. Otherwise
    /// every launch re-encodes every recording ever made.
    @Test("a finished session is not touched again")
    func finishedSessionIsUntouched() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let dir = try session(in: root, named: "2026-08-07-120000")
            let video = dir.appendingPathComponent(SessionFiles.video)
            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            try await SessionFixtures.writeVideo(to: video, seconds: 1)
            try SessionFixtures.writeAudio(
                to: dir.appendingPathComponent(SessionFiles.mic), seconds: 1
            )
            try SessionFixtures.writeAudio(to: mixed, seconds: 1)
            try SessionFixtures.writeMeta(
                to: dir,
                files: [
                    "mic": SessionFiles.mic,
                    "video": SessionFiles.video,
                    "mixed": SessionFiles.mixedAudio,
                ],
                offsets: ["mic": 0, "video": 0]
            )
            try Remux.recordSwap(in: dir)
            try writeTranscript(in: dir)
            let videoBefore = try Data(contentsOf: video)
            let mixedBefore = try Data(contentsOf: mixed)

            let coordinator = TranscriptionCoordinator()
            await coordinator.resumePending(root: root)

            #expect(try Data(contentsOf: video) == videoBefore)
            #expect(try Data(contentsOf: mixed) == mixedBefore)
            #expect(await coordinator.queuedCount == 0)
        }
    }

    /// `recordSwap` is load-bearing: without it the video gets remuxed again on
    /// every launch. It used to swallow its own failure, so the log said the
    /// swap was done and the marker said it wasn't.
    @Test("an unwritable swap marker is reported rather than swallowed")
    func swapMarkerFailureIsReported() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            #expect(throws: Remux.RemuxError.self) {
                try Remux.recordSwap(in: dir)
            }
        }
    }
}
