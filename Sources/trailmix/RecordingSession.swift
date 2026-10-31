import Foundation

/// One recording: a timestamped folder holding whichever tracks were enabled,
/// plus a meta.json written on clean stop.
///
/// Audio tracks stay separate on purpose. Speech models do better on clean
/// single-source audio, and mic-vs-system is free two-party diarization,
/// "mic" vs "system", with no speaker-identification model. Video, when captured, is
/// muxed with audio into mixed.mp4 so it plays standalone.
///
/// Main-actor isolated: it's created and torn down from AppController, and
/// pinning it there keeps the non-Sendable session from crossing an isolation
/// boundary on the async stop path. The concurrent work all lives behind
/// CaptureStream, which is Sendable.
@MainActor
final class RecordingSession {
    let dir: URL
    let startedAt = Date()
    let sources: CaptureStream.Sources

    private let stream: CaptureStream
    /// Wall-clock side of the pauses: the elapsed counter, the limit and
    /// `duration_seconds` all read recorded time from here. The stream keeps
    /// the other side, where each pause falls in the video.
    private var ledger = PauseLedger()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL, sources: CaptureStream.Sources, capture: Config.Capture) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        self.sources = sources
        stream = CaptureStream(sources: sources, capture: capture, dir: candidate)
    }

    /// Notified if capture dies on its own, e.g. the captured window closed.
    var onUnexpectedStop: (@MainActor @Sendable (String) -> Void)? {
        get { stream.onUnexpectedStop }
        set { stream.onUnexpectedStop = newValue }
    }

    func start() async throws {
        try await stream.start()
    }

    // MARK: - Pause

    var isPaused: Bool { ledger.isPaused }
    var pauseCount: Int { ledger.count }

    /// Stop writing audio and mark the gap in the video. Capture keeps
    /// running: see `CaptureStream.pause`. Nothing to await.
    func pause() {
        guard !ledger.isPaused else { return }
        ledger.pause(at: Date())
        stream.pause()
    }

    func resume() {
        guard ledger.isPaused else { return }
        ledger.resume(at: Date())
        stream.resume()
    }

    /// How much has actually been recorded: wall clock minus the pauses. The
    /// number the menu counts, the limit measures, and meta.json reports.
    func recordedElapsed(at now: Date = Date()) -> TimeInterval {
        ledger.recorded(since: startedAt, at: now)
    }

    func pausedTotal(at now: Date = Date()) -> TimeInterval {
        ledger.pausedTotal(at: now)
    }

    /// Stop capture and write meta.json.
    func stop() async {
        // A stop while paused ends the pause here, before the stream comes
        // down, so the paused total doesn't absorb however long the stop takes.
        if ledger.isPaused { ledger.resume(at: Date()) }
        await stream.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each lags
        // the earliest so transcript timestamps share one clock.
        var starts: [String: Date] = [:]
        var files: [String: String] = [:]
        if let writer = stream.systemWriter, writer.wroteAnything {
            files["system"] = SessionFiles.system
            starts["system"] = writer.firstBufferAt ?? startedAt
        }
        if let writer = stream.micWriter, writer.wroteAnything {
            files["mic"] = SessionFiles.mic
            starts["mic"] = writer.firstBufferAt ?? startedAt
        }
        if sources.target.capturesVideo {
            // Size, not just existence: SCRecordingOutput creates the file when
            // recording starts, so a capture that failed immediately leaves a
            // zero-byte video behind. Recording that in meta.json as a
            // video track is how a session ends up promising a video that
            // won't open.
            let size = (try? FileManager.default.attributesOfItem(
                atPath: stream.videoURL.path
            ))?[.size] as? Int ?? 0
            if size > 0 {
                files["video"] = SessionFiles.video
                starts["video"] = stream.videoStart ?? startedAt
            } else {
                Log.warn("video was requested but \(SessionFiles.video) is empty or missing")
            }
        }

        let earliest = starts.values.min() ?? startedAt
        let offsets = starts.mapValues { Int($0.timeIntervalSince(earliest) * 1000) }

        // `duration_seconds` is recorded time: with no pauses that is
        // `ended - started`, exactly what it always was. With pauses it is
        // what the files actually hold, which is the number anyone opening the
        // folder wants, and the wall-clock span is still there in the two
        // timestamps.
        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ledger.recorded(since: startedAt, at: ended)),
            "files": files,
            "start_offset_ms": offsets,
            "sources": [
                "computer_audio": sources.computerAudio,
                "microphone": sources.microphone,
                "video": sources.target.capturesVideo,
            ],
        ]
        if let reason = stream.unexpectedStopReason {
            meta["stopped_unexpectedly"] = reason
        }
        // Only when there were pauses, so an unpaused session's meta.json is
        // what it was before pausing existed. `paused_ms` is in the video
        // file's own time and is what `Remux` cuts out; the audio tracks were
        // never written during these ranges, so they need nothing. An end of
        // -1 is a pause that ran into the stop: it reaches the end of the file.
        if ledger.count > 0 {
            meta["paused_seconds"] = Int(ledger.pausedTotal(at: ended))
            meta["paused_ms"] = stream.pausedRanges.map { range in
                [
                    Int((range.start.seconds * 1000).rounded()),
                    range.end.isPositiveInfinity ? -1 : Int((range.end.seconds * 1000).rounded()),
                ]
            }
        }

        // Atomic, like every other write to this file. Its mere presence is
        // what tells `resumePending` the session stopped cleanly, so a
        // half-written one would mark a session done and then fail to parse.
        //
        // Reported rather than swallowed. This file is the recovery boundary:
        // without it the session is indistinguishable from one that was killed
        // mid-recording, and the offsets that align the transcript and the mix
        // are gone for good, since they can't be reconstructed after the fact.
        // A recording that lost its metadata still transcribes, so this is a
        // warning and not a failure, but it is not nothing and it used to pass
        // in complete silence.
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dir.appendingPathComponent(SessionFiles.meta), options: .atomic)
        } catch {
            Log.warn("\(dir.lastPathComponent): couldn't write \(SessionFiles.meta): \(error)")
            notifyUser(
                title: "trailmix: recording metadata not saved",
                body: "The audio is fine, but track alignment was lost. \(error.localizedDescription)",
                reveal: dir
            )
        }
    }

    /// Tracks whose writes failed, for a post-recording warning. A full disk
    /// otherwise produces a truncated recording with no visible signal.
    var failedTracks: [String] {
        var failed: [String] = []
        if stream.systemWriter?.hadFailure == true { failed.append("system") }
        if stream.micWriter?.hadFailure == true { failed.append("mic") }
        return failed
    }
}
