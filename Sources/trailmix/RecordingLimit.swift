import ArgumentParser
import Foundation

/// How long a recording is allowed to run before it stops itself.
///
/// A limit is per-recording and resets to none when the recording stops: it is
/// picked because *this* webinar is an hour, not as a standing preference, and
/// a saved limit would silently cut short a recording made months later for a
/// different reason. Nothing here is written to config.
///
/// Deliberately free of AppKit so `trailmix timer` can exercise the parser
/// without a bundle, a menu, or a human, which is the only way any of this
/// gets checked, since everything downstream of a menu-bar click needs someone
/// to press the button.
struct RecordingLimit: Equatable, Comparable, Sendable {
    /// Always positive, and never more than `maximum`.
    let seconds: TimeInterval

    /// The ceiling on any limit, whether typed, picked, or extended into.
    ///
    /// Not a safety belt on its own: `Config.maxRecordingHours` stops a
    /// recording that has no limit at all. This is the bound on what the user
    /// is allowed to *ask* for, and it exists because the thing being bounded
    /// is disk: an unattended 4K capture is a few GB an hour.
    static let maximum = RecordingLimit(seconds: 8 * 3600)

    /// The shortest limit the menu will accept. The parser itself allows
    /// anything above zero so `--stop-after 90s` can drive the whole auto-stop
    /// path in a minute and a half instead of a quarter of an hour; policy
    /// about what a *person* may pick belongs to the dialog, not here.
    static let shortestPickable: TimeInterval = 60

    static let presets: [RecordingLimit] = [
        RecordingLimit(seconds: 15 * 60),
        RecordingLimit(seconds: 30 * 60),
        RecordingLimit(seconds: 45 * 60),
        RecordingLimit(seconds: 3600),
        RecordingLimit(seconds: 2 * 3600),
        RecordingLimit(seconds: 3 * 3600),
        RecordingLimit(seconds: 4 * 3600),
        maximum,
    ]

    /// Offered as "Add …" rows while a recording is running.
    static let increments: [TimeInterval] = [15 * 60, 3600]

    /// How long before the deadline the "stopping soon" warning fires. A limit
    /// this short or shorter gets no warning: it would arrive at the same
    /// moment as the limit was set, which is noise rather than notice.
    static let warningLead: TimeInterval = 5 * 60

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    static func < (lhs: RecordingLimit, rhs: RecordingLimit) -> Bool {
        lhs.seconds < rhs.seconds
    }

    /// Push the limit out by `interval`, stopping at `maximum`.
    func extended(by interval: TimeInterval) -> RecordingLimit {
        RecordingLimit(seconds: min(seconds + interval, Self.maximum.seconds))
    }

    // MARK: - Parsing

    enum ParseFailure: Error {
        case empty
        case unreadable
        case notPositive
        case tooLong

        /// Written to be shown to the user verbatim, in a dialog that has
        /// already said what the field is for.
        var message: String {
            switch self {
            case .empty:
                "Enter a duration, like 70 or 1:10."
            case .unreadable:
                "Couldn't read that as a duration. Try 70, 70m, 1:10, or 1h10m."
            case .notPositive:
                "A recording has to run for longer than that."
            case .tooLong:
                // Read off `maximum` rather than written out, so raising the
                // cap can't leave the rejection message quoting the old one.
                "\(RecordingLimit.maximum.menuTitle) is the longest a recording can be set to run."
            }
        }
    }

    /// Read a duration the way someone would write one.
    ///
    /// Accepts `1:10` (h:mm), `1h10m`, `70m`, `90s`, and a bare `70`. A bare
    /// number is minutes, because the number people reach for here is the
    /// length of a meeting and meetings are counted in minutes. `70` meaning
    /// 70 hours would be absurd, and `70` meaning 70 seconds would be useless.
    static func parse(_ text: String) throws -> RecordingLimit {
        let input = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !input.isEmpty else { throw ParseFailure.empty }

        let seconds = input.contains(":")
            ? try colonForm(input)
            : try unitForm(input)

        guard seconds > 0 else { throw ParseFailure.notPositive }
        guard seconds <= maximum.seconds else { throw ParseFailure.tooLong }
        return RecordingLimit(seconds: seconds)
    }

    /// `h:mm`. Minutes are bounded at 59 so `1:70` is rejected rather than
    /// read as 2:10: someone who wrote that meant something else.
    private static func colonForm(_ input: String) throws -> TimeInterval {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let hours = Int(parts[0]),
            let minutes = Int(parts[1]),
            parts[1].count == 2,
            hours >= 0,
            (0...59).contains(minutes)
        else { throw ParseFailure.unreadable }
        return TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60
    }

    /// A run of number/unit pairs: `1h10m`, `70m`, `90s`, `2 h 30 m`, or a
    /// bare number meaning minutes.
    private static func unitForm(_ input: String) throws -> TimeInterval {
        var total: TimeInterval = 0
        var sawUnit = false
        var scanner = Substring(input)

        while !scanner.isEmpty {
            scanner = scanner.drop { $0 == " " }
            if scanner.isEmpty { break }

            let digits = scanner.prefix { $0.isNumber || $0 == "." }
            guard !digits.isEmpty, let value = Double(digits) else {
                throw ParseFailure.unreadable
            }
            scanner = scanner.dropFirst(digits.count).drop { $0 == " " }

            switch scanner.first {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case nil:
                // A bare number is minutes, but only when it stands alone.
                // "1h 10" is someone mid-thought, not a duration.
                guard !sawUnit else { throw ParseFailure.unreadable }
                return value * 60
            default:
                throw ParseFailure.unreadable
            }
            sawUnit = true
            scanner = scanner.dropFirst()
        }

        guard sawUnit else { throw ParseFailure.unreadable }
        return total
    }

    // MARK: - Display

    /// Spelled out, for the row you read once while choosing: "1 hour 10
    /// minutes".
    var menuTitle: String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        // Seconds only surface for values typed at the CLI; no preset has them.
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// `h:mm`, for the row you glance at every few minutes and for the menu
    /// bar. Rounded up, so a limit of 90 seconds never reads as `0:01` at the
    /// moment it is set.
    var compact: String { Self.hoursMinutes(seconds) }

    /// `h:mm`, rounded up. Used for anything counting *down*: showing `0:00`
    /// for the last full minute of a recording reads as a stall.
    static func hoursMinutes(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.up))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// `m:ss`, or `h:mm:ss` past the hour. Used for anything counting *up*.
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// `trailmix timer <duration>`: show how a duration would be read.
///
/// Named `TimerCheck` rather than `Timer` on purpose: a module-level `Timer`
/// would shadow `Foundation.Timer` and capture the elapsed-time ticker's
/// `Timer.scheduledTimer` call in `AppController` without anything failing.
struct TimerCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timer",
        abstract: "Parse a recording-timer duration and report how it was read."
    )

    @Argument(help: "A duration: 70, 70m, 1:10, 1h10m, 90s.")
    var duration: String

    func run() throws {
        do {
            let limit = try RecordingLimit.parse(duration)
            print("\(duration) → \(limit.seconds) s · \(limit.menuTitle) · \(limit.compact)")
            if limit.seconds < RecordingLimit.shortestPickable {
                print("note: below the \(Int(RecordingLimit.shortestPickable))s minimum the menu accepts")
            }
        } catch let failure as RecordingLimit.ParseFailure {
            print("\(duration) → rejected: \(failure.message)")
            throw ExitCode(1)
        }
    }
}
