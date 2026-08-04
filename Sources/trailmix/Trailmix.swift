import AppKit
import ArgumentParser
import Foundation

/// Real entry point.
///
/// Trailmix is launched two ways and both have to work. A double-click in
/// /Applications comes through LaunchServices, which may append process-serial
/// arguments like `-psn_0_12345` that ArgumentParser would reject as unknown
/// options — the app would exit before ever reaching the menu bar. Running the
/// executable inside the bundle from Terminal is the developer path and still
/// wants `doctor` and `run --out`.
///
/// Stripping the LaunchServices noise leaves an empty argument list on a
/// Finder launch, which `defaultSubcommand: Run.self` turns into the daemon.
@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
            .filter { !$0.hasPrefix("-psn_") }
        Trailmix.main(args)
    }
}

struct Trailmix: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trailmix",
        abstract: "Local recorder + transcriber. Captures computer audio, microphone, and a window or display, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Mic.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        MainActor.assumeIsolated { runMain() }
    }

    @MainActor
    private func runMain() {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so a failing
        // check here is informational, not fatal. Launched from Finder there is
        // no terminal to print to and no exit code anyone will ever see — the
        // app would just vanish on double-click with no explanation. Report it
        // and carry on; the failures ride into the menu, which is the only
        // surface the user actually sees.
        let checks = DoctorReport.run(recordingsRoot: root)
        let failures = DoctorReport.failures(checks)
        if !failures.isEmpty {
            let report = (["startup checks failed (continuing anyway):"]
                + DoctorReport.rendered(checks)).joined(separator: "\n")
            Log.warn(report)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root, warnings: failures)

        // ^C sends SIGINT; launchd sends SIGTERM on logout, shutdown, and
        // `launchctl bootout`. Both have to reach the same clean shutdown —
        // an unhandled SIGTERM kills the process before RecordingSession.stop()
        // writes meta.json, which used to strand the recording permanently.
        let signalSources = [SIGINT, SIGTERM].map { signum -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: signum, queue: .main)
            source.setEventHandler {
                Log.info("shutting down")
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            // Suppress the default disposition (terminate) now that the
            // dispatch source owns the signal.
            signal(signum, SIG_IGN)
            return source
        }

        Log.info("trailmix up · recordings → \(root.path) · ^C to quit")
        // The sources are only referenced by this local; releasing them would
        // silently restore default signal handling.
        withExtendedLifetime(signalSources) {
            app.run()
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check screen-recording and microphone permissions, recordings folder, and models."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    /// Mutable: the menu can move it. Only ever read at the moment a
    /// recording starts, so a change mid-session can't strand one.
    private var root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let modelDownload = ModelDownload()
    private let overlay = CaptureOverlay()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var busy = false
    private var terminating = false

    /// `warnings` are failed startup checks, shown in the menu. They don't
    /// block startup — see `Run.runMain`.
    init(root: URL, warnings: [String] = []) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onChangeFolder = { [weak self] in self?.changeFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onSourcesChanged = { sources in
            Config.persistSelections(
                sources: Config.Sources(
                    computerAudio: sources.computerAudio,
                    microphone: sources.microphone
                ),
                capture: Self.captureConfig(for: sources.target)
            )
        }
        menuBar.onDownloadModel = { [weak self] in self?.modelDownload.start() }
        // The cache can fill in behind the menu's back: a transcription that
        // ran since the last open downloads the same weights this row offers.
        menuBar.onMenuOpen = { [weak self] in self?.modelDownload.refresh() }
        modelDownload.onChange = { [weak self] state in self?.showModel(state) }

        menuBar.restore(sources: Self.savedSources())
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateWarnings(warnings)

        // `onChange` only fires on a transition, so the first state has to be
        // pushed by hand or the row would stay hidden until something moved.
        modelDownload.refresh()
        showModel(modelDownload.state)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Restore the persisted selection. A saved display target is trusted
    /// here and reconciled by MenuBarController once enumeration completes,
    /// since checking it now would trigger the Screen Recording prompt at
    /// launch. Window targets are never persisted: CGWindowID isn't stable
    /// across launches.
    private static func savedSources() -> CaptureStream.Sources {
        let config = Config.current
        let target: CaptureTarget = switch config.capture.mode {
        case .none: .none
        case .display: config.capture.displayID.map { .display($0) } ?? .none
        }
        return CaptureStream.Sources(
            computerAudio: config.sources.computerAudio,
            microphone: config.sources.microphone,
            target: target
        )
    }

    private static func captureConfig(for target: CaptureTarget) -> Config.Capture {
        var capture = Config.current.capture
        switch target {
        case .display(let id):
            capture.mode = .display
            capture.displayID = id
        case .window, .none:
            // A window target deliberately doesn't survive a restart.
            capture.mode = .none
            capture.displayID = nil
        }
        return capture
    }

    /// Stop any live session cleanly (finalizing files) and exit. Termination
    /// waits on the stop: the video needs a finalization pass, so quitting
    /// before it completes leaves an unplayable video.
    func shutdown() {
        guard !terminating else { return }
        terminating = true
        Task { @MainActor in
            await stopSession()
            NSApp.terminate(nil)
        }
    }

    private func toggle() {
        // start/stop are async now; ignore clicks while one is in flight.
        //
        // The flag is claimed here rather than inside the Task, which is what
        // makes the guard mean anything. Setting it in the Task left a window
        // between the two: a second click landing while the first task was
        // suspended at an await passed the guard, saw `session` still nil, and
        // started a *second* capture. The first stream's SCStream was then
        // overwritten and never stopped — a live recording with nothing left
        // holding it, and a menu that no longer matched anything real.
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            if session == nil {
                await startSession()
            } else {
                await stopSession()
            }
        }
    }

    private func startSession() async {
        let sources = menuBar.sources
        guard !sources.isEmpty else { return }

        do {
            let newSession = try RecordingSession(
                root: root,
                sources: sources,
                capture: Config.current.capture
            )
            newSession.onUnexpectedStop = { [weak self] reason in
                self?.handleUnexpectedStop(reason)
            }
            try await newSession.start()
            session = newSession
            Log.info("● recording → \(newSession.dir.path)")
        } catch {
            Log.warn("recording start failed: \(error)")
            notifyUser(title: "trailmix — recording failed", body: "\(error)")
            return
        }

        overlay.show(for: sources.target)
        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The stream died on its own: the captured window closed, or the display
    /// was detached. Finalize what we have rather than leaving a live session
    /// that isn't recording anything.
    private func handleUnexpectedStop(_ reason: String) {
        guard session != nil, !busy else { return }
        Log.warn("capture stopped on its own: \(reason)")
        notifyUser(title: "trailmix — capture stopped", body: reason)
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await stopSession()
        }
    }

    private func stopSession() async {
        guard let session else { return }
        self.session = nil

        // Everything that says "recording" comes down before the await, not
        // after it. Finalizing takes as long as it takes, and a menu still
        // offering "Stop recording" for a session that is already stopping
        // reads as a hang — which is exactly what it looked like.
        ticker?.invalidate()
        ticker = nil
        overlay.hide()
        menuBar.showFinishing()

        await session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        Log.info("○ stopped · \(elapsed) · \(session.dir.path)")

        let failed = session.failedTracks
        if !failed.isEmpty {
            notifyUser(
                title: "trailmix — recording incomplete",
                body: "write failures on: \(failed.joined(separator: ", "))",
                reveal: session.dir
            )
        }
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        // Both off the main actor and after the menu is already back to idle.
        // The mix runs first so the playable file exists by the time the
        // "transcript ready" notification invites the user into the folder.
        Task { [transcription] in
            await Mixdown.run(in: dir)
            await Remux.mixedAudioIntoVideo(in: dir)
            await transcription.enqueue(dir)
        }
    }

    /// Config is read on every change rather than cached: transcription can be
    /// switched off in the file while the daemon runs, and offering to download
    /// a model for a disabled feature would be nonsense.
    private func showModel(_ state: ModelDownload.State) {
        menuBar.updateModel(Config.current.transcriptionEnabled ? state : nil)
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Pick a new recordings root. Existing sessions stay where they are —
    /// this changes where the *next* one lands, and moving several gigabytes
    /// of video around behind someone's back is not a thing a menu item
    /// should do.
    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a recordings folder"
        panel.prompt = "Use This Folder"
        panel.message = "New recordings will be saved here. Existing ones stay where they are."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root

        // An .accessory app has no windows and never becomes frontmost on its
        // own, so the panel would otherwise open behind whatever the user is
        // looking at and read as nothing having happened.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Fail here rather than at the top of the next recording, when there
        // is something worth recording and nowhere to put it.
        do {
            try FileManager.default.createDirectory(
                at: chosen, withIntermediateDirectories: true
            )
        } catch {
            Log.warn("can't use \(chosen.path) for recordings: \(error)")
            notifyUser(
                title: "trailmix — can't use that folder",
                body: error.localizedDescription
            )
            return
        }

        root = chosen
        Config.persistRecordingsDir(chosen)
        Log.info("recordings folder → \(chosen.path)")
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
