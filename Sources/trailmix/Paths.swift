import Foundation

/// Every path trailmix derives from the home directory, in one place.
///
/// Not an abstraction for its own sake. `homeDirectoryForCurrentUser` returns
/// the real home today, and under the App Store sandbox it returns
/// `~/Library/Containers/us.stephenturner.trailmix/Data` instead. Nothing
/// throws when that happens: the log, the config file and the recordings root
/// all quietly relocate into the container, which for the recordings root means
/// a user who cannot find anything they recorded and no error to explain it.
/// That is the failure mode this project keeps producing, correct-looking and
/// silent, so the three derivations live together and a sandboxed build is one
/// file to change rather than a search.
///
/// Keeping `~/Trailmix` a real path under the sandbox needs
/// `com.apple.security.files.user-selected.read-write` and a security-scoped
/// bookmark, which is the actual cost of an App Store build. See the
/// Distribution section of STATUS.md.
enum Paths {
    /// The single call the sandbox would redirect.
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `~/Library/Logs/trailmix.log`. See `Log`, which explains why a plain
    /// file rather than the unified log.
    static let log = home.appendingPathComponent("Library/Logs/trailmix.log")

    /// `~/.config/trailmix/config.json`. See `Config`.
    static let config = home.appendingPathComponent(".config/trailmix/config.json")

    /// Where recordings go when nothing overrides it. `~/Recordings` was too
    /// generic a name to put in someone's home folder: it reads like a system
    /// folder and says nothing about what put it there.
    static let defaultRecordingsRoot = home.appendingPathComponent(
        "Trailmix", isDirectory: true)
}
