import Foundation

/// One folder in the SOP library as the naming prompt lists it.
///
/// A class, not a struct: `NSOutlineView` keys its rows on item identity,
/// and a value type would be a fresh item on every data-source call.
final class SOPNode {
    enum Kind {
        /// The library root (`OCR R&M-Role.Object.Step.Descrip.Date`).
        case sopRoot
        /// The drafts folder (`Need To build SOP`), where new recordings land.
        case drafts
        /// A `Role-Objective` process folder, finalized or draft.
        case roleObjective
        /// A `Step-Description.M.D.YY` session folder.
        case session
        /// Anything else someone put in the tree (notes, screenshots).
        case other
    }

    let url: URL
    let name: String
    let kind: Kind
    let children: [SOPNode]

    init(url: URL, kind: Kind, children: [SOPNode] = []) {
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.children = children
    }
}

/// Reads the SOP library off disk for the prompt's side column and its
/// combo boxes. Directories only, three levels below the library root,
/// which is as deep as the convention goes; hidden folders are skipped.
enum SOPTree {
    /// The library under `root`, or nil when it doesn't exist yet (the first
    /// training recording creates it).
    static func read(root: URL, layout: SessionNaming.Layout) -> SOPNode? {
        let layout = layout.effective
        let libraryURL = root.appendingPathComponent(layout.sopRoot, isDirectory: true)
        guard isDirectory(libraryURL) else { return nil }

        var children: [SOPNode] = []
        for url in subdirectories(of: libraryURL) {
            if url.lastPathComponent == layout.drafts {
                children.append(SOPNode(url: url, kind: .drafts, children: processes(in: url)))
            } else {
                children.append(process(at: url))
            }
        }
        // Drafts first: that is where the recording about to start will go.
        children.sort { a, b in
            if a.kind != b.kind { return a.kind == .drafts }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return SOPNode(url: libraryURL, kind: .sopRoot, children: children)
    }

    /// Distinct roles across the whole library, finalized and draft, sorted.
    static func roles(in library: SOPNode) -> [String] {
        distinct(processes(in: library).map { SessionNaming.parseRoleObjective($0.name).role })
    }

    /// Distinct objectives, narrowed to one role when `role` matches a folder
    /// (case-insensitively); every objective otherwise, so a typo in the role
    /// box doesn't empty the objective list.
    static func objectives(in library: SOPNode, forRole role: String?) -> [String] {
        let pairs = processes(in: library).map { SessionNaming.parseRoleObjective($0.name) }
        let wanted = role?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
        let matching = pairs.filter { $0.role.caseInsensitiveCompare(wanted) == .orderedSame }
        return distinct((matching.isEmpty ? pairs : matching).map(\.objective))
    }

    // MARK: - Private

    private static func processes(in url: URL) -> [SOPNode] {
        subdirectories(of: url).map(process(at:))
    }

    /// Every `Role-Objective` node in the library, at either level.
    private static func processes(in library: SOPNode) -> [SOPNode] {
        library.children.flatMap { node -> [SOPNode] in
            switch node.kind {
            case .drafts: return node.children
            case .roleObjective: return [node]
            default: return []
            }
        }
    }

    private static func process(at url: URL) -> SOPNode {
        let children = subdirectories(of: url).map { child in
            SOPNode(
                url: child,
                kind: SessionNaming.parseSession(child.lastPathComponent) == nil ? .other : .session
            )
        }
        return SOPNode(url: url, kind: .roleObjective, children: children)
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
