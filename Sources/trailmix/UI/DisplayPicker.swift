import AppKit

/// The screen chooser shown when a display recording starts, modelled on the
/// macOS screenshot toolbar's "Record Entire Screen": every screen is dimmed
/// except the one under the pointer, the pointer is a camcorder, and a click
/// records that screen. Esc, or the start/stop shortcut pressed again,
/// cancels and nothing is recorded.
///
/// Only worth showing with two or more screens; `AppController` skips it
/// otherwise. The picker windows are gone before the stream starts, so they
/// can never appear in the recording.
@MainActor
final class DisplayPicker {
    private static var active: DisplayPicker?

    private var windows: [PickerWindow] = []
    private var continuation: CheckedContinuation<CGDirectDisplayID?, Never>?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    /// Show the picker and wait for a click. `current` is the display the
    /// menu already points at; it is where the pointer starts in practice,
    /// so nothing special is drawn for it. Nil means cancelled.
    static func pick(current: CGDirectDisplayID?) async -> CGDirectDisplayID? {
        active?.finish(with: nil)
        let picker = DisplayPicker()
        active = picker
        return await withCheckedContinuation { continuation in
            picker.continuation = continuation
            picker.show()
        }
    }

    /// Dismiss a picker that is up, if any. True when there was one: the
    /// caller then knows the click or shortcut it is handling was a cancel.
    @discardableResult
    static func cancelActive() -> Bool {
        guard let picker = active else { return false }
        picker.finish(with: nil)
        return true
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            let window = PickerWindow(screen: screen, id: id)
            window.onPick = { [weak self] id in self?.finish(with: id) }
            window.onHover = { [weak self] in self?.updateHover() }
            windows.append(window)
        }
        guard !windows.isEmpty else {
            finish(with: nil)
            return
        }

        // Key-window status is what routes Esc to the monitor below, and the
        // windows have to be ours to draw the cursor. Focus goes back to
        // whatever had it in finish().
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        (windows.first { $0.frame.contains(mouse) } ?? windows[0]).makeKey()
        Self.cursor.push()
        updateHover()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            MainActor.assumeIsolated { self?.finish(with: nil) }
            return nil
        }
    }

    /// Light the screen under the pointer, dim the rest. Re-read from the
    /// global mouse location rather than trusting enter/exit pairs, which
    /// can arrive out of order when the pointer crosses a screen edge fast.
    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.setLit(window.frame.contains(mouse))
        }
    }

    private func finish(with id: CGDirectDisplayID?) {
        guard let continuation else { return }
        self.continuation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows = []
        if Self.active === self { Self.active = nil }
        if let previousApp, previousApp != .current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        continuation.resume(returning: id)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A white camcorder with a dark outline, readable on any wallpaper. The
    /// hot spot is its centre, so the click lands where the glyph is.
    static let cursor: NSCursor = {
        let size = NSSize(width: 44, height: 44)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "record") else {
                return false
            }
            let glyph = NSRect(x: 6, y: 9, width: 32, height: 26)
            let shape = NSImage.SymbolConfiguration(pointSize: 30, weight: .bold)
            let outline = symbol.withSymbolConfiguration(shape.applying(.init(paletteColors: [.black])))
            let fill = symbol.withSymbolConfiguration(shape.applying(.init(paletteColors: [.white])))
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                outline?.draw(in: glyph.offsetBy(dx: dx, dy: dy))
            }
            fill?.draw(in: glyph)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()
}

/// One borderless window per screen. Above everything, including the menu
/// bar, like the system picker; follows the pointer onto any space.
private final class PickerWindow: NSWindow {
    var onPick: ((CGDirectDisplayID) -> Void)?
    var onHover: (() -> Void)?
    private let view: PickerView

    init(screen: NSScreen, id: CGDirectDisplayID) {
        view = PickerView(id: id, name: screen.localizedName)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        contentView = view
        view.onPick = { [weak self] id in self?.onPick?(id) }
        view.onHover = { [weak self] in self?.onHover?() }
    }

    override var canBecomeKey: Bool { true }

    func setLit(_ lit: Bool) {
        view.lit = lit
    }
}

/// Dim veil with a label; near-clear when lit. The lit fill is not fully
/// transparent on purpose: AppKit passes clicks through transparent pixels
/// of a non-opaque window, and the click is the whole point.
private final class PickerView: NSView {
    var onPick: ((CGDirectDisplayID) -> Void)?
    var onHover: (() -> Void)?
    var lit = false {
        didSet { if lit != oldValue { needsDisplay = true } }
    }

    private let id: CGDirectDisplayID
    private let name: String

    init(id: CGDirectDisplayID, name: String) {
        self.id = id
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { DisplayPicker.cursor.set(); onHover?() }
    override func mouseExited(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { DisplayPicker.cursor.set() }
    override func mouseDown(with event: NSEvent) { onPick?(id) }

    override func draw(_ dirtyRect: NSRect) {
        (lit ? NSColor.white.withAlphaComponent(0.01) : NSColor.black.withAlphaComponent(0.5)).setFill()
        bounds.fill()

        let title = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let hint = NSAttributedString(
            string: lit ? "Click to record this screen  ·  Esc to cancel" : "Move the pointer here to choose this screen",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        let titleSize = title.size(), hintSize = hint.size()
        let pillWidth = max(titleSize.width, hintSize.width) + 48
        let pillHeight = titleSize.height + hintSize.height + 36
        let pill = NSRect(
            x: bounds.midX - pillWidth / 2, y: bounds.midY - pillHeight / 2,
            width: pillWidth, height: pillHeight
        )
        NSColor.black.withAlphaComponent(lit ? 0.6 : 0.35).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 16, yRadius: 16).fill()
        title.draw(at: NSPoint(x: pill.midX - titleSize.width / 2, y: pill.maxY - 18 - titleSize.height))
        hint.draw(at: NSPoint(x: pill.midX - hintSize.width / 2, y: pill.minY + 16))
    }
}
