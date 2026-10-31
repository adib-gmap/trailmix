import Foundation

/// Wall-clock bookkeeping for a recording that can be paused.
///
/// A recording's *recorded* length is its wall-clock length minus every pause,
/// and three things read that number: the elapsed counter in the menu, the
/// user's "stop after" limit (which means recorded length, not time since the
/// click), and `duration_seconds` in meta.json. One place does the arithmetic
/// so the three can't disagree.
///
/// Pure, like `RecordingLimit`: no AppKit, no clock of its own. Every call
/// takes the moment it applies to, which is what makes it testable without
/// waiting and what lets a stop that lands mid-pause count that pause up to
/// the stop and no further.
///
/// The stream-clock side of a pause (where in the *video file* it falls) is
/// kept by `CaptureStream`, which is the only thing that sees the stream's
/// timestamps. This is the wall-clock side.
struct PauseLedger: Sendable {
    private var finished: [(start: Date, end: Date)] = []
    private var current: Date?

    init() {}

    var isPaused: Bool { current != nil }

    /// Pauses so far, including one still open.
    var count: Int { finished.count + (current == nil ? 0 : 1) }

    /// Begin a pause. A second pause while one is open is ignored rather than
    /// restarting it, since restarting would quietly shorten the gap.
    mutating func pause(at now: Date) {
        guard current == nil else { return }
        current = now
    }

    /// End the open pause. Ignored when nothing is paused.
    mutating func resume(at now: Date) {
        guard let start = current else { return }
        finished.append((start, max(start, now)))
        current = nil
    }

    /// Seconds spent paused up to `now`, an open pause included.
    func pausedTotal(at now: Date) -> TimeInterval {
        var total = finished.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        if let current {
            total += max(0, now.timeIntervalSince(current))
        }
        return total
    }

    /// Seconds actually recorded between `start` and `now`: wall clock minus
    /// the pauses. Never negative.
    func recorded(since start: Date, at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(start) - pausedTotal(at: now))
    }
}
