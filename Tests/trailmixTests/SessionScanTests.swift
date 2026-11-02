import Foundation
import Testing

@testable import trailmix

/// The launch-time scan that finds sessions to repair and transcribe. It used
/// to list the root and stop; now a training recording sits four levels down
/// and a quick one is named by its description, so this walks. A session it
/// cannot find is a session that is never mixed, never transcribed, and
/// silently unplayable if the app died mid-recording.
@Suite("SessionScan")
struct SessionScanTests {

    private func folder(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ dir: URL, _ name: String) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    @Test("sessions are found at the root, by description, and four levels down")
    func findsNestedSessions() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let stamped = try folder(root, "2026.08.07-1000")
            try touch(stamped, SessionFiles.meta)
            let quick = try folder(root, "Precon meeting 11.2.26")
            try touch(quick, SessionFiles.mic)
            let nested = try folder(root, "SOP/Need To build SOP/Precon-Material list/Intake-pt1.11.2.26")
            try touch(nested, SessionFiles.meta)
            let videoOnly = try folder(root, "SOP/Precon-Material list/Review.11.2.26")
            try touch(videoOnly, SessionFiles.video)
            let legacy = try folder(root, "2026.07.01-0900")
            try touch(legacy, SessionFiles.legacyVideo)

            let found = Set(SessionScan.sessionFolders(under: root).map(\.lastPathComponent))
            #expect(found == [
                "2026.08.07-1000", "Precon meeting 11.2.26", "Intake-pt1.11.2.26",
                "Review.11.2.26", "2026.07.01-0900",
            ])
        }
    }

    @Test("intermediate folders, hidden folders and anything too deep are not sessions")
    func skipsNonSessions() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            _ = try folder(root, "SOP/Need To build SOP/Precon-Material list")   // empty process folder
            let hidden = try folder(root, ".Trash-like/2026.08.07-1000")
            try touch(hidden, SessionFiles.meta)
            let tooDeep = try folder(root, "a/b/c/d/2026.08.07-1100")
            try touch(tooDeep, SessionFiles.meta)
            let fourDeep = try folder(root, "a/b/c/2026.08.07-1200")
            try touch(fourDeep, SessionFiles.meta)

            let found = SessionScan.sessionFolders(under: root).map(\.lastPathComponent)
            #expect(found == ["2026.08.07-1200"])
        }
    }

    @Test("a session is never descended into")
    func doesNotDescendIntoSessions() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let session = try folder(root, "Precon-stuff 10.31.26")
            try touch(session, SessionFiles.meta)
            let inner = try folder(session, "Precon-screen-shots pt3")
            try touch(inner, SessionFiles.mic)   // media inside a session folder is the session's business

            let found = SessionScan.sessionFolders(under: root).map(\.lastPathComponent)
            #expect(found == ["Precon-stuff 10.31.26"])
        }
    }

    @Test("sessions come back oldest first by creation date, not by name")
    func ordersByCreationDate() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let fm = FileManager.default
            let names = ["c 11.2.26", "a 11.2.26", "b 11.2.26"]
            for (offset, name) in names.enumerated() {
                let dir = try folder(root, name)
                try touch(dir, SessionFiles.meta)
                try fm.setAttributes(
                    [.creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 60)],
                    ofItemAtPath: dir.path
                )
            }
            let found = SessionScan.sessionFolders(under: root).map(\.lastPathComponent)
            #expect(found == names)
        }
    }

    @Test("isSession looks for meta.json or any media file")
    func isSession() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let empty = try folder(root, "empty")
            #expect(!SessionScan.isSession(empty))
            for name in [SessionFiles.meta, SessionFiles.mic, SessionFiles.system, SessionFiles.video, SessionFiles.legacyVideo] {
                let dir = try folder(root, name)
                try touch(dir, name)
                #expect(SessionScan.isSession(dir), "\(name) alone should mark a session")
            }
            let notes = try folder(root, "notes")
            try touch(notes, "OBJECTIVE TO COMPLETE.rtf")
            #expect(!SessionScan.isSession(notes))
        }
    }
}
