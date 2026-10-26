import AppKit
import Carbon.HIToolbox


/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory`, with no dock icon and no main window).
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private var warningItems: [NSMenuItem] = []

    private let computerAudioItem: NSMenuItem
    private let microphoneItem: NSMenuItem
    private let captureItem: NSMenuItem
    private let captureMenu: NSMenu
    private let limitItem: NSMenuItem
    private let limitMenu: NSMenu
    private let permissionsItem: NSMenuItem
    private let permissionsMenu: NSMenu
    private let changeFolderItem: NSMenuItem
    private let modelItem: NSMenuItem

    /// Last enumeration of displays and windows. Shown immediately when the
    /// Capture submenu opens while a fresh fetch runs behind it.
    private var content = ShareableContent()
    private var refreshing = false
    private var isRecording = false

    private(set) var sources = CaptureStream.Sources(
        computerAudio: true,
        microphone: true,
        target: .none
    )

    /// How long the recording may run, or nil for no limit of the user's own.
    /// Per-recording: `AppController` clears it once a recording stops.
    private(set) var limit: RecordingLimit?

    /// The last read of what Trailmix is granted, for the submenu and for the
    /// idle line. Refreshed whenever the menu opens, since a grant can be
    /// revoked in System Settings while the app is running.
    private var permissionStatuses: [PermissionStatus] = []

    /// Set between a capture stopping and its files closing, so the idle line
    /// doesn't overwrite "Finishing…" with a permission complaint.
    private var finishing = false

    /// Required by the current selection but not granted. Non-empty means the
    /// toggle explains itself instead of recording.
    private var blockers: [Permission] {
        Permissions.blockers(for: sources, given: permissionStatuses)
    }

    /// How far into the current recording we are, pushed down every second.
    /// Only used to decide which limits are still choosable: picking one that
    /// has already passed would stop the recording on the spot.
    private var elapsed: TimeInterval = 0

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    /// The user picked a new recordings root.
    var onChangeFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Fired whenever the user changes a source or capture target, so the
    /// selection can be persisted to config.
    var onSourcesChanged: ((CaptureStream.Sources) -> Void)?
    /// The user set, cleared, or extended the recording timer. Always an
    /// absolute limit. The "Add …" rows are resolved to a total before this
    /// fires, so the controller never has to work out what a click meant.
    var onLimitChanged: ((RecordingLimit?) -> Void)?
    /// The user asked for the transcription model to be fetched now.
    var onDownloadModel: (() -> Void)?
    /// The user clicked a permission that isn't granted.
    var onRequestPermission: ((Permission) -> Void)?
    /// The user asked for the Privacy & Security pane.
    var onOpenPrivacySettings: (() -> Void)?
    /// The menu is about to draw. Anything whose state can change behind the
    /// app's back gets resynced here rather than trusted from the last click.
    var onMenuOpen: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false
        self.menu = menu

        stateLabel = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        // The two audio sources sit directly in the menu rather than behind a
        // "Sources" submenu. There are only ever two of them, they are the
        // settings people change most, and a submenu made the common case
        // (glance at the menu, see what is armed) take a hover and a wait.
        computerAudioItem = NSMenuItem(
            title: "Computer audio",
            action: #selector(computerAudioClicked),
            keyEquivalent: ""
        )
        microphoneItem = NSMenuItem(
            title: "Microphone",
            action: #selector(microphoneClicked),
            keyEquivalent: ""
        )
        menu.addItem(computerAudioItem)
        menu.addItem(microphoneItem)

        // Video Capture: a radio group, populated lazily so that merely opening
        // the menu doesn't trigger the Screen Recording prompt. Named for what
        // it selects, since it sits beside two audio rows and "Capture" alone read
        // like it governed them too.
        captureMenu = NSMenu()
        captureMenu.autoenablesItems = false
        captureItem = NSMenuItem(title: "Video Capture", action: nil, keyEquivalent: "")
        captureItem.submenu = captureMenu
        menu.addItem(captureItem)

        menu.addItem(.separator())

        // The key equivalent is filled in by showShortcut() once the global
        // hotkey (GlobalHotkey, from `hotkey` in the config) is registered, so
        // the menu only advertises a shortcut that really works system-wide.
        // An NSStatusItem's menu handles a key equivalent only while it is
        // open; the Carbon registration is what makes it fire from anywhere.
        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: ""
        )
        menu.addItem(toggleItem)

        // Directly under the toggle rather than up with the sources: this is a
        // property of the recording, not another thing being recorded. Unlike
        // the source rows it stays live during a capture. See applySources().
        limitMenu = NSMenu()
        limitMenu.autoenablesItems = false
        limitItem = NSMenuItem(title: "Stop after: Off", action: nil, keyEquivalent: "")
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        // Under the timer and above the folder rows: it belongs with the things
        // that decide whether a recording can happen at all, not with the ones
        // that decide where it lands. Stays live during a capture for the same
        // reason limitItem does, since nothing here touches stream config.
        permissionsMenu = NSMenu()
        permissionsMenu.autoenablesItems = false
        permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)

        // Bare of a key equivalent, like every other row here. See the note on
        // toggleItem above. A status item's menu only handles one while it is
        // already open, so ⌘O saved a click on an item already under the
        // pointer while implying a global shortcut that doesn't exist.
        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(openFolder)

        changeFolderItem = NSMenuItem(
            title: "Change recordings folder…",
            action: #selector(changeFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(changeFolderItem)

        // Hidden unless the weights are actually missing, so the common case
        // is a menu with no maintenance chore in it.
        modelItem = NSMenuItem(
            title: "Download transcription model",
            action: #selector(modelClicked),
            keyEquivalent: ""
        )
        modelItem.isHidden = true
        menu.addItem(modelItem)

        menu.addItem(.separator())

        // Capital T here and in the Quit row below. The executable, the folder
        // and the command are all lowercase `trailmix`; the app the user sees
        // is `Trailmix.app`, which is what these two rows are talking about.
        let about = NSMenuItem(
            title: "About Trailmix",
            action: #selector(aboutClicked),
            keyEquivalent: ""
        )
        menu.addItem(about)

        // ⌘Q is gone for the same reason as ⌘O: it only ever fired with the
        // menu open, so it was decoration on a row that is one click away.
        let quit = NSMenuItem(
            title: "Quit Trailmix",
            action: #selector(quitClicked),
            keyEquivalent: ""
        )
        menu.addItem(quit)

        super.init()

        for item in [
            toggleItem, openFolder, changeFolderItem, about, quit,
            computerAudioItem, microphoneItem, modelItem,
        ] {
            item.target = self
        }
        captureMenu.delegate = self
        menu.delegate = self

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.imagePosition = .imageLeft
            // Set once. The countdown beside the icon rewrites the title every
            // minute, and a proportional font would shuffle the whole menu bar
            // sideways as the digits changed width.
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize(for: .small),
                weight: .regular
            )
        }

        applySources()
        rebuildCaptureMenu()
        rebuildLimitMenu()
    }

    /// Seed the selection from config at startup. A saved display that is no
    /// longer attached falls back to audio only, which `rebuildCaptureMenu`
    /// reconciles once enumeration completes.
    func restore(sources: CaptureStream.Sources) {
        self.sources = sources
        applySources()
        rebuildCaptureMenu()
    }

    /// Reflect recording state in the icon tint and menu item titles. Call
    /// once a second while recording.
    ///
    /// `remaining` is passed only when the user set a timer. The 8-hour
    /// backstop deliberately doesn't produce a countdown: it is a guard against
    /// forgetting, and a menu bar ticking down from 8:00 on every
    /// recording would turn it into a thing to watch.
    func update(recording: Bool, elapsed: TimeInterval?, remaining: TimeInterval? = nil) {
        let transitioned = isRecording != recording
        isRecording = recording
        finishing = false
        self.elapsed = elapsed ?? 0

        if recording {
            var line = "● Recording · \(RecordingLimit.clock(elapsed ?? 0))"
            if let remaining {
                line += " · \(RecordingLimit.clock(remaining)) left"
            }
            stateLabel.title = line
        } else {
            refreshIdleLabel()
        }

        toggleItem.title = recording ? "Stop recording" : "Start recording"
        toggleItem.isEnabled = true
        statusItem.button?.image = recording ? Self.recordingImage : Self.idleImage
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        // The menu bar carries the countdown, not the elapsed time. Elapsed is
        // a number you look up when you wonder; remaining is a number you want
        // to catch out of the corner of your eye, which is the only thing the
        // menu bar is good for.
        setButtonTitle(recording ? remaining.map { RecordingLimit.hoursMinutes($0) } : nil)

        applySources()
        // A full rebuild only when starting or stopping, since that is when the
        // "Add …" rows come and go. Every other second just re-greys the
        // presets the recording has already run past.
        if transitioned {
            rebuildLimitMenu()
        } else {
            applyLimitEnablement()
        }
    }

    /// "Idle", or what is stopping a recording from starting.
    private func refreshIdleLabel() {
        guard !isRecording, !finishing else { return }
        stateLabel.title = Permissions.blockedReason(blockers) ?? "Idle"
    }

    private func setButtonTitle(_ text: String?) {
        guard let button = statusItem.button else { return }
        let new = text ?? ""
        // Writing the same string still triggers a layout pass, and this runs
        // once a second.
        guard button.title != new else { return }
        button.title = new
    }

    /// Capture has stopped but the files aren't closed yet. The video needs a
    /// finalization pass that can take a moment on a long recording, and the
    /// gap has to look like progress rather than a frozen menu.
    func showFinishing() {
        isRecording = false
        finishing = true
        elapsed = 0
        stateLabel.title = "Finishing…"
        toggleItem.title = "Finishing…"
        statusItem.button?.image = Self.idleImage
        statusItem.button?.contentTintColor = nil
        setButtonTitle(nil)
        applySources()
        // applySources() re-enables the toggle whenever sources are non-empty;
        // starting a new recording before this one has closed its files is
        // exactly what must not happen here.
        toggleItem.isEnabled = false
        // isRecording just changed, and the "Add …" rows are conditioned on it.
        rebuildLimitMenu()
    }

    // MARK: - Sources and capture target

    /// Push `sources` into the menu's checkmarks and enablement. Source
    /// controls are locked while recording: ScreenCaptureKit stops the
    /// recording outright if the stream configuration changes mid-capture, so
    /// a menu that accepted changes would be lying.
    private func applySources() {
        computerAudioItem.state = sources.computerAudio ? .on : .off
        microphoneItem.state = sources.microphone ? .on : .off
        computerAudioItem.isEnabled = !isRecording
        microphoneItem.isEnabled = !isRecording
        captureItem.isEnabled = !isRecording
        // The live session already has its folder; moving the root under it
        // mid-recording would split one recording across two places.
        changeFolderItem.isEnabled = !isRecording

        // limitItem is pointedly absent from this list. Nothing about a
        // deadline reaches the SCStream configuration, so changing it
        // mid-recording is safe, and it is the one setting whose whole point
        // is being reachable once a recording is already running and the
        // meeting is running over.

        // None is spelled out rather than left blank. A bare "Video Capture"
        // looks like a heading for the submenu below it, not like a setting
        // that currently has a value.
        captureItem.title = switch sources.target {
        case .none: "Video Capture: None"
        case .display(let id):
            "Video Capture: \(content.displays.first { $0.id == id }?.name ?? "Display")"
        case .window(let id):
            "Video Capture: \(content.windows.first { $0.id == id }?.label ?? "Window")"
        }

        // Nothing selected means nothing to record.
        toggleItem.isEnabled = isRecording || !sources.isEmpty
        for item in captureMenu.items where item.action != nil {
            item.isEnabled = !isRecording
        }
    }

    private func selectionChanged() {
        applySources()
        onSourcesChanged?(sources)
    }

    @objc private func computerAudioClicked() {
        sources.computerAudio.toggle()
        selectionChanged()
    }

    @objc private func microphoneClicked() {
        sources.microphone.toggle()
        selectionChanged()
    }

    @objc private func captureNoneClicked() {
        sources.target = .none
        rebuildCaptureMenu()
        selectionChanged()
    }

    @objc private func captureDisplayClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        sources.target = .display(id)
        rebuildCaptureMenu()
        selectionChanged()
    }

    @objc private func captureWindowClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        sources.target = .window(id)
        rebuildCaptureMenu()
        selectionChanged()
    }

    @objc private func refreshClicked() {
        refreshContent()
    }

    // MARK: - Recording timer

    /// The cap that applies when the user has set no timer of their own, from
    /// `max_recording_hours`. Nil disables it, which is the only way to get a
    /// recording that runs until something stops it.
    private let backstop: RecordingLimit? = {
        let hours = Config.current.maxRecordingHours
        return hours > 0 ? RecordingLimit(seconds: hours * 3600) : nil
    }()

    /// Set or clear the limit without reporting it back. For seeding from
    /// `--stop-after` and for the reset once a recording stops. The caller is
    /// the one making the change, so firing `onLimitChanged` at it would only
    /// echo.
    func setLimit(_ limit: RecordingLimit?) {
        self.limit = limit
        rebuildLimitMenu()
    }

    /// Rebuild the timer submenu from `limit`, `isRecording`, and `elapsed`.
    ///
    /// A number here always means the recording's *total* length, never "from
    /// now". The parent row reads "Stop after: 1:10" and the checkmark marks
    /// one value out of a list, and both of those describe how long the thing
    /// runs. That reading is what makes the "Add …" rows necessary rather than
    /// redundant: at 55 minutes into an hour, "1 hour" is still 1 hour and buys
    /// five more minutes, so wanting more time needs its own verb.
    private func rebuildLimitMenu() {
        limitItem.title = "Stop after: \(limit?.compact ?? "Off")"
        limitMenu.removeAllItems()

        // Extending is meaningless with no clock running, and the rows would
        // just be two more things to read past while setting one up.
        if isRecording {
            for increment in RecordingLimit.increments {
                let item = NSMenuItem(
                    title: "Add \(RecordingLimit(seconds: increment).menuTitle)",
                    action: #selector(limitAddClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = increment
                limitMenu.addItem(item)
            }
            limitMenu.addItem(.separator())
        }

        // "Off" spells out the backstop rather than leaving it a surprise. It
        // is still off in the sense that matters, since nothing stops at a time
        // the user chose, but a recording that ends on its own after 8 hours with
        // no warning anywhere in the menu is the app lying about its state.
        let off = NSMenuItem(
            title: backstop.map { "Off (\($0.menuTitle) maximum)" } ?? "Off",
            action: #selector(limitOffClicked),
            keyEquivalent: ""
        )
        off.target = self
        off.state = limit == nil ? .on : .off
        limitMenu.addItem(off)
        limitMenu.addItem(.separator())

        // A custom value takes its place in the list rather than hiding behind
        // the "Custom…" row, so the checkmark is always visible next to the
        // value it applies to.
        let ceiling = backstop.map { min($0, .maximum) } ?? .maximum
        var values = RecordingLimit.presets.filter { $0 <= ceiling }
        if let limit, !values.contains(limit) {
            values.append(limit)
            values.sort()
        }
        for value in values {
            let item = NSMenuItem(
                title: value.menuTitle,
                action: #selector(limitPresetClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = value == limit ? .on : .off
            limitMenu.addItem(item)
        }

        limitMenu.addItem(.separator())
        let custom = NSMenuItem(
            title: "Custom…",
            action: #selector(limitCustomClicked),
            keyEquivalent: ""
        )
        custom.target = self
        limitMenu.addItem(custom)

        applyLimitEnablement()
    }

    /// Grey out limits the recording has already run past. Clicking one would
    /// be a total length shorter than what is already recorded, which can only
    /// mean stopping immediately, never what someone reaching into a timer
    /// menu wants, and unrecoverable by the time they see it.
    private func applyLimitEnablement() {
        for item in limitMenu.items where item.action == #selector(limitPresetClicked(_:)) {
            guard let value = item.representedObject as? RecordingLimit else { continue }
            item.isEnabled = !isRecording || value.seconds > elapsed
        }
    }

    private func limitChanged() {
        rebuildLimitMenu()
        onLimitChanged?(limit)
    }

    @objc private func limitOffClicked() {
        limit = nil
        limitChanged()
    }

    @objc private func limitPresetClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? RecordingLimit else { return }
        limit = value
        limitChanged()
    }

    /// Resolve "Add 15 minutes" against whatever is in force. With no timer set
    /// there is nothing to add to, so it becomes a limit of that length
    /// measured from where the recording already is, which is what the words
    /// mean when the answer to "add to what?" is "now".
    @objc private func limitAddClicked(_ sender: NSMenuItem) {
        guard let increment = sender.representedObject as? TimeInterval else { return }
        limit = limit?.extended(by: increment)
            ?? RecordingLimit(seconds: elapsed + increment)
        limitChanged()
    }

    @objc private func limitCustomClicked() {
        var problem: String?
        // Loops rather than giving up on bad input: the dialog is modal and the
        // menu is already closed behind it, so a rejection that dismissed
        // everything would cost the whole interaction over a typo.
        while true {
            guard let text = askForDuration(problem: problem) else { return }
            do {
                let candidate = try RecordingLimit.parse(text)
                if let reason = reasonToReject(candidate) {
                    problem = reason
                    continue
                }
                limit = candidate
                limitChanged()
                return
            } catch let failure as RecordingLimit.ParseFailure {
                problem = failure.message
            } catch {
                return
            }
        }
    }

    private func reasonToReject(_ candidate: RecordingLimit) -> String? {
        if candidate.seconds < RecordingLimit.shortestPickable {
            return "The shortest limit is one minute."
        }
        if let backstop, candidate > backstop {
            return "Recordings are capped at \(backstop.menuTitle)."
        }
        if isRecording, candidate.seconds <= elapsed {
            return "This recording is already at \(RecordingLimit.clock(elapsed))."
        }
        return nil
    }

    /// Ask for a duration in a modal panel. Nil means the user cancelled.
    ///
    /// `NSApp.activate` for the same reason `changeFolder` needs it: an
    /// `.accessory` app never becomes frontmost on its own, so the panel would
    /// open behind whatever they were looking at and read as a dead menu item.
    private func askForDuration(problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Stop recording after"

        let ceiling = backstop.map { min($0, .maximum) } ?? .maximum
        var info = "Type a duration: 70, 70m, 1:10, or 1h10m. "
            + "A bare number means minutes. Between one minute and \(ceiling.menuTitle)."
        if isRecording {
            info += "\n\nThis recording is at \(RecordingLimit.clock(elapsed))."
        }
        if let problem {
            info = problem + "\n\n" + info
        }
        alert.informativeText = info

        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 96, height: 24))
        field.stringValue = limit?.compact ?? ""
        field.placeholderString = "1:10"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Launch at login
    //
    // No menu row. Launching trailmix is a double-click in ~/Applications and
    // a login item is a preference, not a control. It earned a permanent row
    // in a seven-item menu by being easy to build, not by being wanted.
    //
    // `LoginItem` is kept whole and still works: SMAppService.mainApp,
    // including the .requiresApproval branch. Restoring the row is an
    // NSMenuItem plus the two calls that were here (set the checkmark from
    // LoginItem.isEnabled on menuNeedsUpdate, toggle it on click). Until then
    // people can add Trailmix under System Settings > General > Login Items
    // themselves, which is where macOS puts the switch anyway.

    /// Rebuild the Capture submenu from the cached content snapshot.
    private func rebuildCaptureMenu() {
        captureMenu.removeAllItems()

        let none = NSMenuItem(
            title: "None (audio only)",
            action: #selector(captureNoneClicked),
            keyEquivalent: ""
        )
        none.target = self
        none.state = sources.target.capturesVideo ? .off : .on
        captureMenu.addItem(none)

        if !content.displays.isEmpty {
            captureMenu.addItem(.separator())
            captureMenu.addItem(Self.header("Displays"))
            for display in content.displays {
                let item = NSMenuItem(
                    title: "\(display.name)  \(display.width)×\(display.height)",
                    action: #selector(captureDisplayClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = display.id
                item.state = sources.target == .display(display.id) ? .on : .off
                captureMenu.addItem(item)
            }
        }

        if !content.windows.isEmpty {
            captureMenu.addItem(.separator())
            captureMenu.addItem(Self.header("Windows"))
            for window in content.windows {
                let item = NSMenuItem(
                    title: window.label,
                    action: #selector(captureWindowClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = window.id
                item.state = sources.target == .window(window.id) ? .on : .off
                captureMenu.addItem(item)
            }
        }

        captureMenu.addItem(.separator())
        let refresh = NSMenuItem(
            title: refreshing ? "Refreshing…" : "Refresh",
            action: #selector(refreshClicked),
            keyEquivalent: ""
        )
        refresh.target = self
        refresh.isEnabled = !refreshing
        captureMenu.addItem(refresh)

        applySources()
    }

    /// Enumerate displays and windows. This is what triggers the Screen
    /// Recording prompt, so it runs only when the Capture submenu is opened
    /// or Refresh is chosen, never at launch.
    private func refreshContent() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer {
                refreshing = false
                rebuildCaptureMenu()
            }
            do {
                content = try await ShareableContent.fetch()
            } catch {
                Log.warn("can't list capturable content: \(error.localizedDescription)")
            }
            // A saved display that's no longer attached, or a window that has
            // closed, silently reverts to audio only rather than failing at
            // the moment the user hits record.
            switch sources.target {
            case .display(let id) where !content.displays.contains(where: { $0.id == id }):
                sources.target = .none
            case .window(let id) where !content.windows.contains(where: { $0.id == id }):
                sources.target = .none
            default:
                break
            }
        }
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state, since a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Drive the model download row. `nil` hides it outright, which covers
    /// transcription being switched off in config: there is no point offering a
    /// 440 MB download for a feature that will never run.
    ///
    /// The row disappears once the weights are cached, so on most launches it
    /// is never seen at all.
    func updateModel(_ state: ModelDownload.State?) {
        guard let state, state != .present else {
            modelItem.isHidden = true
            return
        }
        modelItem.isHidden = false
        switch state {
        case .missing:
            modelItem.title = "Download transcription model (\(ParakeetModel.approximateSize))"
            modelItem.isEnabled = true
        case .working(let line):
            modelItem.title = line
            modelItem.isEnabled = false
        case .failed:
            // The reason goes to stderr and a notification; a menu row is the
            // wrong place for a URLError description.
            modelItem.title = "Model download failed (retry)"
            modelItem.isEnabled = true
        case .present:
            break  // handled by the guard above
        }
    }

    @objc private func modelClicked() { onDownloadModel?() }

    // MARK: - Permissions

    /// Rebuild the permissions submenu. Driven from `onMenuOpen`, because a
    /// grant can change in System Settings while the app is running and the
    /// menu would otherwise show whatever was true at launch.
    func updatePermissions(_ statuses: [PermissionStatus]) {
        permissionStatuses = statuses
        permissionsItem.title = Permissions.summary(statuses)
        permissionsMenu.removeAllItems()

        for status in statuses {
            // ✓ and ✗ rather than a checkmark state: NSMenuItem's checkmark
            // reads as "this option is selected", and a permission is not an
            // option. It also survives the row being disabled, which the
            // checkmark visually does not.
            let mark = status.state == .granted ? "✓" : "✗"
            let item = NSMenuItem(
                title: "\(mark) \(status.permission.title)",
                action: #selector(permissionClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = status.permission
            // A granted permission has nothing to click. Leaving it live would
            // mean a row that opens System Settings for no reason.
            item.isEnabled = status.state != .granted
            permissionsMenu.addItem(item)
        }

        permissionsMenu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Open Privacy Settings…",
            action: #selector(privacySettingsClicked),
            keyEquivalent: ""
        )
        settings.target = self
        permissionsMenu.addItem(settings)

        // A missing grant changes what the idle line says. The toggle stays
        // clickable on purpose: the click is what triggers the explanation,
        // and a greyed row that never says why is worse than one that does.
        refreshIdleLabel()
    }

    @objc private func permissionClicked(_ sender: NSMenuItem) {
        guard let permission = sender.representedObject as? Permission else { return }
        onRequestPermission?(permission)
    }

    @objc private func privacySettingsClicked() { onOpenPrivacySettings?() }

    /// Show failed startup checks as disabled rows below the status labels.
    /// A denied permission doesn't stop the daemon (recording just fails until
    /// it's granted), and launched from Finder there is no terminal attached to
    /// read stderr, so the menu is the only place the user would ever see this.
    /// Replaces any previously shown warnings; an empty array clears them.
    func updateWarnings(_ messages: [String]) {
        for item in warningItems {
            menu.removeItem(item)
        }
        warningItems = messages.map { message in
            let item = NSMenuItem(title: "⚠ \(message)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        // Below the two status labels, above the first separator. index(of:)
        // returns -1 if the label is somehow gone, which lands these at the
        // top of the menu rather than crashing.
        var index = menu.index(of: transcriptionLabel) + 1
        for item in warningItems {
            menu.insertItem(item, at: index)
            index += 1
        }
    }

    // The ridge, in the 24×24 box the icon was drawn in. Kept in source so the
    // executable has no resource bundle to install alongside it (a true
    // single binary), and as points rather than the SVG string it used to be,
    // because the recording variant knocks this shape out of a filled badge
    // and that needs a real path, not a rasterized image.
    //
    // Filled rather than stroked on purpose. At the 16pt the menu bar actually
    // renders, a 1.5pt stroke breaks up into grey mush and stops reading as a
    // mountain; a solid silhouette survives. One continuous ridge also beats
    // separate peaks, whose gaps close up at that size and turn the mark into
    // a lopsided blob.
    private static let ridge: [NSPoint] = [
        NSPoint(x: 0.6, y: 19.6),
        NSPoint(x: 8.4, y: 5.4),
        NSPoint(x: 12.7, y: 13.2),
        NSPoint(x: 15.3, y: 9.3),
        NSPoint(x: 23.4, y: 19.6),
    ]

    /// Menu-bar status icons are nominally 18pt tall; 16 leaves breathing room.
    private static let iconSide: CGFloat = 16

    private static let idleImage = statusImage(recording: false)
    private static let recordingImage = statusImage(recording: true)

    /// Two states, two silhouettes.
    ///
    /// Idle is the ridge alone. Recording knocks the same ridge out of a filled
    /// slab, so the mark reads inverted, dark where it was light.
    ///
    /// Shape, not just colour. The tint was already switching to red, but a red
    /// mountain and a black mountain are the same object in peripheral vision,
    /// which is the only vision a menu bar ever gets, and identical to anyone
    /// who doesn't separate red from black. Inverting the fill changes the
    /// blob, which registers without being looked at. The red tint stays on top
    /// of it, so the two cues agree rather than compete.
    ///
    /// Still a template image: macOS recolours it for light and dark menu bars,
    /// and `contentTintColor` is what makes the recording one red.
    private static func statusImage(recording: Bool) -> NSImage {
        let side = iconSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let scale = side / 24
            let mountain = NSBezierPath()
            mountain.move(to: NSPoint(x: ridge[0].x * scale, y: ridge[0].y * scale))
            for point in ridge.dropFirst() {
                mountain.line(to: NSPoint(x: point.x * scale, y: point.y * scale))
            }
            mountain.close()

            guard recording else {
                mountain.fill()
                return true
            }

            // The slab stops exactly at the ridge's base line (y 19.6), not at
            // the bottom of the square. Any lower and a thin bar of ink is left
            // under the mountain, which at 16pt reads as an underline someone
            // forgot to delete rather than as ground.
            NSBezierPath(
                roundedRect: NSRect(
                    x: 0,
                    y: 3.4 * scale,
                    width: side,
                    height: (19.6 - 3.4) * scale
                ),
                xRadius: 3.0 * scale,
                yRadius: 3.0 * scale
            ).fill()

            // Punched out with .clear rather than filled even-odd. Even-odd
            // also fills whatever part of the ridge falls *outside* the slab:
            // here the base corners, which poke into the rounded corners and
            // come back as two red spurs hanging off the badge. Clearing can
            // only remove, so the mark can never spill past its own outline.
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                context.addPath(mountain.cgPath)
                context.fillPath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Show the registered global shortcut next to "Start recording".
    func showShortcut(_ combo: GlobalHotkey.Combo) {
        toggleItem.keyEquivalent = combo.keyEquivalent
        toggleItem.keyEquivalentModifierMask = combo.cocoaModifiers
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func changeFolderClicked() { onChangeFolder?() }
    @objc private func aboutClicked() { AboutPanel.show() }
    @objc private func quitClicked() { onQuit?() }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    /// Fired just before a menu draws.
    ///
    /// For the Capture submenu the cached snapshot shows immediately
    /// (SCShareableContent is async, so there's nothing to show synchronously
    /// on a first open) and the fetch it kicks off populates the list for the
    /// next open, or sooner via Refresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            onMenuOpen?()
            return
        }
        guard menu === captureMenu, !isRecording else { return }
        refreshContent()
    }
}
