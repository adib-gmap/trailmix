import Foundation

/// How a session folder is named and where it sits under the recordings root.
///
/// The start prompt asks whether the video is for training, and the answer
/// decides between two shapes:
///
///     training:  <sopRoot>/<drafts>/<Role>-<Objective>/<Step>-<Description>.<M.D.YY>
///     quick:     <Description> <M.D.YY>
///
/// plus the old `yyyy.MM.dd-HHmm` timestamp when the prompt is switched off or
/// a quick description is left empty. The training shape is the SOP library's
/// own convention (root folder `OCR R&M-Role.Object.Step.Descrip.Date`, one
/// `Role-Objective` folder per process, one `Step-Descrip.Date` video per
/// step), so a recording lands on disk already named the way it is filed.
/// New training videos always start under the drafts folder; finalizing one
/// is a move by hand.
///
/// Pure: every function takes its date and time zone, so the tests can pin
/// exact strings, and nothing here touches AppKit.
enum SessionNaming {
    /// The two folder names the training shape is built from. They come from
    /// the config (`sop_root`, `sop_drafts`); `effective` substitutes the
    /// defaults for blanks so a half-edited config can never collapse the
    /// tree into the recordings root.
    struct Layout: Sendable, Equatable {
        var sopRoot: String
        var drafts: String

        static let `default` = Layout(
            sopRoot: "OCR R&M-Role.Object.Step.Descrip.Date",
            drafts: "Need To build SOP"
        )

        var effective: Layout {
            let root = SessionNaming.sanitize(sopRoot)
            let drafts = SessionNaming.sanitize(self.drafts)
            return Layout(
                sopRoot: root.isEmpty ? Self.default.sopRoot : root,
                drafts: drafts.isEmpty ? Self.default.drafts : drafts
            )
        }
    }

    /// What the person typed at the prompt. Raw: sanitizing is `folder`'s job.
    enum Request: Sendable, Equatable {
        case quick(description: String)
        case training(role: String, objective: String, step: String, description: String)
    }

    /// Path components below the recordings root; the last one is the session
    /// folder. Never empty.
    struct Folder: Sendable, Equatable {
        let components: [String]

        var leaf: String { components.last ?? "" }
        var relativePath: String { components.joined(separator: "/") }

        /// `components` resolved against a root, intermediate folders and all.
        func url(under root: URL) -> URL {
            components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        }
    }

    // MARK: - Dates

    /// `M.D.YY` with no zero padding, the way the SOP library writes dates:
    /// `11.2.26`, `1.9.26`, `12.25.26`.
    static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("M.d.yy", timeZone).string(from: date)
    }

    /// The timestamp name every session had before the prompt existed. Still
    /// used when the prompt is off or a quick description is left empty.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy.MM.dd-HHmm", timeZone).string(from: date)
    }

    static func timestampFolder(at date: Date, timeZone: TimeZone = .current) -> Folder {
        Folder(components: [timestamp(date, timeZone: timeZone)])
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f
    }

    // MARK: - Text

    /// Make typed text safe as one path component: no `/` or `:` (the two
    /// characters a folder name cannot hold on macOS), no control characters,
    /// no leading dot (Finder would hide the folder), runs of whitespace
    /// collapsed to one space, ends trimmed.
    static func sanitize(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && scalar.properties.generalCategory != .control
        }
        let words = String(String.UnicodeScalarView(cleaned))
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var joined = words.joined(separator: " ")
        while joined.hasPrefix(".") { joined.removeFirst() }
        return joined.trimmingCharacters(in: CharacterSet.whitespaces)
    }

    // MARK: - Folder shapes

    /// The folder a request names, or nil when the request has too little in
    /// it: an empty quick description (the caller falls back to the
    /// timestamp), or a training request without a role, an objective and at
    /// least one of step or description.
    static func folder(
        for request: Request,
        layout: Layout,
        date: Date,
        timeZone: TimeZone = .current
    ) -> Folder? {
        let day = shortDate(date, timeZone: timeZone)
        switch request {
        case .quick(let description):
            let text = sanitize(description)
            guard !text.isEmpty else { return nil }
            return Folder(components: ["\(text) \(day)"])

        case .training(let role, let objective, let step, let description):
            let role = sanitize(role)
            let objective = sanitize(objective)
            let stem = [sanitize(step), sanitize(description)]
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            guard !role.isEmpty, !objective.isEmpty, !stem.isEmpty else { return nil }
            let layout = layout.effective
            return Folder(components: [
                layout.sopRoot,
                layout.drafts,
                "\(role)-\(objective)",
                "\(stem).\(day)",
            ])
        }
    }

    /// `parent/base`, or `parent/base-2`, `-3`, … when that already exists.
    /// Nothing is created; the caller does that, so a cancel between naming
    /// and recording leaves no empty folder behind.
    static func uniqueDirectory(
        parent: URL,
        base: String,
        fileManager: FileManager = .default
    ) -> URL {
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    // MARK: - Reading names back

    /// `EBOS-Create Material Roof Estimate` → `("EBOS", "Create Material Roof
    /// Estimate")`. The split is at the first dash, so a role never holds one.
    /// A name without a dash is all role.
    static func parseRoleObjective(_ name: String) -> (role: String, objective: String) {
        guard let dash = name.firstIndex(of: "-") else { return (name, "") }
        return (
            String(name[..<dash]).trimmingCharacters(in: .whitespaces),
            String(name[name.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// `Intake-pt1.10.29.26` → `("Intake", "pt1", "10.29.26")`; a `-2`
    /// collision suffix is ignored; `Intake.10.29.26` has no description;
    /// a name without a trailing `M.D.YY` is not a session name and returns nil.
    static func parseSession(_ name: String) -> (step: String, description: String, date: String)? {
        let pattern = #/^(.*)\.(\d{1,2}\.\d{1,2}\.\d{2})(?:-\d+)?$/#
        guard let match = name.wholeMatch(of: pattern) else { return nil }
        let stem = String(match.1)
        let date = String(match.2)
        guard !stem.isEmpty else { return nil }
        let (step, description) = parseRoleObjective(stem)
        return (step, description, date)
    }
}
