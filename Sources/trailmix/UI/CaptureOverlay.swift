import AppKit
import ScreenCaptureKit

/// A red border drawn around whatever is being recorded, the way Zoom outlines
/// a shared window. Without it there is no way to tell which of six Firefox
/// windows the menu's `Capture:` line actually refers to, and no way to notice
/// that the recording is pointed at the wrong one until it is over.
///
/// The overlay is a borderless click-through window sitting just above normal
/// windows. It never appears in the recording: a window filter contains only
/// the captured window, and the display filter excludes trailmix's own
/// application (see `CaptureStream.filter(for:in:)`).
///
/// The captured window's frame is re-read on a timer rather than observed.
/// Following a window properly means an AXObserver, which needs the
/// Accessibility permission on top of the two grants trailmix already asks
/// for; `CGWindowListCopyWindowInfo` needs nothing and a few frames of lag on
/// a border is not worth a third permission prompt.
@MainActor
final class CaptureOverlay {
    /// Thickness of the border, in points. Read by BorderView below.
    fileprivate static let borderWidth: CGFloat = 4
    fileprivate static let cornerRadius: CGFloat = 10
    private static let refreshInterval: TimeInterval = 0.2

    private var window: NSWindow?
    private var timer: Timer?
    private var target: CaptureTarget = .none

    /// Start outlining `target`. Audio-only targets show nothing.
    func show(for target: CaptureTarget) {
        hide()
        guard target.capturesVideo else { return }
        self.target = target

        guard let frame = Self.frame(of: target) else {
            // The window went away between picking it and starting. The
            // recording itself will have failed already; nothing to draw.
            Log.warn("capture outline: can't locate the capture target")
            return
        }

        let window = Self.makeWindow()
        window.setFrame(frame.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth), display: true)
        window.orderFront(nil)
        self.window = window

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        target = .none
    }

    /// Reposition onto the target's current frame, or hide if it's gone.
    private func follow() {
        guard let window else { return }
        guard let frame = Self.frame(of: target) else {
            // A closed window also stops the stream, which stops the session;
            // dropping the border immediately avoids a stale rectangle
            // hanging over the desktop until that lands.
            hide()
            return
        }
        let wanted = frame.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth)
        if wanted != window.frame {
            window.setFrame(wanted, display: true)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above ordinary windows so the border stays visible when the captured
        // app is frontmost, but below the menu bar and system panels.
        window.level = .floating
        // The border has to survive a space switch and a full-screen app, and
        // must never be what Cmd-` cycles to.
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.contentView = BorderView()
        return window
    }

    // MARK: - Locating the target

    /// The target's frame in AppKit screen coordinates, or nil if it's gone.
    private static func frame(of target: CaptureTarget) -> NSRect? {
        switch target {
        case .none:
            return nil
        case .display(let id):
            return screen(for: id)?.frame
        case .window(let id):
            return windowFrame(id).map(flipped)
        }
    }

    /// Quartz window bounds, which are top-left origin over the whole desktop.
    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], id
        ) as? [[String: Any]] else { return nil }
        guard let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// Quartz coordinates run top-down from the primary display's top-left;
    /// AppKit runs bottom-up from its bottom-left. Everything below the primary
    /// display's height flips around that one axis.
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return number?.uint32Value == id
        }
    }
}

/// Strokes the border just inside the view, leaving the middle transparent so
/// the window underneath stays fully visible and clickable.
private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let width = CaptureOverlay.borderWidth
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
            xRadius: CaptureOverlay.cornerRadius,
            yRadius: CaptureOverlay.cornerRadius
        )
        path.lineWidth = width
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
