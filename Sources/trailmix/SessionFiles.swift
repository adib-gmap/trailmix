import Foundation

/// The names of the files a session writes.
///
/// One place, because these strings were previously spelled out in five and a
/// rename meant finding all of them. They are also the app's contract with
/// whatever the user points at the folder next (an `on_stop` hook, a script,
/// a Finder habit), so changing one is a user-facing change, not a refactor.
enum SessionFiles {
    /// The two raw capture tracks. Separate on purpose: speech models do
    /// better on clean single-source audio, and one file per source is free
    /// two-party diarization.
    static let mic = "mic.caf"
    static let system = "system.caf"

    /// The two things a person actually opens. Both are named `mixed` because
    /// both contain every audio source the session captured; one happens to
    /// carry video as well.
    static let mixedAudio = "mixed.m4a"
    static let video = "mixed.mp4"

    /// Where the mix is exported before it is checked and moved onto
    /// `mixedAudio`. The final name is a completion marker, so nothing may wear
    /// it until the bytes behind it are known to be whole.
    static let mixTemp = "mix.tmp.m4a"

    /// What the video was called before 2026-08-04, and what recordings made
    /// before then still have on disk. Recovery and remuxing accept it so old
    /// sessions don't become unreadable; nothing writes it any more.
    static let legacyVideo = "screen.mov"

    static let meta = "meta.json"

    /// The three transcript files share a stem so they sort together and read
    /// as one set: the data, the readable rendering, and the record of how it
    /// went. It was `transcribe.log` until 2026-08-04, which sorted away from
    /// the other two and named the verb rather than the thing.
    static let transcript = "transcript.json"
    static let readableTranscript = "transcript.md.txt"
    static let transcriptLog = "transcript.log"

    /// The session's video, whichever name it was written under.
    static func video(in dir: URL) -> URL? {
        for name in [video, legacyVideo] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
