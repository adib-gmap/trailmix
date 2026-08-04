import AppKit
import Carbon.HIToolbox

/// Where a system-wide record shortcut would land if one is ever wired up.
///
/// Kept as data rather than deleted: the choice took some working out and is
/// the awkward part to rediscover. ⌘R is refresh nearly everywhere. ⇧⌘4 and
/// ⇧⌘5 are macOS screenshots and Kap has taken ⇧⌘6, so 7 is the first key
/// clear of the screen-capture range.
///
/// Nothing registers this today — the menu deliberately shows no shortcut,
/// because a status-item key equivalent only fires with the menu already open.
/// Registering it for real is `RegisterEventHotKey(kVK_ANSI_7, …)` at launch,
/// dispatched to the same `onToggle` callback the menu item uses.
enum Shortcut {
    static let recordKeyCode = UInt32(kVK_ANSI_7)
    static let recordModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    /// How it would be written in a menu, if it ever appears in one.
    static let recordDisplay = "⇧⌘7"
}

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
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

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    /// The user picked a new recordings root.
    var onChangeFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Fired whenever the user changes a source or capture target, so the
    /// selection can be persisted to config.
    var onSourcesChanged: ((CaptureStream.Sources) -> Void)?
    /// The user asked for the transcription model to be fetched now.
    var onDownloadModel: (() -> Void)?
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
        // settings people change most, and a submenu made the common case —
        // glance at the menu, see what is armed — take a hover and a wait.
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
        // it selects — it sits beside two audio rows, and "Capture" alone read
        // like it governed them too.
        captureMenu = NSMenu()
        captureMenu.autoenablesItems = false
        captureItem = NSMenuItem(title: "Video Capture", action: nil, keyEquivalent: "")
        captureItem.submenu = captureMenu
        menu.addItem(captureItem)

        menu.addItem(.separator())

        // No key equivalent. An NSStatusItem's menu only handles one while the
        // menu is already open, so a shortcut here buys a keystroke over just
        // clicking the item you are looking at. Advertising one implies a
        // global hotkey that doesn't exist.
        //
        // A real one means RegisterEventHotKey (Carbon, no extra TCC prompt)
        // or an NSEvent global monitor (needs Accessibility), registered at
        // launch and routed to `onToggle` — the same callback the click uses,
        // so nothing below this line has to change to add it. `Shortcut.record`
        // holds the intended default.
        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: ""
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
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

        let quit = NSMenuItem(
            title: "Quit trailmix",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        super.init()

        for item in [
            toggleItem, openFolder, changeFolderItem, quit,
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
        }

        applySources()
        rebuildCaptureMenu()
    }

    /// Seed the selection from config at startup. A saved display that is no
    /// longer attached falls back to audio only, which `rebuildCaptureMenu`
    /// reconciles once enumeration completes.
    func restore(sources: CaptureStream.Sources) {
        self.sources = sources
        applySources()
        rebuildCaptureMenu()
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the ridge mark (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        isRecording = recording
        stateLabel.title = recording ? "● Recording · \(elapsed ?? "0:00")" : "Idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        toggleItem.isEnabled = true
        statusItem.button?.image = recording ? Self.recordingImage : Self.idleImage
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        applySources()
    }

    /// Capture has stopped but the files aren't closed yet. The video needs a
    /// finalization pass that can take a moment on a long recording, and the
    /// gap has to look like progress rather than a frozen menu.
    func showFinishing() {
        isRecording = false
        stateLabel.title = "Finishing…"
        toggleItem.title = "Finishing…"
        statusItem.button?.image = Self.idleImage
        statusItem.button?.contentTintColor = nil
        applySources()
        // applySources() re-enables the toggle whenever sources are non-empty;
        // starting a new recording before this one has closed its files is
        // exactly what must not happen here.
        toggleItem.isEnabled = false
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

    // MARK: - Launch at login
    //
    // No menu row. Launching trailmix is a double-click in ~/Applications and
    // a login item is a preference, not a control — it earned a permanent row
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
    /// menu; nil hides it. Independent of recording state — a new recording
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
            modelItem.title = "Model download failed — retry"
            modelItem.isEnabled = true
        case .present:
            break  // handled by the guard above
        }
    }

    @objc private func modelClicked() { onDownloadModel?() }

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
    // executable has no resource bundle to install alongside it — true
    // single-binary — and as points rather than the SVG string it used to be,
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
    /// slab, so the mark reads inverted — dark where it was light.
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
            // also fills whatever part of the ridge falls *outside* the slab —
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

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func changeFolderClicked() { onChangeFolder?() }
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
