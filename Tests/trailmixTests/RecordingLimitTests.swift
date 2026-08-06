import Foundation
import Testing

@testable import trailmix

/// The recording-timer parser reads free text someone types into a dialog, and
/// every mistake it can make is quiet. A duration read as the wrong number
/// doesn't fail, it stops the recording at the wrong time, which is only
/// discovered afterwards by the recording being the wrong length.
///
/// The accepted cases below are transcribed from the table in `STATUS.md` that
/// was built by running `trailmix timer` by hand. That was the check; this is
/// the same check that runs every build.
@Suite("RecordingLimit.parse")
struct RecordingLimitParseTests {

    // MARK: - Accepted

    /// Every spelling of seventy minutes. A bare number means minutes, because
    /// the number people reach for is the length of a meeting.
    @Test("the same duration written five ways",
          arguments: ["70", "70m", "1:10", "1h10m", "1 h 10 m"])
    func seventyMinutes(input: String) throws {
        #expect(try RecordingLimit.parse(input).seconds == 4200)
    }

    @Test("units and fractions",
          arguments: [("1.5h", 5400.0), ("90s", 90.0), ("0:15", 900.0), ("8h", 28800.0),
                      ("2h", 7200.0), ("45", 2700.0), ("45m", 2700.0), ("1:00", 3600.0)])
    func acceptedValues(input: String, seconds: TimeInterval) throws {
        #expect(try RecordingLimit.parse(input).seconds == seconds)
    }

    /// Exactly the cap is allowed; one second over is not. Worth pinning because
    /// it is a `<=` that could drift to `<` without anything else noticing.
    @Test("the maximum itself parses")
    func maximumIsInclusive() throws {
        #expect(try RecordingLimit.parse("8h").seconds == RecordingLimit.maximum.seconds)
    }

    @Test("surrounding whitespace and capitals are tolerated",
          arguments: ["  70  ", "70M", "1H10M", " 1:10 "])
    func lenientInput(input: String) throws {
        #expect(try RecordingLimit.parse(input).seconds == 4200)
    }

    // MARK: - Rejected

    /// Each of these has a distinct reason, and the reason is shown to the user
    /// verbatim, so the mapping matters as much as the rejection.
    @Test("over the cap")
    func tooLong() {
        for input in ["9h", "8h1m", "8:01", "100h"] {
            #expect(throws: RecordingLimit.ParseFailure.tooLong) {
                try RecordingLimit.parse(input)
            }
        }
    }

    @Test("zero and below")
    func notPositive() {
        for input in ["0", "0m", "0:00", "0s"] {
            #expect(throws: RecordingLimit.ParseFailure.notPositive) {
                try RecordingLimit.parse(input)
            }
        }
    }

    @Test("empty input")
    func empty() {
        for input in ["", "   "] {
            #expect(throws: RecordingLimit.ParseFailure.empty) {
                try RecordingLimit.parse(input)
            }
        }
    }

    /// `1:70` is rejected rather than read as 2:10, and `1:5` rather
    /// than as 1:05. Someone who typed either meant something else, and guessing
    /// which would set a timer they did not ask for.
    @Test("malformed h:mm is rejected, not reinterpreted")
    func malformedColonForm() {
        for input in ["1:70", "1:5", "1:", ":10", "1:2:3", "1:xx"] {
            #expect(throws: RecordingLimit.ParseFailure.unreadable) {
                try RecordingLimit.parse(input)
            }
        }
    }

    /// A bare number is minutes only when it stands alone. `1h 10` is someone
    /// mid-thought, and reading it as 1h10m would be inventing intent.
    @Test("a bare number after a unit is rejected")
    func bareNumberAfterUnit() {
        for input in ["1h 10", "1h10", "2m 30"] {
            #expect(throws: RecordingLimit.ParseFailure.unreadable) {
                try RecordingLimit.parse(input)
            }
        }
    }

    @Test("nonsense")
    func unreadable() {
        for input in ["abc", "1x", "h", "m", "-5", "1..5h", "∞"] {
            #expect(throws: RecordingLimit.ParseFailure.unreadable) {
                try RecordingLimit.parse(input)
            }
        }
    }
}

/// Formatting and arithmetic. Two different clock formats exist on purpose and
/// the difference between them is easy to get backwards.
@Suite("RecordingLimit display")
struct RecordingLimitDisplayTests {

    /// Counting up. Shows `m:ss`, and grows an hours field only once there is
    /// one.
    @Test("clock counts up and truncates")
    func clock() {
        #expect(RecordingLimit.clock(0) == "0:00")
        #expect(RecordingLimit.clock(1) == "0:01")
        #expect(RecordingLimit.clock(59) == "0:59")
        #expect(RecordingLimit.clock(60) == "1:00")
        #expect(RecordingLimit.clock(3599) == "59:59")
        #expect(RecordingLimit.clock(3600) == "1:00:00")
        #expect(RecordingLimit.clock(3661) == "1:01:01")
        // Truncates rather than rounds: 59.9 seconds elapsed is not a minute.
        #expect(RecordingLimit.clock(59.9) == "0:59")
        // Negative elapsed is nonsense but must not render as a negative clock.
        #expect(RecordingLimit.clock(-10) == "0:00")
    }

    /// Counting down. Rounds **up**, so the last full minute of a recording
    /// reads as `0:01` rather than `0:00`, which would look like a stall.
    @Test("hoursMinutes counts down and rounds up")
    func hoursMinutes() {
        #expect(RecordingLimit.hoursMinutes(0) == "0:00")
        #expect(RecordingLimit.hoursMinutes(1) == "0:01")
        #expect(RecordingLimit.hoursMinutes(59) == "0:01")
        #expect(RecordingLimit.hoursMinutes(60) == "0:01")
        #expect(RecordingLimit.hoursMinutes(61) == "0:02")
        #expect(RecordingLimit.hoursMinutes(3600) == "1:00")
        #expect(RecordingLimit.hoursMinutes(4200) == "1:10")
        #expect(RecordingLimit.hoursMinutes(-10) == "0:00")
    }

    /// The two formats disagree deliberately, and this is the case that shows
    /// it: 90 seconds is "1:30 elapsed" counting up and "2 minutes left"
    /// counting down.
    @Test("the two clocks differ on purpose")
    func clocksDifferDeliberately() {
        #expect(RecordingLimit.clock(90) == "1:30")
        #expect(RecordingLimit.hoursMinutes(90) == "0:02")
    }

    @Test("menuTitle spells the duration out")
    func menuTitle() {
        #expect(RecordingLimit(seconds: 3600).menuTitle == "1 hour")
        #expect(RecordingLimit(seconds: 7200).menuTitle == "2 hours")
        #expect(RecordingLimit(seconds: 60).menuTitle == "1 minute")
        #expect(RecordingLimit(seconds: 900).menuTitle == "15 minutes")
        #expect(RecordingLimit(seconds: 4200).menuTitle == "1 hour 10 minutes")
        #expect(RecordingLimit(seconds: 90).menuTitle == "1 minute 30 seconds")
        // Never empty: a zero limit still has to render as something.
        #expect(RecordingLimit(seconds: 0).menuTitle == "0 seconds")
    }

    @Test("compact is the countdown format")
    func compact() {
        #expect(RecordingLimit(seconds: 4200).compact == "1:10")
        #expect(RecordingLimit(seconds: 3600).compact == "1:00")
    }

    /// What a parsed duration shows back to the user has to be readable as the
    /// thing they typed, since `trailmix timer` exists to confirm exactly that.
    @Test("parse and display round-trip through compact")
    func parseDisplayRoundTrip() throws {
        for input in ["1:10", "2:30", "0:15", "8:00"] {
            #expect(try RecordingLimit.parse(input).compact == input)
        }
    }
}

/// The values the menu offers, and the arithmetic behind the "Add …" rows.
@Suite("RecordingLimit values")
struct RecordingLimitValueTests {

    @Test("presets are sorted, positive, and within the cap")
    func presetsAreWellFormed() {
        let presets = RecordingLimit.presets
        #expect(!presets.isEmpty)
        #expect(presets == presets.sorted())
        for preset in presets {
            #expect(preset.seconds >= RecordingLimit.shortestPickable)
            #expect(preset <= RecordingLimit.maximum)
        }
        // No duplicates, or the menu would show the same row twice.
        #expect(Set(presets.map(\.seconds)).count == presets.count)
    }

    @Test("every preset parses back from what the menu shows")
    func presetsRoundTrip() throws {
        for preset in RecordingLimit.presets {
            #expect(try RecordingLimit.parse(preset.compact).seconds == preset.seconds)
        }
    }

    @Test("increments are positive")
    func incrementsArePositive() {
        #expect(!RecordingLimit.increments.isEmpty)
        for increment in RecordingLimit.increments {
            #expect(increment > 0)
        }
    }

    /// "Add 15 minutes" pushes the end back, and stops at the cap rather than
    /// sailing past it.
    @Test("extending adds, and clamps at the maximum")
    func extending() {
        let hour = RecordingLimit(seconds: 3600)
        #expect(hour.extended(by: 900).seconds == 4500)
        #expect(hour.extended(by: 0).seconds == 3600)

        let nearCap = RecordingLimit(seconds: RecordingLimit.maximum.seconds - 60)
        #expect(nearCap.extended(by: 3600).seconds == RecordingLimit.maximum.seconds)
        #expect(RecordingLimit.maximum.extended(by: 3600).seconds
            == RecordingLimit.maximum.seconds)
    }

    /// Extending is what the menu offers instead of re-picking a preset, so it
    /// has to be monotonic: repeated clicks never shorten a recording.
    @Test("extending never shortens")
    func extendingIsMonotonic() {
        var limit = RecordingLimit(seconds: 60)
        for _ in 0 ..< 20 {
            let next = limit.extended(by: 3600)
            #expect(next.seconds >= limit.seconds)
            limit = next
        }
        #expect(limit.seconds == RecordingLimit.maximum.seconds)
    }

    @Test("ordering compares by duration")
    func ordering() {
        #expect(RecordingLimit(seconds: 60) < RecordingLimit(seconds: 61))
        #expect(RecordingLimit(seconds: 3600) == RecordingLimit(seconds: 3600))
        #expect(RecordingLimit.maximum > RecordingLimit(seconds: 3600))
    }

    /// The backstop in the menu is `min(configured, maximum)`, so the cap has to
    /// be at least as long as the longest thing anyone can pick.
    @Test("the cap is not shorter than the shortest pickable limit")
    func capIsSane() {
        #expect(RecordingLimit.maximum.seconds > RecordingLimit.shortestPickable)
        #expect(RecordingLimit.warningLead > 0)
        #expect(RecordingLimit.warningLead < RecordingLimit.maximum.seconds)
    }
}
