import AppKit
import ArgumentParser
import Foundation

/// Real entry point.
///
/// Trailmix is launched two ways and both have to work. A double-click in
/// /Applications comes through LaunchServices, which may append process-serial
/// arguments like `-psn_0_12345` that ArgumentParser would reject as unknown
/// options, so the app would exit before ever reaching the menu bar. Running the
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
        subcommands: [Run.self, Doctor.self, Mic.self, TimerCheck.self],
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

    /// Also the only way to exercise the auto-stop path without waiting out
    /// the shortest limit the menu offers: `--stop-after 90s` runs the whole
    /// thing in a minute and a half.
    @Option(name: .long, help: "Pre-set the recording timer (70, 70m, 1:10, 1h10m, 90s).")
    var stopAfter: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Fail here rather than at the menu bar: a mistyped duration that
        // silently became "no timer" would only be discovered by a recording
        // that didn't stop.
        var limit: RecordingLimit?
        if let stopAfter {
            do {
                limit = try RecordingLimit.parse(stopAfter)
            } catch let failure as RecordingLimit.ParseFailure {
                throw ValidationError("--stop-after: \(failure.message)")
            }
        }

        // Non-blocking: permissions prompt on first recording, so a failing
        // check here is informational, not fatal. Launched from Finder there is
        // no terminal to print to and no exit code anyone will ever see: the
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

        let controller = AppController(root: root, warnings: failures, limit: limit)

        // ^C sends SIGINT; launchd sends SIGTERM on logout, shutdown, and
        // `launchctl bootout`. Both have to reach the same clean shutdown, since
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
        // Printed here rather than folded into a check, because it is about how
        // to read the report rather than about anything being wrong with it.
        print("")
        print(permissionAttributionNote)
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
    /// System-wide start/stop shortcut from `hotkey` in the config. Held so
    /// the registration lives as long as the app.
    private var hotkey: GlobalHotkey?
    /// System-wide pause/resume shortcut from `pause_hotkey`. Same lifetime.
    private var pauseHotkey: GlobalHotkey?
    private var ticker: Timer?
    private var busy = false
    private var terminating = false

    /// The start or stop currently in flight, if any.
    ///
    /// `busy` stops a *click* landing in the middle of one. This stops
    /// `shutdown()` doing the same, which `busy` can't: `stopSession()` clears
    /// `session` before it awaits the finalization, so a Quit or a SIGTERM
    /// arriving during "Finishing…" found no session, terminated immediately,
    /// and cut the video's finalization pass off mid-write. Termination now
    /// awaits this first.
    private var lifecycle: Task<Void, Never>?

    /// Whether the "stopping soon" warning has already gone out for the
    /// current limit. The limit itself is not stored as a deadline: it is
    /// worked out on every tick from the recorded time (the user's limit) and
    /// the wall clock (the backstop), see `timeLeft`. Both read the clock
    /// rather than counting ticks, so a machine that slept through its limit
    /// stops on the first tick after it wakes instead of resuming a recording
    /// nobody is watching.
    private var warned = false

    /// `warnings` are failed startup checks, shown in the menu. They don't
    /// block startup; see `Run.runMain`.
    init(root: URL, warnings: [String] = [], limit: RecordingLimit? = nil) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        let spec = Config.current.hotkey
        if let combo = GlobalHotkey.Combo.parse(spec) {
            if let registered = GlobalHotkey(combo: combo, handler: { [weak self] in self?.toggle() }) {
                hotkey = registered
                menuBar.showShortcut(combo)
                Log.info("hotkey \(combo.display) starts and stops recording")
            } else {
                Log.warn("hotkey \(combo.display) could not be registered; another app may hold it")
            }
        } else if !["", "none", "off", "false"].contains(spec.lowercased()) {
            Log.warn("hotkey \"\(spec)\" not understood: use e.g. cmd+shift+7, or none")
        }
        menuBar.onPauseToggle = { [weak self] in self?.pauseToggle() }
        let pauseSpec = Config.current.pauseHotkey
        if let combo = GlobalHotkey.Combo.parse(pauseSpec) {
            if combo == hotkey?.combo {
                Log.warn("pause_hotkey \(combo.display) is the start/stop key; pause has no shortcut")
            } else if let registered = GlobalHotkey(combo: combo, handler: { [weak self] in self?.pauseToggle() }) {
                pauseHotkey = registered
                menuBar.showPauseShortcut(combo)
                Log.info("hotkey \(combo.display) pauses and resumes recording")
            } else {
                Log.warn("pause_hotkey \(combo.display) could not be registered; another app may hold it")
            }
        } else if !["", "none", "off", "false"].contains(pauseSpec.lowercased()) {
            Log.warn("pause_hotkey \"\(pauseSpec)\" not understood: use e.g. cmd+shift+2, or none")
        }
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
        menuBar.onLimitChanged = { [weak self] limit in self?.limitChanged(to: limit) }
        menuBar.onDownloadModel = { [weak self] in self?.modelDownload.start() }
        menuBar.onRequestPermission = { [weak self] permission in
            self?.requestPermission(permission)
        }
        menuBar.onOpenPrivacySettings = { Permissions.openSettings(for: nil) }
        // Both of these can change behind the menu's back: a transcription that
        // ran since the last open downloads the same weights that row offers,
        // and a permission can be toggled in System Settings at any time.
        menuBar.onMenuOpen = { [weak self] in
            self?.modelDownload.refresh()
            self?.menuBar.updatePermissions(Permissions.all())
        }
        modelDownload.onChange = { [weak self] state in self?.showModel(state) }

        menuBar.restore(sources: Self.savedSources())
        menuBar.setLimit(limit)
        // Before the first `update`, which renders the idle line from these. An
        // empty status list reads as everything being missing, which is the
        // right way for it to fail but the wrong thing to flash on screen.
        // Reading a grant never prompts; asking is what waits for a click.
        let permissions = Permissions.all()
        menuBar.updatePermissions(permissions)
        Log.info(Permissions.logLine(permissions))
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
    ///
    /// A stop already under way is awaited rather than raced. Its own
    /// `stopSession()` cleared `session` before awaiting the stream, so a
    /// second one started here would see nothing to do and terminate straight
    /// through the finalization it was supposed to be protecting. `terminating`
    /// then keeps any later click, timer or unexpected stop from starting
    /// another transition behind the one that is on its way out.
    func shutdown() {
        guard !terminating else { return }
        terminating = true
        let inFlight = lifecycle
        Task { @MainActor in
            await inFlight?.value
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
        // overwritten and never stopped: a live recording with nothing left
        // holding it, and a menu that no longer matched anything real.
        //
        // `terminating` is the same guard for the other direction: the app is
        // on its way out and `shutdown()` is already awaiting whatever was in
        // flight, so a click landing now would start a recording nothing will
        // ever stop.
        guard !busy, !terminating else { return }
        busy = true
        lifecycle = Task { @MainActor in
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

        // Read the grants again rather than trusting the menu's snapshot: one
        // can be revoked in System Settings between the menu opening and the
        // click landing.
        let statuses = Permissions.all()
        let missing = Permissions.blockers(for: sources, given: statuses)
        guard missing.isEmpty else {
            menuBar.updatePermissions(statuses)
            Log.warn("not recording · \(Permissions.blockedReason(missing) ?? "")")
            explainBlockedRecording(missing)
            return
        }

        let newSession: RecordingSession
        do {
            newSession = try RecordingSession(
                root: root,
                sources: sources,
                capture: Config.current.capture
            )
        } catch {
            Log.warn("recording start failed: \(error)")
            notifyUser(title: "trailmix: recording failed", body: "\(error)")
            return
        }
        newSession.onUnexpectedStop = { [weak self] reason in
            self?.handleUnexpectedStop(reason)
        }

        do {
            try await newSession.start()
        } catch {
            // The folder is created by init, before capture is attempted, so a
            // failed start would otherwise leave an empty timestamped directory
            // in the recordings root. Only removed when it really is empty, so
            // a partial capture is never thrown away to tidy up.
            let contents = (try? FileManager.default.contentsOfDirectory(
                atPath: newSession.dir.path
            )) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: newSession.dir)
            }
            Log.warn("recording start failed: \(error)")
            notifyUser(title: "trailmix: recording failed", body: "\(error)")
            return
        }
        session = newSession
        Log.info("● recording → \(newSession.dir.path)")

        overlay.show(for: sources.target)
        warned = false

        // Installed in .common rather than scheduled into .default. A menu
        // that is open puts the run loop in event-tracking mode, where a
        // default-mode timer simply doesn't fire: the elapsed counter froze
        // for as long as the menu was held open, and now that the auto-stop
        // check rides on this same tick, so would the stop.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        tick()
    }

    /// How long the current recording has left before it stops itself: the
    /// user's limit, the backstop, or whichever of the two comes first. nil
    /// with neither set.
    ///
    /// The user's limit is measured against *recorded* time, because a limit
    /// means total recording length. Picking "1 hour" is a statement about how
    /// long the recording is, not about how much longer it has left, and a
    /// pause doesn't shorten the recording. Extending is a separate verb, and
    /// the menu offers it as one.
    ///
    /// The backstop is wall clock on purpose. It guards against a recording
    /// that was forgotten, and a recording forgotten while paused is still
    /// forgotten: eight hours later it stops and finalizes whatever it has.
    private func timeLeft(at now: Date) -> (left: TimeInterval, whole: TimeInterval)? {
        guard let session else { return nil }
        var candidates: [(left: TimeInterval, whole: TimeInterval)] = []
        if let limit = menuBar.limit {
            candidates.append((limit.seconds - session.recordedElapsed(at: now), limit.seconds))
        }
        let backstop = Config.current.maxRecordingHours * 3600
        if backstop > 0 {
            candidates.append((backstop - now.timeIntervalSince(session.startedAt), backstop))
        }
        return candidates.min { $0.left < $1.left }
    }

    private func limitChanged(to limit: RecordingLimit?) {
        // A limit that moved deserves a fresh warning: extending past the
        // five-minute mark and then getting no second warning is how you end
        // up surprised twice by the same timer.
        warned = false
        Log.info("recording timer → \(limit?.compact ?? "off")")
        // Show the new countdown now rather than up to a second from now; the
        // menu the user just clicked in is still on screen.
        if session != nil { tick() }
    }

    /// Pause or resume the live recording. Synchronous: the stream keeps
    /// running either way (see `CaptureStream.pause`), so there is nothing to
    /// await and no `lifecycle` task to hold. The `busy` guard still applies:
    /// a pause landing in the middle of a start or stop would be acting on a
    /// session that is half there.
    ///
    /// Refused for the first two seconds of a recording so every track has
    /// written its first buffer before any gap; the menu row is disabled for
    /// the same window, and the hotkey just does nothing.
    private func pauseToggle() {
        guard let session, !busy, !terminating else { return }
        let now = Date()
        if session.isPaused {
            session.resume()
            overlay.setPaused(false)
            Log.info("▶ resumed · \(RecordingLimit.clock(session.recordedElapsed(at: now))) recorded")
        } else {
            guard session.recordedElapsed(at: now) >= MenuBarController.pauseGrace else { return }
            session.pause()
            overlay.setPaused(true)
            Log.info("❚❚ paused at \(RecordingLimit.clock(session.recordedElapsed(at: now)))")
        }
        tick()
    }

    /// The timer ran out. Same shape as `handleUnexpectedStop` down to the
    /// synchronous `busy` claim, for the same reason.
    private func autoStop(limit ran: TimeInterval) {
        guard let session, !busy, !terminating else { return }
        let dir = session.dir
        Log.info("timer reached \(RecordingLimit.clock(ran)), stopping")

        busy = true
        lifecycle = Task { @MainActor in
            defer { busy = false }
            await stopSession()
            // After the stop, so the notification's reveal opens a folder that
            // has finished being written to.
            notifyUser(
                title: "trailmix: recording stopped",
                body: "Reached the \(RecordingLimit(seconds: ran).menuTitle) limit.",
                reveal: dir
            )
        }
    }

    /// The stream died on its own: the captured window closed, or the display
    /// was detached. Finalize what we have rather than leaving a live session
    /// that isn't recording anything.
    private func handleUnexpectedStop(_ reason: String) {
        guard session != nil, !busy, !terminating else { return }
        Log.warn("capture stopped on its own: \(reason)")
        notifyUser(title: "trailmix: capture stopped", body: reason)
        busy = true
        lifecycle = Task { @MainActor in
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
        // reads as a hang, which is what it looked like.
        ticker?.invalidate()
        ticker = nil
        warned = false
        overlay.hide()
        menuBar.showFinishing()
        // A limit belongs to one recording. It was picked because this webinar
        // was an hour, and carrying it into the next recording would cut short
        // something started for an entirely different reason.
        menuBar.setLimit(nil)

        await session.stop()
        let elapsed = RecordingLimit.clock(session.recordedElapsed())
        let paused = session.pauseCount > 0
            ? " · \(RecordingLimit.clock(session.pausedTotal())) paused in \(session.pauseCount) pause(s)"
            : ""
        Log.info("○ stopped · \(elapsed)\(paused) · \(session.dir.path)")

        let failed = session.failedTracks
        if !failed.isEmpty {
            notifyUser(
                title: "trailmix: recording incomplete",
                body: "write failures on: \(failed.joined(separator: ", "))",
                reveal: session.dir
            )
        }
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        // Both off the main actor and after the menu is already back to idle.
        // The mix runs first so the playable file exists by the time the
        // "transcript ready" notification invites the user into the folder.
        // `Remux.finalize` swaps the mix into the video and cuts out whatever
        // was recorded while paused.
        Task { [transcription] in
            await Mixdown.run(in: dir)
            await Remux.finalize(in: dir)
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
        let now = Date()
        let recorded = session.recordedElapsed(at: now)

        // Only a limit the user set produces a countdown. The backstop is a
        // guard against forgetting, not a clock to watch.
        let remaining = menuBar.limit.map { $0.seconds - recorded }
        menuBar.update(
            recording: true,
            elapsed: recorded,
            remaining: remaining,
            paused: session.isPaused
        )

        guard let status = timeLeft(at: now) else { return }
        let (left, whole) = status
        if left <= 0 {
            autoStop(limit: whole)
            return
        }

        // Skipped when the limit is no longer than the warning itself, where
        // the warning would land at the moment the timer was set.
        guard !warned, left <= RecordingLimit.warningLead, whole > RecordingLimit.warningLead
        else { return }
        warned = true
        let minutes = Int((left / 60).rounded(.up))
        notifyUser(
            title: "trailmix: stopping soon",
            body: "Recording stops in \(minutes) minute\(minutes == 1 ? "" : "s")."
        )
    }

    // MARK: - Permissions

    /// Ask for one grant, then land the user somewhere useful whatever happened.
    ///
    /// Three outcomes. Granted and it takes effect immediately, which is the
    /// microphone. Granted but the running process can't see it, which is
    /// screen recording and needs a relaunch. Or not granted, which means macOS
    /// declined to ask and only System Settings can move it.
    private func requestPermission(_ permission: Permission) {
        Task { @MainActor in
            let state = await Permissions.request(permission)
            menuBar.updatePermissions(Permissions.all())

            guard state == .granted else {
                Permissions.openSettings(for: permission)
                return
            }
            Log.info("\(permission.title) granted")
            guard !permission.appliesWithoutRelaunch else { return }

            // Mid-recording an alert is the wrong interruption, and relaunching
            // would end the very thing the permission was wanted for.
            guard session == nil else {
                notifyUser(
                    title: "trailmix: \(permission.title) granted",
                    body: "It takes effect the next time Trailmix starts."
                )
                return
            }
            offerRelaunch(after: permission)
        }
    }

    /// Pressing record with a permission missing.
    ///
    /// The row stays clickable rather than greying out, because this is the
    /// moment the explanation is wanted and a dead control explains nothing.
    /// The primary button leads straight into the same request path the
    /// Permissions submenu uses, so the click that failed becomes the one that
    /// fixes it.
    private func explainBlockedRecording(_ missing: [Permission]) {
        guard let first = missing.first else { return }

        let alert = NSAlert()
        alert.messageText = missing.count == 1
            ? "Trailmix needs \(first.title) access"
            : "Trailmix needs two permissions"
        alert.informativeText = Permissions.explanation(missing)
        alert.addButton(withTitle: "Grant \(first.title)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // One at a time, in `Permission.allCases` order, which puts the
        // microphone first. That is deliberate: it resolves inline, where
        // screen recording ends in a relaunch, and relaunching with the
        // microphone still outstanding would lose the second half.
        requestPermission(first)
    }

    private func offerRelaunch(after permission: Permission) {
        let alert = NSAlert()
        alert.messageText = "\(permission.title) granted"
        alert.informativeText =
            "macOS applies this only to a newly launched app. "
            + "Trailmix needs to restart before it can record."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        // An .accessory app never comes forward on its own, so without this the
        // alert opens behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    /// Restart, by handing the reopen to a detached shell that waits for this
    /// process to be gone first.
    ///
    /// Launching the new copy before quitting would put two daemons in the menu
    /// bar at once, both holding a status item and both willing to record. The
    /// shell polls for our exit instead, so the handover is strictly ordered
    /// and `shutdown()` still gets to finalize a session on the way out.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        // Single-quoted so a path with spaces survives, with embedded quotes
        // escaped the only way single-quoting allows.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(quoted)",
        ]
        do {
            try task.run()
        } catch {
            // Better to stay up than to quit with nothing coming back.
            Log.warn("couldn't schedule a relaunch: \(error)")
            notifyUser(
                title: "trailmix: couldn't relaunch",
                body: "Quit and reopen Trailmix for the new permission to apply."
            )
            return
        }
        Log.info("relaunching")
        shutdown()
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Pick a new recordings root. Existing sessions stay where they are:
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
                title: "trailmix: can't use that folder",
                body: error.localizedDescription
            )
            return
        }

        root = chosen
        Config.persistRecordingsDir(chosen)
        Log.info("recordings folder → \(chosen.path)")
    }

}
