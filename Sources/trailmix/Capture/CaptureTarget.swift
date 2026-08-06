import AppKit
import Foundation
import ScreenCaptureKit

/// What the video track points at. `none` still needs a filter behind the
/// scenes, because SCStream always requires one even for audio-only capture;
/// see CaptureStream.filter(for:).
enum CaptureTarget: Sendable, Equatable {
    case none
    case display(CGDirectDisplayID)
    case window(CGWindowID)

    var capturesVideo: Bool {
        if case .none = self { return false }
        return true
    }
}

/// A snapshot of what's capturable right now, for building the Capture menu.
///
/// Enumerating is deliberately lazy: SCShareableContent triggers the Screen
/// Recording prompt, and a user who only wants audio shouldn't hit it just by
/// opening the menu.
struct ShareableContent: Sendable {
    struct DisplayOption: Sendable, Identifiable {
        let id: CGDirectDisplayID
        let name: String
        /// Pixel dimensions, not points.
        let width: Int
        let height: Int
    }

    struct WindowOption: Sendable, Identifiable {
        let id: CGWindowID
        /// "Zoom: Team Standup" style label, app name first.
        let label: String
    }

    var displays: [DisplayOption] = []
    var windows: [WindowOption] = []

    static func fetch() async throws -> ShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )

        let displays = content.displays.enumerated().map { index, display in
            DisplayOption(
                id: display.displayID,
                name: Self.name(for: display, index: index),
                width: display.width,
                height: display.height
            )
        }

        var windows: [WindowOption] = []
        for window in content.windows {
            // Untitled and tiny windows are almost always chrome, panels, or
            // offscreen helpers; they'd bloat the menu.
            guard let title = window.title, !title.isEmpty else { continue }
            guard window.frame.width > 80, window.frame.height > 80 else { continue }
            let app = window.owningApplication?.applicationName ?? "Unknown"
            windows.append(WindowOption(id: window.windowID, label: "\(app): \(title)"))
        }
        windows.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        return ShareableContent(displays: displays, windows: windows)
    }

    /// SCDisplay has no display-name property, so fall back to the localized
    /// name from NSScreen when the screen numbers line up.
    private static func name(for display: SCDisplay, index: Int) -> String {
        let match = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return number?.uint32Value == display.displayID
        }
        if let name = match?.localizedName, !name.isEmpty { return name }
        return "Display \(index + 1)"
    }
}
