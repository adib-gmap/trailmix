import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// The two TCC grants trailmix needs, and the only surface that can report on
/// them honestly.
///
/// `make doctor` asks the same questions but from a process launched by a
/// terminal, and macOS attributes a TCC query to the *responsible* process,
/// which for anything spawned from a shell is usually the terminal. So a
/// terminal saying "microphone: ok" may be reporting the terminal's own grant.
/// The menu runs inside the app LaunchServices started, which is the only
/// context where the answer is about Trailmix.
enum Permission: CaseIterable, Hashable, Sendable {
    case microphone
    case screenRecording

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        }
    }

    /// The System Settings pane that governs it. Needed because neither grant
    /// can be re-prompted once refused: `AVCaptureDevice.requestAccess` returns
    /// false immediately for a denied microphone, and screen capture cannot
    /// prompt at all.
    var settingsURL: URL {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    /// Whether a fresh grant reaches the running process. It does for the
    /// microphone and does not for screen recording, which is why granting the
    /// latter looks like it worked and changes nothing until a relaunch.
    var appliesWithoutRelaunch: Bool {
        switch self {
        case .microphone: true
        case .screenRecording: false
        }
    }
}

enum PermissionState: Sendable, Equatable {
    case granted
    /// Not granted, and worth asking for.
    case notGranted
    /// Refused. Only System Settings can undo this; asking again does nothing.
    case denied

    var label: String {
        switch self {
        case .granted: "granted"
        case .notGranted: "not granted"
        case .denied: "denied"
        }
    }
}

struct PermissionStatus: Sendable, Equatable {
    let permission: Permission
    let state: PermissionState
}

enum Permissions {
    /// Privacy & Security itself, for the row that just opens the pane.
    static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!

    static func status(of permission: Permission) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notGranted
            case .denied, .restricted: return .denied
            @unknown default: return .notGranted
            }
        case .screenRecording:
            // Preflight reports the grant without prompting. There is no way to
            // tell "never asked" from "refused" here, so an ungranted state is
            // always reported as worth asking for; `request` falls back to
            // System Settings when the ask changes nothing.
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
    }

    static func all() -> [PermissionStatus] {
        Permission.allCases.map { PermissionStatus(permission: $0, state: status(of: $0)) }
    }

    /// Ask for one grant and report where things ended up.
    ///
    /// Neither call blocks on the user in the way you would hope. The
    /// microphone shows a real Allow/Don't Allow dialog and resolves.
    /// `CGRequestScreenCaptureAccess` puts the app in the Screen Recording list
    /// and shows Apple's own "open System Settings" dialog, then returns the
    /// state as it was, so the caller has to re-read it rather than trust the
    /// return value.
    static func request(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
        }
        return status(of: permission)
    }

    static func openSettings(for permission: Permission?) {
        NSWorkspace.shared.open(permission?.settingsURL ?? privacySettingsURL)
    }

    // MARK: - Gating a recording

    /// Which grants the current selection actually needs.
    ///
    /// Screen recording always, audio-only included, because `SCStream` demands
    /// a content filter whatever you ask it for. The microphone only when that
    /// source is switched on, so someone recording computer audio and a display
    /// is never blocked by a grant they will not use.
    ///
    /// Returned in `allCases` order so the submenu, the idle line, and the
    /// modal all name them the same way round.
    static func required(for sources: CaptureStream.Sources) -> [Permission] {
        Permission.allCases.filter { permission in
            switch permission {
            case .screenRecording: true
            case .microphone: sources.microphone
            }
        }
    }

    /// Required but not granted. Non-empty means a recording must not start.
    ///
    /// Blocking rather than starting anyway is the whole point. An ungranted
    /// microphone does not throw: `AVAudioEngine` starts, the tap runs, buffers
    /// arrive, and every sample in them is zero. That is a `mic.caf` of exactly
    /// the right length containing nothing, which is the failure this project
    /// has shipped three separate times and never noticed until playback.
    static func blockers(
        for sources: CaptureStream.Sources,
        given statuses: [PermissionStatus]
    ) -> [Permission] {
        let granted = Set(statuses.filter { $0.state == .granted }.map(\.permission))
        return required(for: sources).filter { !granted.contains($0) }
    }

    /// The idle status line when something is missing, in place of "Idle".
    ///
    /// Greying a row without saying why is what makes a disabled control feel
    /// broken, and the line above the toggle is already where the menu says
    /// what is going on.
    static func blockedReason(_ blockers: [Permission]) -> String? {
        guard !blockers.isEmpty else { return nil }
        return "Needs " + blockers.map(\.title).joined(separator: " and ")
    }

    /// What the modal says: one paragraph per missing grant, each naming why it
    /// is needed rather than only that it is. The microphone paragraph names
    /// the way out, since turning that source off is a legitimate answer and
    /// otherwise looks like a dead end.
    static func explanation(_ blockers: [Permission]) -> String {
        blockers.map { permission in
            switch permission {
            case .screenRecording:
                "Screen Recording is required for every recording, audio only "
                    + "included, because macOS routes all capture through "
                    + "ScreenCaptureKit."
            case .microphone:
                "Microphone is needed because the Microphone source is switched "
                    + "on. Switch it off in the menu to record without it."
            }
        }.joined(separator: "\n\n")
    }

    /// One line for the log, written at every launch.
    ///
    /// Worth the line because this is the only record of what the *app* was
    /// entitled to, as opposed to what `make doctor` saw from a terminal. When
    /// a recording comes out wrong, the log is the first place anyone looks,
    /// and "screen recording: not granted" at startup answers most of it.
    static func logLine(_ statuses: [PermissionStatus]) -> String {
        let parts = statuses.map { "\($0.permission.title.lowercased()): \($0.state.label)" }
        return "permissions · " + parts.joined(separator: " · ")
    }

    /// The parent row's title.
    ///
    /// It names the problem rather than staying a bare noun, the same way
    /// "Video Capture: None" does: a permission that is missing is the single
    /// most likely reason a recording will come out wrong, and it should not
    /// take a hover to find that out.
    static func summary(_ statuses: [PermissionStatus]) -> String {
        let missing = statuses.filter { $0.state != .granted }
        switch missing.count {
        case 0: return "Permissions"
        // Named outright when it is the only one, since "1 missing" makes you
        // hover to learn something that fits in the row.
        case 1: return "Permissions: \(missing[0].permission.title) missing"
        default: return "Permissions: \(missing.count) missing"
        }
    }
}
