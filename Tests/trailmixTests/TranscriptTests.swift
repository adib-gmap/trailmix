import Foundation
import Testing

@testable import trailmix

/// `transcript.json` is a commit marker, not just an output file.
///
/// `resumePending` skips any session that has one, so whatever is written
/// before it has to be on disk by the time it lands. It was the other way round
/// until now: the JSON went first, and a process that died between the two
/// writes left a session permanently marked finished with no readable
/// transcript in it and nothing that would ever retry.
@Suite("Transcript")
struct TranscriptTests {

    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailmix-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func transcript() -> Transcript {
        Transcript(
            engine: "parakeet",
            model: "parakeet-tdt-0.6b-v2",
            created_at: "2026-08-07T12:00:00Z",
            segments: [
                Transcript.Segment(speaker: "mic", start_ms: 0, end_ms: 1500, text: "morning"),
                Transcript.Segment(
                    speaker: "system", start_ms: 1500, end_ms: 3000, text: "morning to you"
                ),
            ]
        )
    }

    @Test("both files are written")
    func writesBoth() throws {
        try inTemporaryDirectory { dir in
            try transcript().write(to: dir)

            let readable = try String(
                contentsOf: dir.appendingPathComponent(SessionFiles.readableTranscript),
                encoding: .utf8
            )
            #expect(readable.contains("**[0:00] Mic:** morning"))
            #expect(readable.contains("**[0:01] System:** morning to you"))
            #expect(readable.hasPrefix("# \(dir.lastPathComponent)"))

            let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.transcript))
            let decoded = try JSONDecoder().decode(Transcript.self, from: data)
            #expect(decoded.segments.count == 2)
        }
    }

    /// The ordering itself, forced rather than reasoned about: a directory
    /// sitting where `transcript.md.txt` should go makes the first write throw,
    /// and the commit marker must not exist afterwards.
    @Test("a failed readable write leaves no transcript.json behind")
    func jsonIsTheCommitMarker() throws {
        try inTemporaryDirectory { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(SessionFiles.readableTranscript),
                withIntermediateDirectories: true
            )

            #expect(throws: (any Error).self) { try transcript().write(to: dir) }
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(SessionFiles.transcript).path
                ),
                "the session was marked done with half its output missing"
            )
        }
    }

    /// The repair for sessions transcribed under the old order, which have the
    /// data and nothing anyone can double-click. Re-rendering costs a file read
    /// rather than another pass over the audio.
    @Test("a missing readable transcript is re-rendered from the json")
    func readableIsRestored() throws {
        try inTemporaryDirectory { dir in
            let encoder = JSONEncoder()
            try encoder.encode(transcript())
                .write(to: dir.appendingPathComponent(SessionFiles.transcript))

            Transcript.restoreReadable(in: dir)

            let readable = try String(
                contentsOf: dir.appendingPathComponent(SessionFiles.readableTranscript),
                encoding: .utf8
            )
            #expect(readable.contains("**[0:00] Mic:** morning"))
        }
    }

    @Test("an existing readable transcript is left alone")
    func restoreDoesNotOverwrite() throws {
        try inTemporaryDirectory { dir in
            let readable = dir.appendingPathComponent(SessionFiles.readableTranscript)
            try Data("hand edited".utf8).write(to: readable)
            try JSONEncoder().encode(transcript())
                .write(to: dir.appendingPathComponent(SessionFiles.transcript))

            Transcript.restoreReadable(in: dir)

            #expect(try String(contentsOf: readable, encoding: .utf8) == "hand edited")
        }
    }

    /// Nothing to restore from, and nothing to say about it. A session that
    /// never transcribed reaches this on every launch.
    @Test("no transcript.json means nothing is written")
    func restoreWithoutJsonIsANoOp() throws {
        try inTemporaryDirectory { dir in
            Transcript.restoreReadable(in: dir)
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(SessionFiles.readableTranscript).path
                )
            )
        }
    }
}
