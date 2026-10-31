import AVFoundation
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "mic", system.caf → "system"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md.txt (readable). The filesystem is the queue:
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcript.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    enum TranscribeError: Error, CustomStringConvertible {
        case everyTrackFailed(Int)
        case nothingToTranscribe

        var description: String {
            switch self {
            case .everyTrackFailed(let count):
                return "all \(count) track(s) failed to transcribe"
            case .nothingToTranscribe:
                return "no audio track named in \(SessionFiles.meta) is on disk"
            }
        }
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    /// How many sessions are waiting to be transcribed.
    ///
    /// A test seam. Whether `resumePending` queued a session or only repaired
    /// its media is the distinction the whole method turns on, and from outside
    /// the two look identical: both leave a folder with a transcript in it.
    var queuedCount: Int { queue.count }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, or a
    /// video-only session with no audio to transcribe, the on_stop hook still
    /// fires; it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.current.transcriptionEnabled else {
            log(sessionDir, "not transcribing: disabled in config")
            runHook(for: sessionDir)
            return
        }
        guard !audioTracks(in: sessionDir).isEmpty else {
            log(sessionDir, "not transcribing: no audio tracks on disk")
            runHook(for: sessionDir)
            return
        }
        log(sessionDir, "queued for transcription")
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for unfinished work: anything that either
    /// stopped cleanly (meta.json) or still has media on disk. Folder names
    /// sort chronologically, so oldest-first is a name sort.
    ///
    /// Two separate questions get asked of every session it finds, and they are
    /// deliberately not the same question. transcript.json decides whether the
    /// audio needs transcribing; the mix and the swap have their own markers
    /// and are repaired whatever the transcript says. Treating the transcript
    /// as the one marker for the whole session is a bug this had: a session
    /// whose remux failed but whose transcription then succeeded was skipped
    /// here on every later launch, so its mixed.mp4 never got the microphone
    /// and nothing was ever going to give it one.
    ///
    /// Only called from AppController.init, before the run loop starts and so
    /// before any menu click could begin a recording. That ordering matters:
    /// a live session looks exactly like a crashed one (audio, no meta.json),
    /// so calling this while recording would transcribe a session mid-flight
    /// and leave a truncated transcript.json in its place.
    ///
    /// It awaits repairs now, so it can be in flight for a while, but the scan
    /// itself still runs to completion before the first suspension point. A
    /// recording started while this is repairing an older session is therefore
    /// not in the list and cannot be touched by it.
    func resumePending(root: URL) async {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        var pending: [URL] = []
        var transcribed: Set<URL> = []
        for dir in entries {
            if fm.fileExists(atPath: dir.appendingPathComponent(SessionFiles.transcript).path) {
                // Transcribed, unless the readable rendering is missing:
                // transcript.json is written last precisely so that it means
                // "finished", but a session transcribed before that ordering
                // was fixed can have the JSON and nothing anyone can
                // double-click. Re-render it from the data rather than
                // transcribing the audio again.
                Transcript.restoreReadable(in: dir)
                transcribed.insert(dir)
            }
            // A folder counts as a session if it stopped cleanly or still has
            // media in it. No meta.json means the process died before it could
            // stop cleanly; the audio is still good, since CAF needs no
            // finalization pass, so recover it rather than orphaning it
            // forever. (the video will be unplayable in that case; mp4 does
            // need finalizing. It's still recorded in the metadata.)
            if fm.fileExists(atPath: dir.appendingPathComponent(SessionFiles.meta).path)
                || !sessionFiles(in: dir).isEmpty
            {
                pending.append(dir)
            }
        }
        pending.sort { $0.lastPathComponent < $1.lastPathComponent }

        let transcribing = Config.current.transcriptionEnabled
        var resumed = 0
        var repairOnly: [URL] = []
        for dir in pending where !queue.contains(dir) {
            if !fm.fileExists(atPath: dir.appendingPathComponent(SessionFiles.meta).path) {
                do {
                    try recoverMeta(at: dir)
                    log(dir, "recovered meta.json: session never stopped cleanly")
                } catch {
                    log(dir, "can't recover meta.json: \(error)")
                    continue
                }
            }
            // Recovery is worth doing for any session, but only untranscribed
            // audio is worth transcribing. Queueing a video-only session would
            // load ~600 MB of model to produce an empty transcript, every
            // launch, and queueing an already-transcribed one would overwrite
            // a finished transcript with a second run of the same audio.
            guard transcribing, !transcribed.contains(dir), !audioTracks(in: dir).isEmpty else {
                // Everything the queue will never see: sessions that already
                // have a transcript, video-only sessions, and every session at
                // all when transcription is switched off. The mix and the
                // remux have nothing to do with transcribing, so these still
                // get repaired. Before this they were stuck forever, since the
                // drain was the only thing that repaired anything and they
                // never reached it.
                repairOnly.append(dir)
                continue
            }
            queue.append(dir)
            resumed += 1
        }
        if resumed > 0 {
            Log.info("resuming \(resumed) untranscribed session(s)")
        }
        // Before the repairs, not after: a queued session is repaired at the
        // top of its own drain job, and making transcription wait on the
        // mixdown of a folder it isn't going to read would be backwards.
        drainIfIdle()
        for dir in repairOnly {
            await repairMixedFiles(in: dir)
        }
    }

    /// The audio track files a session directory actually has on disk, keyed
    /// the way meta.json keys them.
    private func audioTracks(in dir: URL) -> [String: String] {
        let fm = FileManager.default
        return ["mic": SessionFiles.mic, "system": SessionFiles.system].filter {
            fm.fileExists(atPath: dir.appendingPathComponent($0.value).path)
        }
    }

    /// Every media file a session has, audio plus video. Video counts as
    /// evidence that a folder is a real session: a video-only recording has no
    /// .caf files at all, and judging by audio alone would orphan it forever.
    private func sessionFiles(in dir: URL) -> [String: String] {
        var files = audioTracks(in: dir)
        // Whichever name the video was written under. A session recorded
        // before the rename still has screen.mov, and judging it by the
        // current name alone would orphan it.
        if let video = SessionFiles.video(in: dir) {
            files["video"] = video.lastPathComponent
        }
        return files
    }

    /// Reconstruct a minimal meta.json for a session killed before it wrote
    /// one: SIGKILL, a panic, a power loss, the cases no signal handler can
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
        // Audio only: AVAudioFile can't read the video, and a hard-killed one
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
        try data.write(to: dir.appendingPathComponent(SessionFiles.meta), options: .atomic)
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
            // Where a recovered session gets its mixed files: it reached this
            // queue without ever passing through `stopSession`, which is what
            // builds them for a session that stopped normally. A no-op for one
            // that did, and for anything already repaired.
            await repairMixedFiles(in: dir)
            do {
                try await transcribe(dir)
                notifyUser(
                    title: "trailmix: transcript ready",
                    body: dir.lastPathComponent,
                    reveal: dir
                )
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "trailmix: transcription failed",
                    body: "\(dir.lastPathComponent), see \(SessionFiles.transcriptLog)",
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

    /// Build `mixed.m4a` (and swap it into the video) for a session that never
    /// got one.
    ///
    /// `AppController.stopSession` runs the mix and the remux before it
    /// enqueues, so for a session that stopped normally this finds the file
    /// already there and does nothing. The case it exists for is the one that
    /// didn't stop normally: a session recovered by `resumePending` reached
    /// this queue without ever passing through `stopSession`, and so had the
    /// tracks and eventually a transcript but no playable audio file at all.
    /// Same for a session that crashed in the window between `meta.json` and
    /// the mix. Nothing else regenerated either of them.
    ///
    /// Safe to reach for on every job: each step is guarded on its own
    /// completion, so this never re-encodes a finished mix or re-swaps a video
    /// that already carries one.
    ///
    /// Those guards live in `Mixdown.run` and `Remux.alreadySwapped`, and not
    /// also here. A second copy of the mix guard is what this had, and it was
    /// wrong in the way duplicated guards usually are: it tested existence
    /// while the real one tests readability, so it took the decision away from
    /// the code that knew better. A `mixed.m4a` left half-written by an
    /// interrupted export never reached the check that would have rebuilt it,
    /// and `Remux` then refused it on every launch, correctly and forever.
    ///
    /// The two steps are guarded *separately*, which is the whole point. The
    /// presence of `mixed.m4a` used to stand for both, so a session that
    /// crashed in the window between the mixdown and the swap, or whose swap
    /// failed once, returned here and was declared finished on every later
    /// launch: `mixed.mp4` kept the system audio it came off the stream with
    /// and never got the microphone. `Remux` records the swap in meta.json
    /// after it lands, and that marker is what closes it.
    private func repairMixedFiles(in dir: URL) async {
        await Mixdown.run(in: dir)

        // `Remux.finalize` decides what the video still needs: the mix swapped
        // in if one got built, or just its pauses cut out if there is no mix
        // to swap (a video-only session), each behind its own marker. A
        // hard-killed session's video is unfinalized and unreadable, so it
        // warns and leaves it alone, which is the honest outcome.
        await Remux.finalize(in: dir)
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let fm = FileManager.default
        var tracks: [SessionMeta.Track] = []
        for track in meta.tracks {
            if fm.fileExists(atPath: dir.appendingPathComponent(track.file).path) {
                tracks.append(track)
            } else {
                log(dir, "skipping missing track \(track.file)")
            }
        }
        // Established before the model loads, and separately from the failure
        // count below, because those are two different nothings. A session with
        // no readable track cannot produce a transcript, and writing an empty
        // one anyway would commit transcript.json: the session would be marked
        // finished forever, the menu would say "transcript ready", and the file
        // would say nothing was ever said. Throwing here costs a retry next
        // launch and no model load.
        guard !tracks.isEmpty else { throw TranscribeError.nothingToTranscribe }

        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var attempted = 0
        var succeeded = 0
        for track in tracks {
            let audio = dir.appendingPathComponent(track.file)
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript, so log it and keep going.
            attempted += 1
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            succeeded += 1
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

        // Every track threw. Writing the transcript anyway would commit an
        // empty one, with the same permanent, silent result as above. A model
        // that failed to load, or a session whose tracks are all truncated,
        // deserves the retry on the next launch. Zero segments from a track
        // that transcribed fine is a different thing entirely, and still
        // succeeds: silence really does transcribe to nothing.
        //
        // No `attempted == 0` escape here. There is at least one track on disk
        // by this point, so the only way to attempt nothing is for it to
        // vanish mid-run, and a transcript committed on the strength of that
        // is exactly the empty one this is meant to prevent.
        guard succeeded > 0 else {
            throw TranscribeError.everyTrackFailed(attempted)
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done: \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.current.transcriptionEngine
        if configured != "parakeet" {
            Log.warn("unknown transcription engine \"\(configured)\", using parakeet")
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
        let url = dir.appendingPathComponent(SessionFiles.transcriptLog)
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
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0;
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

/// Canonical transcript. Property names are the JSON schema: this struct
/// exists to be serialized.
///
/// Internal rather than private so the tests can drive `write` and
/// `restoreReadable` directly. Which file lands first is the whole difference
/// between a session that can be retried and one permanently marked done, and
/// that is not something the coordinator can be asked about from outside.
struct Transcript: Codable {
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

    /// Write the readable rendering and then transcript.json. Both writes are
    /// atomic (temp file + rename), so a partially written transcript never
    /// exists on disk, and resumePending treats presence of transcript.json as
    /// "done".
    ///
    /// The order is that way round because of what "done" means. transcript.json
    /// is the commit marker, so it has to be the last thing written: with the
    /// JSON first, a process that died between the two writes left a session
    /// permanently marked finished with no readable transcript in it, and
    /// nothing would ever retry it.
    ///
    /// The readable one is `transcript.md.txt`, not `transcript.md`. It is
    /// markdown and the double extension keeps that visible, but `.txt` is
    /// what makes it open in something on a Mac that has never had a markdown
    /// editor installed. A file nobody can double-click is not readable.
    func write(to dir: URL) throws {
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.readableTranscript), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent(SessionFiles.transcript), options: .atomic)
    }

    /// Re-render `transcript.md.txt` from `transcript.json` when the data is
    /// there and the readable file isn't.
    ///
    /// For sessions transcribed before the write order above was fixed. The
    /// JSON holds everything the rendering is made of, so this costs a file
    /// read rather than another pass over the audio, and it is a no-op the
    /// moment either file is in the state it should be.
    static func restoreReadable(in dir: URL) {
        let readable = dir.appendingPathComponent(SessionFiles.readableTranscript)
        guard !FileManager.default.fileExists(atPath: readable.path) else { return }
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.transcript)),
            let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { return }
        do {
            try Data(transcript.rendered(title: dir.lastPathComponent).utf8)
                .write(to: readable, options: .atomic)
            Log.info("\(dir.lastPathComponent): re-rendered \(SessionFiles.readableTranscript)")
        } catch {
            Log.warn("\(dir.lastPathComponent): can't re-render \(SessionFiles.readableTranscript): \(error)")
        }
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", ""]
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
