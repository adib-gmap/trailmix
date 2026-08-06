import AppKit
import Foundation
import UserNotifications

/// Best-effort user-visible notification, posted as trailmix.
///
/// This used to shell out to `osascript`, which works but posts the
/// notification *as Script Editor*, so trailmix's icon was wrong and clicking
/// "transcript ready" opened Script Editor. Now that there is a real signed
/// bundle with an identifier, `UNUserNotificationCenter` is available and the
/// notification belongs to the app that sent it. It also drops a `Process`
/// spawn per notification.
enum Notify {
    /// Authorization is requested once per process, lazily: asking at launch
    /// would put a permission dialog in front of a user who has not yet done
    /// anything that would produce a notification.
    private static let requested: Bool = {
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                Log.warn("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.info("notifications not permitted, check System Settings › Notifications")
            }
        }
        return true
    }()

    /// Without a delegate saying otherwise, a notification is suppressed while
    /// its own app is frontmost. trailmix is `.accessory` and effectively
    /// never frontmost, but it can be for a moment after the user clicks the
    /// menu, and a notification that silently vanishes some of the time is
    /// worse than one that never arrives.
    private static let presenter = Presenter()

    // Stateless, so sharing it across the actors that post notifications is
    // safe by construction rather than by locking.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        /// Clicking a notification opens the folder it is about. trailmix has
        /// no window to bring forward, so without this a click activates an
        /// app with nothing to show and looks like it did nothing.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard
                response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                let path = response.notification.request.content.userInfo[revealKey] as? String
            else { return }
            let url = URL(fileURLWithPath: path)
            await MainActor.run {
                // Select the folder in its parent rather than opening a new
                // Finder window on its contents: the files inside are the
                // point, and this shows them without burying the folder name.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private static let revealKey = "trailmix.reveal"

    /// - Parameter reveal: a folder to show in Finder when the notification is
    ///   clicked. Notifications with nothing to show pass nil.
    static func post(title: String, body: String, reveal: URL? = nil) {
        // UNUserNotificationCenter.current() raises if the executable isn't in
        // a bundle. That shouldn't happen (the bare binary can't get a mic
        // either) but an unraisable exception is not worth the risk.
        guard Bundle.main.bundleIdentifier != nil else {
            Log.warn("no bundle identifier, can't post: \(title): \(body)")
            return
        }
        _ = requested

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let reveal {
            content.userInfo = [revealKey: reveal.path]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.warn("couldn't post notification: \(error.localizedDescription)")
            }
        }
    }
}

/// Kept as a free function so the call sites read the same as they always did.
func notifyUser(title: String, body: String, reveal: URL? = nil) {
    Notify.post(title: title, body: body, reveal: reveal)
}
