import Foundation

/// Finds session folders under the recordings root, wherever they sit.
///
/// Sessions used to be the root's direct children, named by timestamp, so a
/// listing plus a name sort was the whole scan. The naming prompt puts
/// training recordings four levels down (`sopRoot/drafts/Role-Objective/
/// Step-Description.date`) and names quick ones by their description, so
/// neither assumption holds: this walks a bounded tree instead and orders by
/// creation date.
enum SessionScan {
    /// Whether a folder holds a session: it stopped cleanly (meta.json) or
    /// still has media on disk. No meta.json means the process died before it
    /// could stop; the audio is still good, since CAF needs no finalization
    /// pass, so it counts and gets recovered rather than orphaned. Video
    /// counts too: a video-only recording has no .caf at all.
    static func isSession(_ dir: URL, fileManager fm: FileManager = .default) -> Bool {
        let markers = [SessionFiles.meta, SessionFiles.mic, SessionFiles.system]
        if markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            return true
        }
        return SessionFiles.video(in: dir) != nil
    }

    /// Every session folder at most `maxDepth` levels below `root`, oldest
    /// first by creation date (name breaks ties). A session folder is never
    /// descended into: anything inside it (a screenshots subfolder, say) is
    /// the session's own business. Hidden entries and symlinks are skipped.
    ///
    /// The default depth is exactly what the training shape needs and no
    /// more, so a `recordings_dir` pointed at something large stays cheap.
    static func sessionFolders(
        under root: URL,
        maxDepth: Int = 4,
        fileManager fm: FileManager = .default
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        var found: [(url: URL, created: Date)] = []
        var stack: [(url: URL, depth: Int)] = [(root, 0)]

        while let next = stack.popLast() {
            let (dir, depth) = next
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                  )
            else { continue }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                let child = entry.standardizedFileURL
                if isSession(child, fileManager: fm) {
                    found.append((child, values.creationDate ?? .distantPast))
                } else {
                    stack.append((child, depth + 1))
                }
            }
        }

        return found
            .sorted {
                $0.created != $1.created
                    ? $0.created < $1.created
                    : $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            .map(\.url)
    }
}
