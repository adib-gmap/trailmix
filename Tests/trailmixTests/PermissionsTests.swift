import Foundation
import Testing

@testable import trailmix

/// The permission surface has one pure part worth pinning, the parent row's
/// title, plus a handful of constants that are load-bearing strings: a
/// mistyped System Settings URL fails by opening the wrong pane or none at
/// all, with nothing logged.
///
/// The queries themselves ask macOS about TCC and cannot be tested here, which
/// is the whole reason the submenu exists. See `Permission`.
@Suite("Permissions")
struct PermissionsTests {

    private func status(_ permission: Permission, _ state: PermissionState) -> PermissionStatus {
        PermissionStatus(permission: permission, state: state)
    }

    // MARK: - The parent row

    /// Everything granted is the common case and gets a bare noun. The row
    /// should not nag when there is nothing to do.
    @Test("all granted reads as a plain noun")
    func summaryAllGranted() {
        #expect(Permissions.summary([
            status(.microphone, .granted),
            status(.screenRecording, .granted),
        ]) == "Permissions")
    }

    /// One missing names it outright rather than counting. "1 missing" would
    /// make you hover to learn something that fits in the row.
    @Test("a single missing permission is named, not counted")
    func summaryOneMissing() {
        #expect(Permissions.summary([
            status(.microphone, .granted),
            status(.screenRecording, .notGranted),
        ]) == "Permissions: Screen Recording missing")

        #expect(Permissions.summary([
            status(.microphone, .denied),
            status(.screenRecording, .granted),
        ]) == "Permissions: Microphone missing")
    }

    /// Denied and never-asked both count as missing. The distinction changes
    /// what clicking does, not whether something is wrong.
    @Test("denied counts as missing, the same as never asked")
    func deniedCountsAsMissing() {
        for state in [PermissionState.notGranted, .denied] {
            #expect(Permissions.summary([status(.microphone, state)])
                == "Permissions: Microphone missing")
        }
    }

    @Test("more than one missing falls back to a count")
    func summaryManyMissing() {
        #expect(Permissions.summary([
            status(.microphone, .notGranted),
            status(.screenRecording, .denied),
        ]) == "Permissions: 2 missing")
    }

    /// An empty list must not render as "0 missing".
    @Test("no permissions at all reads as the plain noun")
    func summaryEmpty() {
        #expect(Permissions.summary([]) == "Permissions")
    }

    /// Whatever the state, the row is still recognisably the same row.
    @Test("every summary starts with the row's own name")
    func summaryAlwaysPrefixed() {
        let states: [PermissionState] = [.granted, .notGranted, .denied]
        for mic in states {
            for screen in states {
                let title = Permissions.summary([
                    status(.microphone, mic),
                    status(.screenRecording, screen),
                ])
                #expect(title.hasPrefix("Permissions"))
            }
        }
    }

    // MARK: - What a recording is allowed to need

    private func sources(mic: Bool, audio: Bool = true, target: CaptureTarget = .none)
        -> CaptureStream.Sources
    {
        CaptureStream.Sources(computerAudio: audio, microphone: mic, target: target)
    }

    /// Screen recording is required for everything, audio-only included,
    /// because SCStream demands a content filter whatever you ask it for.
    @Test("screen recording is required whatever the sources")
    func screenRecordingAlwaysRequired() {
        for mic in [true, false] {
            for target in [CaptureTarget.none, .display(1), .window(2)] {
                let required = Permissions.required(for: sources(mic: mic, target: target))
                #expect(required.contains(.screenRecording))
            }
        }
    }

    /// The correction to "block until both are granted". Someone recording
    /// computer audio and a display must not be stopped by a microphone grant
    /// they will never exercise.
    @Test("the microphone is required only when that source is on")
    func microphoneRequiredOnlyWhenEnabled() {
        #expect(Permissions.required(for: sources(mic: true)).contains(.microphone))
        #expect(!Permissions.required(for: sources(mic: false)).contains(.microphone))
        #expect(Permissions.required(for: sources(mic: false)) == [.screenRecording])
    }

    @Test("nothing is required beyond the two")
    func requiredIsBounded() {
        let required = Permissions.required(for: sources(mic: true))
        #expect(Set(required) == Set(Permission.allCases))
        #expect(required.count == 2)
    }

    /// Granted permissions are not blockers, and an ungranted one that is not
    /// required is not a blocker either.
    @Test("only the missing and required block")
    func blockers() {
        let micOffScreenMissing = Permissions.blockers(
            for: sources(mic: false),
            given: [status(.microphone, .denied), status(.screenRecording, .notGranted)]
        )
        #expect(micOffScreenMissing == [.screenRecording],
                "a denied microphone must not block when the source is off")

        #expect(Permissions.blockers(
            for: sources(mic: true),
            given: [status(.microphone, .granted), status(.screenRecording, .granted)]
        ).isEmpty)

        #expect(Permissions.blockers(
            for: sources(mic: true),
            given: [status(.microphone, .notGranted), status(.screenRecording, .granted)]
        ) == [.microphone])
    }

    /// A status list that says nothing about a permission means it is not
    /// granted, so an incomplete read fails closed rather than open.
    @Test("an unknown permission is treated as missing")
    func unknownIsMissing() {
        #expect(Permissions.blockers(for: sources(mic: true), given: []).count == 2)
    }

    /// The microphone leads, because it resolves inline while screen recording
    /// ends in a relaunch. Granting in the other order would drop the second.
    @Test("blockers come back microphone first")
    func blockerOrder() {
        #expect(Permissions.blockers(
            for: sources(mic: true),
            given: []
        ) == [.microphone, .screenRecording])
    }

    // MARK: - What the user is told

    @Test("the idle line names what is missing, and is absent when nothing is")
    func blockedReason() {
        #expect(Permissions.blockedReason([]) == nil)
        #expect(Permissions.blockedReason([.microphone]) == "Needs Microphone")
        #expect(Permissions.blockedReason([.screenRecording]) == "Needs Screen Recording")
        #expect(Permissions.blockedReason([.microphone, .screenRecording])
            == "Needs Microphone and Screen Recording")
    }

    /// The microphone paragraph has to name the way out. Turning that source
    /// off is a legitimate answer, and without saying so the modal is a dead
    /// end for anyone who does not want to grant it.
    @Test("the explanation says why, and how to avoid needing it")
    func explanation() {
        let mic = Permissions.explanation([.microphone])
        #expect(mic.contains("Switch it off"))

        let screen = Permissions.explanation([.screenRecording])
        #expect(screen.contains("audio only"))

        // One paragraph each, not one run-on.
        let both = Permissions.explanation([.microphone, .screenRecording])
        #expect(both.contains("\n\n"))
        #expect(both.contains("Microphone"))
        #expect(both.contains("Screen Recording"))
        #expect(Permissions.explanation([]).isEmpty)
    }

    // MARK: - Constants

    @Test("both permissions are covered and named for what System Settings calls them")
    func titles() {
        #expect(Permission.allCases.count == 2)
        #expect(Permission.microphone.title == "Microphone")
        #expect(Permission.screenRecording.title == "Screen Recording")
        #expect(Set(Permission.allCases.map(\.title)).count == Permission.allCases.count)
    }

    /// The scheme is what makes these open System Settings rather than a
    /// browser, and the query is what picks the pane.
    @Test("settings URLs address the right pane")
    func settingsURLs() {
        for permission in Permission.allCases {
            #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
        }
        #expect(Permission.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(Permission.screenRecording.settingsURL.absoluteString
            .hasSuffix("Privacy_ScreenCapture"))
        #expect(Permissions.privacySettingsURL.scheme == "x-apple.systempreferences")
    }

    /// The asymmetry the relaunch prompt exists for. Getting this backwards
    /// means either a pointless restart or a permission that looks granted and
    /// silently does nothing.
    @Test("only screen recording needs a relaunch")
    func relaunchRequirement() {
        #expect(Permission.microphone.appliesWithoutRelaunch)
        #expect(!Permission.screenRecording.appliesWithoutRelaunch)
    }
}
