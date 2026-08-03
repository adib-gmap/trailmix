import AVFoundation
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "mic", system.caf → "system"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md.txt (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, or a
    /// video-only session with no audio to transcribe, the on_stop hook still
    /// fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.current.transcriptionEnabled else {
            log(sessionDir, "not transcribing — disabled in config")
            runHook(for: sessionDir)
            return
        }
        guard !audioTracks(in: sessionDir).isEmpty else {
            log(sessionDir, "not transcribing — no audio tracks on disk")
            runHook(for: sessionDir)
            return
        }
        log(sessionDir, "queued for transcription")
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that were never transcribed:
    /// anything without a transcript.json that either stopped cleanly
    /// (meta.json) or still has audio on disk. Folder names sort
    /// chronologically, so oldest-first is a name sort.
    ///
    /// Only called from AppController.init, before the run loop starts and so
    /// before any menu click could begin a recording. That ordering matters:
    /// a live session looks exactly like a crashed one (audio, no meta.json),
    /// so calling this while recording would transcribe a session mid-flight
    /// and leave a truncated transcript.json in its place.
    func resumePending(root: URL) {
        guard Config.current.transcriptionEnabled else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        var pending: [URL] = []
        for dir in entries {
            if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                continue
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {
                pending.append(dir)
            } else if !sessionFiles(in: dir).isEmpty {
                // No meta.json means the process died before it could stop
                // cleanly. The audio is still good — CAF needs no finalization
                // pass — so recover it rather than orphaning it forever.
                // (screen.mov will be unplayable in that case; MOV does need
                // finalizing. It's still recorded in the metadata.)
                pending.append(dir)
            }
        }
        pending.sort { $0.lastPathComponent < $1.lastPathComponent }

        var resumed = 0
        for dir in pending where !queue.contains(dir) {
            if !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {
                do {
                    try recoverMeta(at: dir)
                    log(dir, "recovered meta.json — session never stopped cleanly")
                } catch {
                    log(dir, "can't recover meta.json: \(error)")
                    continue
                }
            }
            // Recovery is worth doing for any session, but only audio can be
            // transcribed. Queueing a video-only session would load ~600 MB of
            // model to produce an empty transcript, every launch.
            guard !audioTracks(in: dir).isEmpty else { continue }
            queue.append(dir)
            resumed += 1
        }
        if resumed > 0 {
            Log.info("resuming \(resumed) untranscribed session(s)")
        }
        drainIfIdle()
    }

    /// The audio track files a session directory actually has on disk, keyed
    /// the way meta.json keys them.
    private func audioTracks(in dir: URL) -> [String: String] {
        let fm = FileManager.default
        return ["mic": "mic.caf", "system": "system.caf"].filter {
            fm.fileExists(atPath: dir.appendingPathComponent($0.value).path)
        }
    }

    /// Every media file a session has, audio plus video. Video counts as
    /// evidence that a folder is a real session: a video-only recording has no
    /// .caf files at all, and judging by audio alone would orphan it forever.
    private func sessionFiles(in dir: URL) -> [String: String] {
        var files = audioTracks(in: dir)
        let video = "screen.mov"
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(video).path) {
            files["video"] = video
        }
        return files
    }

    /// Reconstruct a minimal meta.json for a session killed before it wrote
    /// one — SIGKILL, a panic, a power loss, the cases no signal handler can
    /// catch. Timestamps are estimated from the filesystem and marked as such;
    /// per-track offsets are unknowable after the fact and default to 0, which
    /// is what SessionMeta.read already assumes for sessions recorded before
    /// offsets were captured.
    private func recoverMeta(at dir: URL) throws {
        let fm = FileManager.default
        let iso = ISO8601DateFormatter()
        let files = sessionFiles(in: dir)
        let audio = audioTracks(in: dir)

        // The folder is created at the moment recording starts, so its creation
        // date is the real session start. Duration comes from the audio itself
        // rather than file timestamps, which only bound when writing stopped.
        let started = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date
        // Audio only: AVAudioFile can't read screen.mov, and a hard-killed one
        // is unfinalized anyway, so its duration is unknowable here.
        let duration = audio.values
            .compactMap { name -> TimeInterval? in
                // AVAudioFile(forReading:) is the same probe ParakeetEngine
                // uses; a zero-length track is unreadable rather than fatal.
                guard
                    let track = try? AVAudioFile(forReading: dir.appendingPathComponent(name)),
                    track.length > 0, track.fileFormat.sampleRate > 0
                else { return nil }
                return Double(track.length) / track.fileFormat.sampleRate
            }
            .max()

        var meta: [String: Any] = [
            "recovered": true,
            "files": files,
            "start_offset_ms": files.mapValues { _ in 0 },
        ]
        if let started { meta["started"] = iso.string(from: started) }
        if let duration {
            // Truncated, matching how RecordingSession.stop() writes the field.
            meta["duration_seconds"] = Int(duration)
            if let started {
                meta["ended"] = iso.string(from: started.addingTimeInterval(duration))
            }
        }

        let data = try JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(
                    title: "trailmix — transcript ready",
                    body: dir.lastPathComponent,
                    reveal: dir
                )
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "trailmix — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log",
                    reveal: dir
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.current.transcriptionEngine
        if configured != "parakeet" {
            Log.warn("unknown transcription engine \"\(configured)\" — using parakeet")
        }
        let engine = ParakeetEngine()
        // The first load of the session compiles ~440 MB of Core ML weights for
        // the ANE and can run to the better part of a minute with no output at
        // all. Bracketing it is the difference between "slow" and "hung".
        Log.info("loading transcription model…")
        try await engine.prepare()
        Log.info("transcription model ready")
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.current.onStop else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        Log.info("\(dir.lastPathComponent): \(message)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        // Named for the source, not for who is presumably behind it. "me" and
        // "them" claim more than the recorder knows: with no echo cancellation
        // the mic picks up whatever the speakers are playing, so a track
        // labelled "me" routinely contains the other side of the call.
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "mic", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "system", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and the readable rendering. Both writes are
    /// atomic (temp file + rename), so a partially written transcript never
    /// exists on disk — resumePending treats presence of transcript.json as
    /// "done".
    ///
    /// The readable one is `transcript.md.txt`, not `transcript.md`. It is
    /// markdown and the double extension keeps that visible, but `.txt` is
    /// what makes it open in something on a Mac that has never had a markdown
    /// editor installed. A file nobody can double-click is not readable.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md.txt"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(Self.label(seg.speaker)):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// transcript.json keys speakers the way meta.json keys the tracks; the
    /// rendering capitalizes them for reading.
    private static func label(_ speaker: String) -> String {
        switch speaker {
        case "mic": return "Mic"
        case "system": return "System"
        default: return speaker
        }
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
