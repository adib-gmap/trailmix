import Foundation
import Testing

@testable import trailmix

/// The arithmetic behind the elapsed counter, the recording limit and
/// `duration_seconds` once a recording can be paused. Three readers of one
/// number; this is where it is decided.
@Suite("PauseLedger")
struct PauseLedgerTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("with no pauses, recorded time is wall-clock time")
    func noPauses() {
        let ledger = PauseLedger()
        #expect(!ledger.isPaused)
        #expect(ledger.count == 0)
        #expect(ledger.pausedTotal(at: at(30)) == 0)
        #expect(ledger.recorded(since: t0, at: at(30)) == 30)
    }

    @Test("a finished pause is subtracted")
    func onePause() {
        var ledger = PauseLedger()
        ledger.pause(at: at(10))
        #expect(ledger.isPaused)
        ledger.resume(at: at(18))
        #expect(!ledger.isPaused)
        #expect(ledger.count == 1)
        #expect(ledger.pausedTotal(at: at(30)) == 8)
        #expect(ledger.recorded(since: t0, at: at(30)) == 22)
    }

    @Test("an open pause counts up to the moment asked about")
    func openPause() {
        var ledger = PauseLedger()
        ledger.pause(at: at(10))
        #expect(ledger.count == 1)
        #expect(ledger.pausedTotal(at: at(15)) == 5)
        #expect(ledger.recorded(since: t0, at: at(15)) == 10, "the counter stands still while paused")
        #expect(ledger.recorded(since: t0, at: at(25)) == 10)
    }

    @Test("several pauses add up")
    func severalPauses() {
        var ledger = PauseLedger()
        ledger.pause(at: at(10)); ledger.resume(at: at(18))
        ledger.pause(at: at(25)); ledger.resume(at: at(30))
        ledger.pause(at: at(40))
        #expect(ledger.count == 3)
        #expect(ledger.pausedTotal(at: at(43)) == 16)
        #expect(ledger.recorded(since: t0, at: at(43)) == 27)
    }

    @Test("a second pause or resume in a row is ignored")
    func doubleCallsAreNoOps() {
        var ledger = PauseLedger()
        ledger.resume(at: at(5))
        #expect(!ledger.isPaused)
        #expect(ledger.count == 0)
        ledger.pause(at: at(10))
        ledger.pause(at: at(12))
        ledger.resume(at: at(20))
        ledger.resume(at: at(22))
        #expect(ledger.count == 1)
        #expect(ledger.pausedTotal(at: at(30)) == 10, "the first pause call is the one that counts")
    }

    @Test("a clock that went backwards can't produce a negative pause")
    func clockSkew() {
        var ledger = PauseLedger()
        ledger.pause(at: at(10))
        ledger.resume(at: at(8))
        #expect(ledger.pausedTotal(at: at(30)) == 0)
        ledger.pause(at: at(20))
        #expect(ledger.pausedTotal(at: at(19)) == 0)
        #expect(ledger.recorded(since: at(40), at: at(30)) == 0)
    }
}
