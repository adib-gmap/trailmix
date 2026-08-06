import AVFoundation
import CoreGraphics
import Foundation

/// Why the permission rows below carry a caveat.
///
/// macOS attributes a TCC query to the *responsible* process, and for anything
/// spawned from a shell that is the terminal, not the binary. Measured on
/// 2026-08-06 with the same build, minutes apart, and it was wrong in both
/// directions at once:
///
///     doctor, from a terminal:  microphone granted, screen recording not
///     the app, opened by Finder: microphone not granted, screen recording yes
///
/// The terminal had a microphone grant and Trailmix did not; Trailmix had a
/// screen recording grant and the terminal did not. Neither row described the
/// app. `make doctor` is still the right tool for the recordings folder and the
/// model cache, which are plain filesystem questions.
let permissionAttributionNote = """
note: the two permission rows describe whichever process asked. Run from a \
terminal that is the terminal, not Trailmix. For Trailmix's own grants use \
the menu bar → Permissions.
"""

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkScreenRecording(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
        ]
    }

    /// Shares `Permissions.status` with the menu so the two can't disagree
    /// about what is granted. They can still disagree about *whose* grant they
    /// are reading: run from a terminal, this reports whatever the terminal is
    /// entitled to, because macOS attributes a TCC query to the responsible
    /// process. The menu's Permissions submenu is the one that runs inside the
    /// app LaunchServices started.
    static func checkMicrophone() -> Check {
        switch Permissions.status(of: .microphone) {
        case .granted:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notGranted:
            return Check(
                name: "microphone",
                status: .warn("not yet requested, will prompt on first recording"),
                remediation: "menu bar → Permissions → Microphone, or start a recording"
            )
        case .denied:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for Trailmix"
            )
        }
    }

    /// Every capture path needs this now, audio included: SCStream always
    /// requires a content filter, so even audio-only recording attaches to a
    /// display. CGPreflightScreenCaptureAccess reports the grant without
    /// prompting, which the old Core Audio tap had no equivalent for.
    ///
    /// Warns rather than fails when ungranted: macOS prompts on first
    /// recording, so an ungranted permission at startup is normal, not broken.
    /// (This also used to keep the old LaunchAgent out of a respawn loop; the
    /// agent is gone, but the reasoning stands on its own.)
    static func checkScreenRecording() -> Check {
        if Permissions.status(of: .screenRecording) == .granted {
            return Check(name: "screen recording", status: .ok, remediation: nil)
        }
        return Check(
            name: "screen recording",
            status: .warn("not granted, will prompt on first recording"),
            remediation: "menu bar → Permissions → Screen Recording, then relaunch Trailmix"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.current.transcriptionEnabled else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        if ParakeetModel.isPresent {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~\(ParakeetModel.approximateSize))"),
            remediation: "menu bar → Download transcription model, or leave it and the first transcription downloads it"
        )
    }

    /// Checks as display lines: a status line each, plus an indented
    /// remediation where there is one.
    static func rendered(_ checks: [Check]) -> [String] {
        var lines: [String] = []
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            lines.append("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                lines.append("    → \(r)")
            }
        }
        return lines
    }

    /// Print to stdout. For the `doctor` subcommand, where the report is the
    /// command's output. The long-running daemon uses `rendered` and writes to
    /// stderr instead. stdout is block-buffered when redirected to a file, so
    /// a daemon that never exits never flushes it.
    static func print(_ checks: [Check]) {
        for line in rendered(checks) {
            Swift.print(line)
        }
    }

    /// Hard-failing checks as short "name: reason" lines, for display somewhere
    /// with no room for remediation text. Warnings are deliberately excluded:
    /// system audio can only ever warn (its TCC state isn't queryable), so
    /// including warnings would mean a permanent complaint in the menu.
    static func failures(_ checks: [Check]) -> [String] {
        checks.compactMap { check in
            guard case .fail(let reason) = check.status else { return nil }
            return "\(check.name): \(reason)"
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
