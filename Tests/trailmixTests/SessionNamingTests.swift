import Foundation
import Testing

@testable import trailmix

/// The folder names the start prompt produces. Every string here is one a
/// person will read in Finder and in the SOP library, so they are pinned
/// exactly: a date with a zero in it or a dash in the wrong place is a
/// recording filed under the wrong name, found only when someone goes
/// looking for it.
private let utcZone = TimeZone(identifier: "UTC")!

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("SessionNaming")
struct SessionNamingTests {

    private static let utc = utcZone
    private static let nov2 = date(2026, 11, 2, 14, 32)
    private static let layout = SessionNaming.Layout.default

    // MARK: - Dates

    @Test("the short date has no zero padding",
          arguments: [
              (date(2026, 11, 2), "11.2.26"),
              (date(2026, 1, 9), "1.9.26"),
              (date(2026, 12, 25), "12.25.26"),
              (date(2030, 10, 10), "10.10.30"),
          ])
    func shortDate(date: Date, expected: String) {
        #expect(SessionNaming.shortDate(date, timeZone: Self.utc) == expected)
    }

    @Test("the timestamp is the name sessions always had")
    func timestamp() {
        #expect(SessionNaming.timestamp(Self.nov2, timeZone: Self.utc) == "2026.11.02-1432")
        #expect(SessionNaming.timestampFolder(at: Self.nov2, timeZone: Self.utc).components == ["2026.11.02-1432"])
    }

    // MARK: - Sanitizing

    @Test("typed text becomes one safe path component",
          arguments: [
              ("  a  b ", "a b"),
              ("a/b:c", "abc"),
              ("\tx\n", "x"),
              ("a\u{0}b", "ab"),
              (".hidden", "hidden"),
              ("...", ""),
              ("   ", ""),
              ("Precon meeting", "Precon meeting"),
              ("R&M / Repair", "R&M Repair"),
          ])
    func sanitize(input: String, expected: String) {
        #expect(SessionNaming.sanitize(input) == expected)
    }

    // MARK: - Quick recordings

    @Test("a quick recording is the description and the date, under the root")
    func quickFolder() {
        let folder = SessionNaming.folder(
            for: .quick(description: "Precon meeting"), layout: Self.layout, date: Self.nov2, timeZone: Self.utc
        )
        #expect(folder?.components == ["Precon meeting 11.2.26"])
        #expect(folder?.leaf == "Precon meeting 11.2.26")
    }

    @Test("an empty quick description means no name (the caller uses the timestamp)",
          arguments: ["", "   ", "/", ":::"])
    func quickEmpty(description: String) {
        #expect(SessionNaming.folder(for: .quick(description: description), layout: Self.layout, date: Self.nov2) == nil)
    }

    @Test("a quick description is sanitized")
    func quickSanitized() {
        let folder = SessionNaming.folder(
            for: .quick(description: " a/b : c "), layout: Self.layout, date: Self.nov2, timeZone: Self.utc
        )
        #expect(folder?.components == ["ab c 11.2.26"])
    }

    // MARK: - Training recordings

    @Test("a training recording is filed in the drafts folder by Role-Objective and Step-Description.date")
    func trainingFolder() {
        let folder = SessionNaming.folder(
            for: .training(role: "Precon", objective: "Material list", step: "Intake", description: "pt1"),
            layout: Self.layout, date: Self.nov2, timeZone: Self.utc
        )
        #expect(folder?.components == [
            "OCR R&M-Role.Object.Step.Descrip.Date",
            "Need To build SOP",
            "Precon-Material list",
            "Intake-pt1.11.2.26",
        ])
        #expect(folder?.relativePath == "OCR R&M-Role.Object.Step.Descrip.Date/Need To build SOP/Precon-Material list/Intake-pt1.11.2.26")
    }

    @Test("step or description alone still names the leaf",
          arguments: [("Intake", "", "Intake.11.2.26"), ("", "pt1", "pt1.11.2.26")])
    func trainingPartialLeaf(step: String, description: String, leaf: String) {
        let folder = SessionNaming.folder(
            for: .training(role: "Precon", objective: "Material list", step: step, description: description),
            layout: Self.layout, date: Self.nov2, timeZone: Self.utc
        )
        #expect(folder?.leaf == leaf)
    }

    @Test("a training recording needs a role, an objective, and a step or description",
          arguments: [
              ("", "Material list", "Intake", "pt1"),
              ("Precon", "", "Intake", "pt1"),
              ("Precon", "Material list", "", ""),
              ("  ", "Material list", "Intake", "pt1"),
          ])
    func trainingIncomplete(role: String, objective: String, step: String, description: String) {
        #expect(SessionNaming.folder(
            for: .training(role: role, objective: objective, step: step, description: description),
            layout: Self.layout, date: Self.nov2
        ) == nil)
    }

    @Test("blank layout names fall back to the defaults so the tree never collapses into the root")
    func layoutFallback() {
        let folder = SessionNaming.folder(
            for: .training(role: "R", objective: "O", step: "S", description: ""),
            layout: SessionNaming.Layout(sopRoot: "  ", drafts: ""), date: Self.nov2, timeZone: Self.utc
        )
        #expect(folder?.components.prefix(2) == ["OCR R&M-Role.Object.Step.Descrip.Date", "Need To build SOP"])

        let custom = SessionNaming.folder(
            for: .training(role: "R", objective: "O", step: "S", description: ""),
            layout: SessionNaming.Layout(sopRoot: "SOPs", drafts: "Drafts"), date: Self.nov2, timeZone: Self.utc
        )
        #expect(custom?.components == ["SOPs", "Drafts", "R-O", "S.11.2.26"])
    }

    @Test("a folder resolves under a root with every intermediate component")
    func folderURL() {
        let root = URL(fileURLWithPath: "/tmp/rec", isDirectory: true)
        let folder = SessionNaming.Folder(components: ["a", "b c", "d"])
        #expect(folder.url(under: root).path == "/tmp/rec/a/b c/d")
    }

    // MARK: - Collisions

    @Test("a taken name gets -2, then -3")
    func uniqueDirectory() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let fm = FileManager.default
            #expect(SessionNaming.uniqueDirectory(parent: root, base: "Intake.11.2.26").lastPathComponent == "Intake.11.2.26")
            try fm.createDirectory(at: root.appendingPathComponent("Intake.11.2.26"), withIntermediateDirectories: true)
            #expect(SessionNaming.uniqueDirectory(parent: root, base: "Intake.11.2.26").lastPathComponent == "Intake.11.2.26-2")
            try fm.createDirectory(at: root.appendingPathComponent("Intake.11.2.26-2"), withIntermediateDirectories: true)
            #expect(SessionNaming.uniqueDirectory(parent: root, base: "Intake.11.2.26").lastPathComponent == "Intake.11.2.26-3")
            // Nothing was created by asking.
            #expect(!fm.fileExists(atPath: root.appendingPathComponent("Intake.11.2.26-3").path))
        }
    }

    // MARK: - Reading names back

    @Test("Role-Objective splits at the first dash",
          arguments: [
              ("EBOS-Create Material Roof Estimate", "EBOS", "Create Material Roof Estimate"),
              ("EBOS-1ARepair", "EBOS", "1ARepair"),
              ("Precon-Material-list", "Precon", "Material-list"),
              ("Onboarding", "Onboarding", ""),
              ("Precon - Material list", "Precon", "Material list"),
          ])
    func parseRoleObjective(name: String, role: String, objective: String) {
        let parsed = SessionNaming.parseRoleObjective(name)
        #expect(parsed.role == role)
        #expect(parsed.objective == objective)
    }

    @Test("a session name gives back its step, description and date",
          arguments: [
              ("Intake-pt1.10.29.26", "Intake", "pt1", "10.29.26"),
              ("Intake.10.29.26", "Intake", "", "10.29.26"),
              ("Intake-pt1.10.29.26-2", "Intake", "pt1", "10.29.26"),
              ("Bidding Roof By Cost Per Square Foot.9.30.26", "Bidding Roof By Cost Per Square Foot", "", "9.30.26"),
          ])
    func parseSession(name: String, step: String, description: String, date: String) throws {
        let parsed = try #require(SessionNaming.parseSession(name))
        #expect(parsed.step == step)
        #expect(parsed.description == description)
        #expect(parsed.date == date)
    }

    @Test("a name without a trailing M.D.YY is not a session",
          arguments: ["screenshots", "2026.10.28-1745", "Precon meeting 11.2.26", ".11.2.26", "notes.2026"])
    func parseSessionRejects(name: String) {
        #expect(SessionNaming.parseSession(name) == nil)
    }
}
