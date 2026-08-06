import Foundation
import Testing

@testable import trailmix

/// The doctor report has two consumers with opposite needs, and the split
/// between them is the thing worth pinning.
///
/// `doctor` prints everything and exits non-zero on a hard failure. The daemon
/// takes only `failures` into the menu, because system audio can never do better
/// than warn (its TCC state is not queryable), so a menu fed warnings would carry
/// a permanent complaint. Getting that backwards means either a daemon that
/// refuses to start on a normal first launch, or one that never mentions a denied
/// microphone.
///
/// These functions are pure. The checks themselves ask the system about
/// permissions and cannot be tested here.
@Suite("DoctorReport")
struct DoctorReportTests {

    private let ok = Check(name: "microphone", status: .ok, remediation: nil)
    private let warn = Check(
        name: "screen recording",
        status: .warn("not granted, will prompt on first recording"),
        remediation: "System Settings → Privacy & Security"
    )
    private let fail = Check(
        name: "recordings folder",
        status: .fail("not writable"),
        remediation: "check permissions on the directory"
    )
    private let failNoFix = Check(name: "transcription", status: .fail("broken"), remediation: nil)

    // MARK: - allOK

    /// Warnings do not block. An ungranted permission at startup is the normal
    /// state on a first launch, since macOS prompts on first recording.
    @Test("warnings pass, failures do not")
    func allOK() {
        #expect(DoctorReport.allOK([]))
        #expect(DoctorReport.allOK([ok]))
        #expect(DoctorReport.allOK([ok, warn]))
        #expect(!DoctorReport.allOK([ok, fail]))
        #expect(!DoctorReport.allOK([warn, fail]))
        #expect(!DoctorReport.allOK([fail]))
    }

    // MARK: - failures

    /// Only hard failures reach the menu, and each is a short "name: reason"
    /// with no remediation text, since the menu row has no room for it.
    @Test("only hard failures are surfaced, as name and reason")
    func failures() {
        #expect(DoctorReport.failures([ok, warn]).isEmpty)
        #expect(DoctorReport.failures([ok, warn, fail]) == ["recordings folder: not writable"])
        #expect(DoctorReport.failures([fail, failNoFix]) == [
            "recordings folder: not writable",
            "transcription: broken",
        ])
    }

    @Test("failures preserves the order the checks were run in")
    func failuresKeepsOrder() {
        #expect(DoctorReport.failures([failNoFix, fail]) == [
            "transcription: broken",
            "recordings folder: not writable",
        ])
    }

    /// The two are consistent by construction: something is fine exactly when it
    /// has nothing to report.
    @Test("allOK agrees with failures being empty")
    func allOKAgreesWithFailures() {
        for checks in [[ok], [ok, warn], [ok, fail], [warn, fail], [], [fail, failNoFix]] {
            #expect(DoctorReport.allOK(checks) == DoctorReport.failures(checks).isEmpty)
        }
    }

    // MARK: - rendered

    @Test("each status gets its own mark")
    func renderedMarks() {
        #expect(DoctorReport.rendered([ok]) == ["✓ microphone: ok"])
        #expect(DoctorReport.rendered([failNoFix]) == ["✗ transcription: broken"])
        #expect(DoctorReport.rendered([warn]).first
            == "! screen recording: not granted, will prompt on first recording")
    }

    /// Remediation is a second, indented line rather than part of the status, so
    /// the report scans as one line per check.
    @Test("remediation is an indented second line, and only when there is one")
    func renderedRemediation() {
        let lines = DoctorReport.rendered([warn])
        #expect(lines.count == 2)
        #expect(lines[1] == "    → System Settings → Privacy & Security")

        // No remediation, no second line.
        #expect(DoctorReport.rendered([ok]).count == 1)
        #expect(DoctorReport.rendered([failNoFix]).count == 1)
    }

    @Test("checks render in order, and every one appears")
    func renderedOrder() {
        let lines = DoctorReport.rendered([ok, warn, fail])
        // 1 + 2 + 2: two of the three carry remediation.
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("✓ microphone"))
        #expect(lines[1].hasPrefix("! screen recording"))
        #expect(lines[3].hasPrefix("✗ recordings folder"))
    }

    @Test("an empty report renders nothing rather than a header")
    func renderedEmpty() {
        #expect(DoctorReport.rendered([]).isEmpty)
    }

    /// Every rendered line starts with a mark or the remediation indent, so
    /// nothing can silently render as a bare unprefixed line.
    @Test("every line is either a status or an indented remediation")
    func renderedLinesAreWellFormed() {
        for line in DoctorReport.rendered([ok, warn, fail, failNoFix]) {
            let isStatus = ["✓ ", "! ", "✗ "].contains { line.hasPrefix($0) }
            #expect(isStatus || line.hasPrefix("    → "))
        }
    }
}
