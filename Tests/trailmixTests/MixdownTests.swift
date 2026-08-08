import AVFoundation
import Foundation
import Testing

@testable import trailmix

/// `mixed.m4a` is a completion marker as much as it is a file: `Mixdown.run`
/// skips a session that has one, and nothing else ever rebuilds it. So the
/// question these ask is not whether the mix sounds right, it is whether the
/// name can ever end up on bytes that aren't a finished mix.
@Suite("Mixdown")
struct MixdownTests {

    /// A session with two raw tracks and no mix yet.
    private func writeTracks(in dir: URL, seconds: Double = 1) throws {
        try SessionFixtures.writeAudio(to: dir.appendingPathComponent(SessionFiles.mic), seconds: seconds)
        try SessionFixtures.writeAudio(
            to: dir.appendingPathComponent(SessionFiles.system), seconds: seconds
        )
        try SessionFixtures.writeMeta(
            to: dir,
            files: ["mic": SessionFiles.mic, "system": SessionFiles.system],
            offsets: ["mic": 0, "system": 0]
        )
    }

    @Test("the mix is built from the raw tracks and recorded in meta.json")
    func mixIsBuilt() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try writeTracks(in: dir)
            await Mixdown.run(in: dir)

            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            #expect(await SessionFixtures.hasPlayableAudio(mixed))
            let files = try SessionFixtures.readMeta(in: dir)["files"] as? [String: String]
            #expect(files?["mixed"] == SessionFiles.mixedAudio)
        }
    }

    /// The export writes beside the destination and moves the result into
    /// place, so the working file must not outlive the run. A leftover
    /// `mix.tmp.m4a` in every session folder is user-visible junk in the one
    /// directory the app promises to keep tidy.
    @Test("the working file doesn't survive a finished mix")
    func temporaryFileIsCleanedUp() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try writeTracks(in: dir)
            await Mixdown.run(in: dir)

            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(SessionFiles.mixTemp).path
                )
            )
        }
    }

    /// The failure this exists for: a process killed mid-export leaves bytes
    /// at the final name. Before the export moved through a temporary file,
    /// `mixed.m4a` was trusted on existence alone, so that debris was treated
    /// as a finished mix on every later launch and the real one was never
    /// built. `Remux` would then refuse it, correctly, and the video would go
    /// without the microphone forever.
    @Test("a mixed.m4a that isn't a readable mix is rebuilt, not trusted")
    func partialMixIsRebuilt() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try writeTracks(in: dir)
            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            // What an interrupted export leaves: the first few kilobytes of an
            // m4a, correct as far as they go and unplayable.
            try Data(repeating: 0, count: 4096).write(to: mixed)
            #expect(await !SessionFixtures.hasPlayableAudio(mixed), "the fixture must be broken")

            await Mixdown.run(in: dir)

            #expect(await SessionFixtures.hasPlayableAudio(mixed))
        }
    }

    /// The other half of that: rebuilding must not become the default. A
    /// re-encode per session per launch is exactly the cost the marker exists
    /// to avoid, so a mix meta.json already records is taken at its word
    /// without reading it back.
    @Test("a recorded mix is left exactly as it was")
    func recordedMixIsUntouched() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try writeTracks(in: dir)
            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            try SessionFixtures.writeAudio(to: mixed, seconds: 1)
            try SessionFixtures.writeMeta(
                to: dir,
                files: [
                    "mic": SessionFiles.mic,
                    "system": SessionFiles.system,
                    "mixed": SessionFiles.mixedAudio,
                ],
                offsets: ["mic": 0, "system": 0]
            )
            let before = try Data(contentsOf: mixed)

            await Mixdown.run(in: dir)

            #expect(try Data(contentsOf: mixed) == before)
        }
    }

    /// A readable mix that meta.json doesn't mention is finished work with a
    /// missing receipt: the file is proof enough, and re-encoding it would
    /// throw away a good mix. Recording it is what stops the next launch
    /// reading it back again.
    @Test("an unrecorded but readable mix is kept and recorded")
    func unrecordedMixIsAdopted() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try writeTracks(in: dir)
            let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
            try SessionFixtures.writeAudio(to: mixed, seconds: 1)
            let before = try Data(contentsOf: mixed)

            await Mixdown.run(in: dir)

            #expect(try Data(contentsOf: mixed) == before)
            let files = try SessionFixtures.readMeta(in: dir)["files"] as? [String: String]
            #expect(files?["mixed"] == SessionFiles.mixedAudio)
        }
    }

    /// A video-only session has nothing to mix and must not end up with an
    /// empty `mixed.m4a` standing in for one.
    @Test("a session with no audio produces no mix")
    func noAudioProducesNoMix() async throws {
        try await SessionFixtures.inTemporaryDirectory { dir in
            try SessionFixtures.writeMeta(to: dir, files: ["video": SessionFiles.video])
            await Mixdown.run(in: dir)

            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(SessionFiles.mixedAudio).path
                )
            )
        }
    }
}
