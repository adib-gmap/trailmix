import AppKit

/// The About Trailmix panel.
///
/// `orderFrontStandardAboutPanel` rather than a hand-built window: it already
/// draws the bundle icon, name and version in the shape people expect, reads
/// them straight out of `Info.plist`, and is one window this app doesn't have
/// to own the lifetime of. Only the credits block is ours.
@MainActor
enum AboutPanel {
    static let sourceURL = URL(string: "https://github.com/stephenturner/trailmix")!
    static let authorURL = URL(string: "https://stephenturner.us")!

    /// The copyright line. Undocumented, but it is a real key the panel reads,
    /// and an empty string is the only way to get rid of the line: left alone
    /// the panel prints `NSHumanReadableCopyright` from the bundle, and that
    /// key has to stay put for Finder's Get Info.
    private static let copyrightKey = NSApplication.AboutPanelOptionKey(rawValue: "Copyright")

    static func show() {
        // An .accessory app is never frontmost on its own, so without this the
        // panel opens behind whatever the user was looking at and the menu item
        // reads as dead. Same reason the duration and folder prompts do it.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            // Suppresses the build number. The version line is assembled as
            // "Version <applicationVersion> (<version>)" from
            // CFBundleShortVersionString and CFBundleVersion; blanking the
            // second one drops the parentheses with it rather than leaving
            // "Version 0.1.0 ()". Only this key is overridden, so the marketing
            // version still comes from App/Info.plist and stays the one place a
            // version number is written down.
            .version: "",
            copyrightKey: "",
        ])
    }

    private static var credits: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 2

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]

        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(
                string: "Menu-bar recorder and transcriber. Computer audio, "
                    + "microphone, and optionally a window or a display, "
                    + "transcribed on-device.\n\n",
                attributes: body
            )
        )
        text.append(link("Source code", to: sourceURL, base: body))
        // Outside the link: it labels the licence of what the link points at,
        // and clicking "(FSL-1.1-MIT)" landing on the repo would be a small lie.
        text.append(NSAttributedString(string: " (FSL-1.1-MIT)\n", attributes: body))
        text.append(NSAttributedString(string: "Developed by ", attributes: body))
        text.append(link("Stephen Turner", to: authorURL, base: body))
        return text
    }

    private static func link(
        _ label: String,
        to url: URL,
        base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = base
        attributes[.link] = url
        return NSAttributedString(string: label, attributes: attributes)
    }
}
