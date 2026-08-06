import Foundation
import os

/// Diagnostics that survive a Finder launch.
///
/// stderr is the natural place for these, and `make run` still shows it, but an
/// app started from Finder or at login has fd 2 pointing at /dev/null. Every
/// warning the daemon writes is then lost at exactly the moment it matters:
/// a capture that failed to start, a video that never finalized, a
/// transcription that threw.
///
/// So everything goes three places. stderr for `make run`. The unified log,
/// which costs nothing and is where a macOS app is supposed to put this. And
/// `~/Library/Logs/trailmix.log`, which is the one that actually works here:
/// `log stream` requires admin and `log show` needs the local store readable,
/// neither of which holds on a non-admin account. A plain file needs no
/// privilege at all.
///
///     tail -f ~/Library/Logs/trailmix.log
enum Log {
    private static let logger = Logger(
        subsystem: "us.stephenturner.trailmix",
        category: "daemon"
    )

    static let fileURL = Paths.log

    /// Truncate above this and start over. A daemon that runs for months
    /// shouldn't grow a log file forever, and nothing here is worth
    /// the complexity of real rotation.
    private static let maxBytes = 1 << 20  // 1 MB

    /// Serializes appends: writers come from the main actor, the capture
    /// sample queue, and the transcription actor.
    private static let queue = DispatchQueue(label: "us.stephenturner.trailmix.log")

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Normal progress: recording started, stopped, transcript written.
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        emit(message)
    }

    /// Something went wrong. Not necessarily fatal, since most of the daemon
    /// degrades rather than stops, but worth finding later.
    static func warn(_ message: String) {
        logger.error("\(message, privacy: .public)")
        emit("warning: \(message)")
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        let line = "\(timestamp.string(from: Date())) \(message)\n"
        queue.async { append(line) }
    }

    /// Best effort throughout. A daemon that can't write its log should keep
    /// recording, not fall over.
    private static func append(_ line: String) {
        let fm = FileManager.default
        let path = fileURL.path
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(line.utf8).write(to: fileURL)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > UInt64(maxBytes) {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
