import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// One ScreenCaptureKit stream feeding up to three consumers:
///
///     SCStream (single capture, single timebase)
///     ├── SCRecordingOutput ──────────> mixed.mp4    video + system audio
///     └── addStreamOutput(.audio) ────> system.caf   AAC stereo
///
///     AVAudioEngine (voice processing)
///     └── input tap ──────────────────> mic.caf      AAC mono, echo-cancelled
///
/// The mic used to be a third output on the SCStream, which is tidier but
/// records the speakers along with the speaker: ScreenCaptureKit hands over
/// the raw input and has no echo cancellation to ask for. See
/// `MicrophoneCapture`. Set `echo_cancellation: false` to put it back on the
/// stream, in which case mixed.mp4 gets the mic muxed in directly and the
/// diagram above collapses back to one capture.
///
/// With echo cancellation on, mixed.mp4 leaves the stream carrying system
/// audio only, and `Remux` swaps in the mixed track afterwards.
///
/// Note that SCStream always needs a content filter, so audio-only recording
/// still attaches to a display (see `configuration`) and still requires the
/// Screen Recording permission.
final class CaptureStream: NSObject, @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case noSources
        case displayUnavailable
        case windowUnavailable
        case noShareableContent(Error)

        var description: String {
            switch self {
            case .noSources:
                return "nothing selected to record"
            case .displayUnavailable:
                return "the selected display is no longer attached"
            case .windowUnavailable:
                return "the selected window is gone"
            case .noShareableContent(let e):
                return "can't read shareable content (\(e)). Check System Settings → Privacy & Security → Screen Recording"
            }
        }
    }

    struct Sources: Sendable, Equatable {
        var computerAudio: Bool
        var microphone: Bool
        var target: CaptureTarget

        var isEmpty: Bool { !computerAudio && !microphone && !target.capturesVideo }
    }

    private let sources: Sources
    private let capture: Config.Capture
    private let dir: URL
    private let sampleQueue = DispatchQueue(label: "us.stephenturner.trailmix.capture-samples")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private(set) var systemWriter: AudioTrackWriter?
    private(set) var micWriter: AudioTrackWriter?
    private var microphone: MicrophoneCapture?

    /// Whether the mic runs on its own voice-processing engine rather than on
    /// the SCStream. Read once at start so a config edit mid-session can't
    /// leave the stream configured one way and the teardown expecting another.
    private let echoCancellation = Config.current.echoCancellation

    private let lock = NSLock()
    private var videoStartedAt: Date?
    private var stoppedUnexpectedly: String?

    // Pause bookkeeping, all under `lock`.
    //
    // A pause does not stop the stream. SCRecordingOutput keeps writing
    // mixed.mp4 and the audio writers drop what they are handed, so the audio
    // tracks come out gapless while the video still holds the paused stretch.
    // What is kept here is *where* in the video each pause falls, on the
    // stream's own clock, so `Remux` can cut the same ranges out afterwards and
    // put the two back on one timeline.
    //
    // The sample timestamps are the only clock the recording output and this
    // code share. `firstPTS` is the earliest one the stream delivered, of any
    // type, taken as the file's time zero. `lastPTS` plus how much host time
    // has passed since it arrived gives "stream time now" at any moment, which
    // is what a pause is stamped with: it has to work on a static screen with
    // computer audio off, where no sample may arrive for seconds.
    private var paused = false
    private var firstPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var firstScreenPTS: CMTime?
    private var lastPTS: CMTime = .invalid
    private var lastPTSHost: CMTime = .invalid
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    /// The last pause ran into `stop()`. Its cut must reach the end of the
    /// file, not the last sample this delegate saw: the recorder writes on
    /// for roughly half a second after that while the capture comes down.
    private var pausedAtStop = false

    /// Set when the recording output reports the file closed, either way.
    /// `stopCapture()` returns before the video is finalized, so without
    /// waiting on this the file may not exist yet when RecordingSession goes
    /// looking for it. That is how a video recording ends up with no video
    /// in meta.json.
    private let videoFinalized = Latch()

    /// Called if the stream dies on its own (the captured window closed, the
    /// display was detached, a config change). Delivered on the main queue.
    var onUnexpectedStop: (@MainActor @Sendable (String) -> Void)?

    init(sources: Sources, capture: Config.Capture, dir: URL) {
        self.sources = sources
        self.capture = capture
        self.dir = dir
        super.init()
    }

    var videoURL: URL { dir.appendingPathComponent(SessionFiles.video) }

    /// Wall-clock start of the video track, or nil if video wasn't captured.
    var videoStart: Date? {
        lock.lock()
        defer { lock.unlock() }
        return videoStartedAt
    }

    /// Non-nil if the stream stopped on its own before `stop()` was called.
    var unexpectedStopReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return stoppedUnexpectedly
    }

    // MARK: - Pause

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    /// Stop writing audio and mark where in the video the gap begins. The
    /// stream itself keeps running; see the note on the pause fields. A no-op
    /// before `start()`, after `stop()`, or while already paused.
    func pause() {
        lock.lock()
        guard stream != nil, !paused else { lock.unlock(); return }
        paused = true
        pauses.append((start: streamNowLocked(), end: nil))
        lock.unlock()
        systemWriter?.setPaused(true)
        micWriter?.setPaused(true)
    }

    /// Resume writing audio and close the open gap. A no-op unless paused.
    func resume() {
        lock.lock()
        guard paused else { lock.unlock(); return }
        closePauseLocked()
        lock.unlock()
        systemWriter?.setPaused(false)
        micWriter?.setPaused(false)
    }

    /// Every pause so far, as ranges in the video file's own time (zero at the
    /// first sample the stream delivered). An open pause runs to now; a pause
    /// that ran into `stop()` runs to the end of the file (`end` is
    /// `+infinity`). This is what `RecordingSession` writes to meta.json as
    /// `paused_ms` and what `Remux` cuts out.
    var pausedRanges: [CMTimeRange] {
        lock.lock()
        defer { lock.unlock() }
        guard let origin = firstPTS else { return [] }
        let now = streamNowLocked()
        let openEnded = pausedAtStop ? pauses.indices.last : nil
        return pauses.enumerated().compactMap { index, pause in
            let start = CMTimeMaximum(pause.start - origin, .zero)
            if index == openEnded { return CMTimeRange(start: start, end: .positiveInfinity) }
            let end = CMTimeMaximum((pause.end ?? now) - origin, start)
            guard end > start else { return nil }
            return CMTimeRange(start: start, end: end)
        }
    }

    /// Lock held by the caller.
    private func streamNowLocked() -> CMTime {
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        guard lastPTS.isValid, lastPTSHost.isValid else { return host }
        return lastPTS + (host - lastPTSHost)
    }

    /// Synchronous on purpose: `stop()` is async and NSLock can't be taken
    /// from there, so it calls this instead.
    private func endPauseForStop() {
        lock.lock()
        if paused {
            pausedAtStop = true
            closePauseLocked()
        }
        lock.unlock()
    }

    /// Lock held by the caller.
    private func closePauseLocked() {
        paused = false
        if let last = pauses.indices.last, pauses[last].end == nil {
            pauses[last].end = streamNowLocked()
        }
    }

    /// Lock held by the caller. Called for every sample of every type.
    private func noteTimestampLocked(_ pts: CMTime, of type: SCStreamOutputType) {
        guard pts.isValid else { return }
        lastPTS = pts
        lastPTSHost = CMClockGetTime(CMClockGetHostTimeClock())
        if firstPTS == nil || pts < firstPTS! { firstPTS = pts }
        switch type {
        case .audio, .microphone: if firstAudioPTS == nil { firstAudioPTS = pts }
        case .screen: if firstScreenPTS == nil { firstScreenPTS = pts }
        @unknown default: break
        }
    }

    /// One log line with everything needed to check the pause cut points
    /// against the finished video: which sample set the file's zero, how far
    /// apart the two candidates were, and where the stream ended. Read it next
    /// to the finalized duration of mixed.mp4 if a cut ever lands off.
    private func logPauseCalibration() {
        lock.lock()
        let origin = firstPTS, audio = firstAudioPTS, screen = firstScreenPTS, end = lastPTS
        let ranges = pauses
        lock.unlock()
        guard !ranges.isEmpty, let origin else { return }
        let ms = { (t: CMTime?) -> String in t.map { String(Int(($0 - origin).seconds * 1000)) } ?? "none" }
        Log.info(
            "pause calibration · first audio \(ms(audio)) ms · first screen \(ms(screen)) ms "
                + "· last sample \(ms(end)) ms · pauses \(ranges.map { "\(ms($0.start))-\(ms($0.end))" }.joined(separator: " "))"
        )
    }

    func start() async throws {
        guard !sources.isEmpty else { throw CaptureError.noSources }

        let filter = try await contentFilter()
        let config = configuration(for: filter)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream

        if sources.computerAudio {
            let writer = AudioTrackWriter(
                url: dir.appendingPathComponent(SessionFiles.system),
                downmixToMono: false
            )
            systemWriter = writer
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if sources.microphone {
            let writer = AudioTrackWriter(
                url: dir.appendingPathComponent(SessionFiles.mic),
                downmixToMono: true
            )
            micWriter = writer
            if echoCancellation {
                // Off the SCStream entirely, since ScreenCaptureKit has no way
                // to ask for echo cancellation. The mic runs on its own engine.
                microphone = MicrophoneCapture(writer: writer)
            } else {
                try stream.addStreamOutput(
                    self, type: .microphone, sampleHandlerQueue: sampleQueue
                )
            }
        }
        if sources.target.capturesVideo {
            // Screen samples must be consumed for the recording output to
            // receive frames, even though we never touch them ourselves.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try addRecordingOutput(to: stream)
        }

        try await stream.startCapture()

        // After the stream, not before: a mic engine left running because the
        // stream failed to start is a live microphone with nothing recording
        // it. Failure here is reported but not fatal: a session with system
        // audio and video is worth more than no session.
        if let microphone {
            do {
                try microphone.start()
            } catch {
                // Unless the microphone was the whole recording. Degrading
                // there leaves a session that captures nothing at all: a 2×2
                // video nobody asked for, no audio, and a menu counting up the
                // elapsed time of a recording that isn't happening. Take the
                // stream back down and let the failure reach the click.
                guard sources.computerAudio || sources.target.capturesVideo else {
                    Log.warn("microphone capture failed to start, and it was the only source: \(error)")
                    // Taken down the ordinary stop path rather than by hand.
                    // stopCapture() has hung before, which is why stop() bounds
                    // it at five seconds and moves on; awaiting it raw here
                    // would hand the click an unbounded wait, and a start that
                    // never returns wedges the menu just as thoroughly as a
                    // stop that never returns. It also unwinds the half-started
                    // mic engine, which still has a tap to remove, and closes
                    // the empty writer instead of abandoning it.
                    await stop()
                    throw error
                }
                Log.warn("microphone capture failed to start: \(error)")
                notifyUser(
                    title: "trailmix: microphone unavailable",
                    body: "recording without it. \(error)"
                )
                self.microphone = nil
            }
        }
    }

    /// Stop capture and finalize every output. Idempotent.
    ///
    /// Bounded at every step. A stop that never returns leaves the menu stuck
    /// on "recording" with no way back short of quitting, which is a worse
    /// failure than a truncated file, so each wait gives up and moves on.
    func stop() async {
        guard let stream else { return }
        self.stream = nil

        // A stop while paused ends the pause at the stop: the gap runs to the
        // end of the video and gets cut like any other. Closed before the
        // capture comes down so "stream time now" is still anchored to a
        // sample that arrived moments ago.
        endPauseForStop()
        logPauseCalibration()

        // The mic engine is independent of the stream, so it comes down first
        // and on its own. Its writer is closed below with the others.
        microphone?.stop()
        microphone = nil

        // stopCapture() alone finalizes the video: "If stopCapture is called
        // without removing recordingOutput, recording will be stopped and
        // finish writing into the file" (SCStream.h). Removing the output
        // first, as this used to, starts a *second* finalization down a path
        // nobody observes, and is the difference between the audio-only stop
        // (which always worked) and the window-capture stop (which wedged).
        //
        // It runs detached because a stop that blocks must not block the
        // caller. Abandoning it leaks at most one task per stuck stop.
        let stopped = Latch()
        Task.detached(priority: .userInitiated) {
            do {
                try await stream.stopCapture()
            } catch {
                // Already stopped by the system (window closed, display
                // detached) is the common case and not worth reporting.
                Log.info("stopCapture: \(error.localizedDescription)")
            }
            stopped.set()
        }
        if await !stopped.wait(upTo: 5) {
            Log.warn("stopCapture() didn't return within 5s, continuing")
        }

        if recordingOutput != nil {
            // The file is closed asynchronously after capture stops.
            if await !videoFinalized.wait(upTo: 10) {
                Log.warn("\(SessionFiles.video) didn't finalize within 10s, it may not be playable")
            }
            recordingOutput = nil
        }

        systemWriter?.close()
        micWriter?.close()
    }

    // MARK: - Configuration

    private func addRecordingOutput(to stream: SCStream) throws {
        let config = SCRecordingOutputConfiguration()
        config.outputURL = videoURL
        // mp4 rather than mov. Both are offered and mov is the more Mac-native
        // of the two, but the point of this file is that someone can open it,
        // the same reason the audio mix is m4a and not caf. mp4 plays on
        // Windows, Android, and in a browser without help; .mov outside macOS
        // means "find VLC". It is also SCRecordingOutput's own default.
        //
        // The container is only half of that promise: HEVC inside mp4 still
        // needs a codec Windows does not always ship. `"codec": "h264"` in the
        // config is the lever for anyone who cares more about playing
        // everywhere than about halving the file size.
        if config.availableOutputFileTypes.contains(.mp4) {
            config.outputFileType = .mp4
        }
        // HEVC roughly halves the file for screen content. Fall back if the
        // system doesn't offer it.
        let preferred: AVVideoCodecType = capture.codec == "h264" ? .h264 : .hevc
        if config.availableVideoCodecTypes.contains(preferred) {
            config.videoCodecType = preferred
        }
        let output = SCRecordingOutput(configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        recordingOutput = output
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = sources.computerAudio
        // Keeps trailmix's own notification sounds out of the recording.
        config.excludesCurrentProcessAudio = true
        // Only when the mic is on the stream. With echo cancellation it comes
        // from MicrophoneCapture instead, and asking ScreenCaptureKit for it
        // as well would open the device twice and mux the raw, echoing signal
        // into the video.
        if sources.microphone, !echoCancellation {
            config.captureMicrophone = true
        }

        if sources.target.capturesVideo {
            // contentRect is in points; multiplying by pointPixelScale is what
            // gives true Retina pixel dimensions. Using SCDisplay.width/height
            // directly yields soft, downscaled video.
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(max(1, capture.fps))
            )
            config.showsCursor = true
            config.queueDepth = 6
        } else {
            // Audio-only still needs a filter and a video size. Make it as
            // cheap as possible and never consume the frames.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            config.queueDepth = 3
        }
        return config
    }

    /// The filter decides what video is captured *and*, as a side effect,
    /// whose audio is captured.
    ///
    /// ScreenCaptureKit scopes audio at the app level and never at the window
    /// level: "when a single window filter is used, all the audio content
    /// from the application that contains the window will be captured, even
    /// from those windows that are not present in the video output" (WWDC22,
    /// Take ScreenCaptureKit to the Next Level). So:
    ///
    ///   - `.none` and `.display` build display filters, and system.caf gets
    ///     every app on the machine except trailmix.
    ///   - `.window` gets that window's owning application and nothing else.
    ///     Record a Firefox window during a Zoom call and system.caf is
    ///     silent, with no error anywhere to say why.
    ///
    /// Decoupling the two would take a second SCStream, one filtered for
    /// video and one for audio. See the backlog in STATUS.md.
    private func contentFilter() async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.noShareableContent(error)
        }

        switch sources.target {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayUnavailable
            }
            return Self.filter(for: display, in: content)

        case .none:
            // Audio-only: any display works as the anchor.
            guard let display = content.displays.first else {
                throw CaptureError.displayUnavailable
            }
            return Self.filter(for: display, in: content)
        }
    }

    /// Whole-display capture with trailmix's own windows left out.
    ///
    /// A window filter only ever contains the one window, but a display filter
    /// takes everything on screen, including the capture outline drawn around
    /// the recorded area, which would be burned into the video it is marking.
    /// Excluding the app by identity also keeps the menu out of the frame.
    private static func filter(
        for display: SCDisplay,
        in content: SCShareableContent
    ) -> SCContentFilter {
        let own = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if own.isEmpty {
            // Only reachable if trailmix has no window ScreenCaptureKit can
            // see, which shouldn't happen while the status item exists. Worth
            // a line: it's the one condition under which the capture outline
            // ends up burned into a display recording.
            Log.warn("trailmix isn't in the shareable content list, so the capture outline may be recorded")
        }
        return SCContentFilter(
            display: display,
            excludingApplications: own,
            exceptingWindows: []
        )
    }
}

// MARK: - SCStreamOutput

extension CaptureStream: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Every sample, whatever its type, advances the stream clock the
        // pause ranges are stamped on. The writers do the dropping while
        // paused; nothing here changes with the pause state.
        lock.lock()
        if sampleBuffer.isValid {
            noteTimestampLocked(sampleBuffer.presentationTimeStamp, of: type)
        }
        lock.unlock()

        switch type {
        case .audio:
            systemWriter?.append(sampleBuffer)
        case .microphone:
            micWriter?.append(sampleBuffer)
        case .screen:
            // Consumed only so the recording output receives frames. Record
            // the first one as the video track's true start.
            lock.lock()
            if videoStartedAt == nil, sampleBuffer.isValid {
                videoStartedAt = Date()
            }
            lock.unlock()
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureStream: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stoppedUnexpectedly = error.localizedDescription
        lock.unlock()
        Log.warn("capture stream stopped: \(error.localizedDescription)")
        systemWriter?.close()
        micWriter?.close()
        let reason = error.localizedDescription
        if let handler = onUnexpectedStop {
            Task { @MainActor in handler(reason) }
        }
    }
}

// MARK: - SCRecordingOutputDelegate

extension CaptureStream: SCRecordingOutputDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.info("\(SessionFiles.video): recording started")
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        videoFinalized.set()
    }

    func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        // Unblocks stop() as well as reporting: a failed recording never
        // reaches didFinishRecording, and waiting the full timeout for a file
        // that is already known to be broken helps nobody.
        videoFinalized.set()
        Log.warn("screen recording failed: \(error.localizedDescription)")
        notifyUser(title: "trailmix: video recording failed", body: error.localizedDescription)
    }
}

/// A one-way latch with a bounded async wait.
///
/// Used where ScreenCaptureKit signals completion through a delegate callback
/// that may never arrive. A continuation would be tidier, but it has to be
/// resumed exactly once and these callbacks carry no such guarantee; polling a
/// flag can't trap the process by being resumed twice or never.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    /// Wait up to `seconds` for the flag. Returns whether it was ever set.
    func wait(upTo seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isSet {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
