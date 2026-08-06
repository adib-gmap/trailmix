import Foundation
import Testing

@testable import trailmix

/// These filenames are the app's contract with whatever gets pointed at a
/// session folder next: an `on_stop` hook, a script, a Finder habit. Changing
/// one is a user-facing change rather than a refactor, so the current values are
/// pinned here to make a rename a deliberate act instead of a side effect.
///
/// `SessionFiles.swift` exists because these strings were once spelled out in
/// five places and a rename missed some.
@Suite("SessionFiles")
struct SessionFilesTests {

    @Test("the names are what the README documents")
    func names() {
        #expect(SessionFiles.mic == "mic.caf")
        #expect(SessionFiles.system == "system.caf")
        #expect(SessionFiles.mixedAudio == "mixed.m4a")
        #expect(SessionFiles.video == "mixed.mp4")
        #expect(SessionFiles.legacyVideo == "screen.mov")
        #expect(SessionFiles.meta == "meta.json")
        #expect(SessionFiles.transcript == "transcript.json")
        #expect(SessionFiles.readableTranscript == "transcript.md.txt")
        #expect(SessionFiles.transcriptLog == "transcript.log")
    }

    /// The double extension is deliberate: it is markdown, and `.txt` is what
    /// makes it open on a Mac that has never had a markdown editor installed. A
    /// file nobody can double-click is not readable.
    @Test("the readable transcript stays openable by double-click")
    func doubleExtension() {
        #expect(SessionFiles.readableTranscript.hasSuffix(".txt"))
        #expect(SessionFiles.readableTranscript.contains(".md."))
    }

    /// The three transcript files share a stem so they sort together and read as
    /// one set: the data, the readable rendering, and the record of how it went.
    @Test("the transcript files share a stem")
    func transcriptFilesSortTogether() {
        for name in [
            SessionFiles.transcript,
            SessionFiles.readableTranscript,
            SessionFiles.transcriptLog,
        ] {
            #expect(name.hasPrefix("transcript"))
        }
    }

    /// Both `mixed.*` files are named for containing every audio source the
    /// session captured; one of them happens to carry video too.
    @Test("the mixed files share a stem")
    func mixedFilesSortTogether() {
        #expect(SessionFiles.mixedAudio.hasPrefix("mixed"))
        #expect(SessionFiles.video.hasPrefix("mixed"))
    }

    @Test("every name is distinct")
    func namesAreDistinct() {
        let names = [
            SessionFiles.mic, SessionFiles.system, SessionFiles.mixedAudio,
            SessionFiles.video, SessionFiles.legacyVideo, SessionFiles.meta,
            SessionFiles.transcript, SessionFiles.readableTranscript,
            SessionFiles.transcriptLog,
        ]
        #expect(Set(names).count == names.count)
    }

    // MARK: - Locating the video

    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailmix-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("a session with no video reports none")
    func noVideo() throws {
        try inTemporaryDirectory { dir in
            #expect(SessionFiles.video(in: dir) == nil)
        }
    }

    @Test("the current name is found")
    func findsCurrentName() throws {
        try inTemporaryDirectory { dir in
            try Data().write(to: dir.appendingPathComponent(SessionFiles.video))
            #expect(SessionFiles.video(in: dir)?.lastPathComponent == SessionFiles.video)
        }
    }

    /// Sessions recorded before the 2026-08-04 rename still have `screen.mov` on
    /// disk. Judging them by the current name alone would orphan them.
    @Test("a pre-rename session is still found")
    func findsLegacyName() throws {
        try inTemporaryDirectory { dir in
            try Data().write(to: dir.appendingPathComponent(SessionFiles.legacyVideo))
            #expect(SessionFiles.video(in: dir)?.lastPathComponent == SessionFiles.legacyVideo)
        }
    }

    /// With both on disk the current name wins, so a folder that somehow has
    /// both doesn't resolve to the older file.
    @Test("the current name takes precedence over the legacy one")
    func currentNameWins() throws {
        try inTemporaryDirectory { dir in
            try Data().write(to: dir.appendingPathComponent(SessionFiles.legacyVideo))
            try Data().write(to: dir.appendingPathComponent(SessionFiles.video))
            #expect(SessionFiles.video(in: dir)?.lastPathComponent == SessionFiles.video)
        }
    }

    /// A zero-byte file still counts as present here. That is correct at this
    /// level: `SessionFiles` answers "which name was it written under", and
    /// whether the file is usable is `RecordingSession`'s question, which checks
    /// size because `SCRecordingOutput` creates the file at start.
    @Test("presence is by name, not by size")
    func presenceIsByName() throws {
        try inTemporaryDirectory { dir in
            try Data().write(to: dir.appendingPathComponent(SessionFiles.video))
            #expect(SessionFiles.video(in: dir) != nil)
        }
    }

    @Test("the returned URL is inside the session folder")
    func returnsPathInsideSession() throws {
        try inTemporaryDirectory { dir in
            try Data().write(to: dir.appendingPathComponent(SessionFiles.video))
            let found = try #require(SessionFiles.video(in: dir))
            #expect(found.deletingLastPathComponent().standardizedFileURL
                == dir.standardizedFileURL)
        }
    }
}
