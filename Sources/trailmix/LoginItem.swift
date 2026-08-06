import AppKit
import ServiceManagement

/// Launch-at-login, backed by `SMAppService.mainApp`.
///
/// This replaces the hand-written LaunchAgent plist that the old CLI build
/// installed into ~/Library/LaunchAgents. SMAppService needs a real .app
/// bundle, which we now have; it registers the bundle itself, so there is no
/// path to go stale when the app moves, no `launchctl bootstrap` to fail
/// silently, and no daemon stdout/stderr sitting in world-readable /tmp.
///
/// The user can always revoke this from System Settings › General › Login
/// Items, which is why `isEnabled` reads the live status rather than caching.
enum LoginItem {
    /// Whether trailmix is currently registered to start at login.
    /// `.requiresApproval` counts as off: registration succeeded but macOS is
    /// waiting on the user, so nothing will actually launch yet.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS has the registration but the user hasn't approved it in
    /// System Settings. The menu surfaces this, since it's otherwise invisible.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registration is only meaningful for a bundled, launchable app. Running
    /// the executable straight out of .build has no bundle for SMAppService to
    /// register, and `register()` throws an opaque error. Better to grey the
    /// menu item out than to fail on click.
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Toggle the registration. Returns the resulting state so the caller can
    /// resync its checkmark without a second round trip.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.warn("couldn't \(enabled ? "enable" : "disable") launch at login: \(error)")
            notifyUser(
                title: "trailmix: launch at login",
                body: "\(error.localizedDescription)"
            )
        }
        return isEnabled
    }

    /// Open the Login Items pane so the user can approve a pending
    /// registration. `SMAppService.openSystemSettingsLoginItems()` targets the
    /// right pane on macOS 13+.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
