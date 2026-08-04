import AVFoundation
import Foundation

/// Combines a session's separate audio tracks into one file anyone can play.
///
/// The `.caf` tracks exist to be transcribed, not listened to: two files, one
/// per source, in a container Finder will preview but few things outside macOS
/// will open. `mixed.m4a` is the one to send someone. It is produced whether or
/// not video was captured, so an audio-only session isn't stuck with a pair of
/// half-conversations.
///
/// m4a rather than wav or mp3. wav would be about 600 MB an hour, which is not
/// a file anyone emails; AVFoundation cannot encode mp3 at all. AAC-in-m4a
/// double-clicks on macOS and Windows alike and lands around 30 MB an hour.
enum Mixdown {
    enum MixError: Error, CustomStringConvertible {
        case noTracks
        case exportUnavailable
        case exportFailed(Error?)

        var description: String {
            switch self {
            case .noTracks: return "no audio tracks to mix"
            case .exportUnavailable: return "the system offers no m4a export preset"
            case .exportFailed(let e): return "export failed\(e.map { ": \($0)" } ?? "")"
            }
        }
    }

    /// Build `mixed.m4a` for a session and record it in meta.json.
    ///
    /// Offsets come from meta.json's `start_offset_ms`, so the tracks line up
    /// the same way the transcript does — the mic and system streams do not
    /// begin on the same buffer and a naive concatenation at zero would drift
    /// them apart by a couple of hundred milliseconds.
    static func run(in dir: URL) async {
        let existing = dir.appendingPathComponent(SessionFiles.mixedAudio)
        guard !FileManager.default.fileExists(atPath: existing.path) else { return }

        do {
            try await write(in: dir)
            record(SessionFiles.mixedAudio, in: dir)
            Log.info("\(dir.lastPathComponent): wrote \(SessionFiles.mixedAudio)")
        } catch MixError.noTracks {
            // Video-only session. Nothing wrong, nothing to do.
        } catch {
            Log.warn("\(dir.lastPathComponent): can't mix audio: \(error)")
        }
    }

    private static func write(in dir: URL) async throws {
        let offsets = startOffsets(in: dir)
        let composition = AVMutableComposition()
        var added = 0

        // One composition track per source. Exporting a multi-track
        // composition to a single-track format is what performs the mix.
        for (key, name) in [("mic", SessionFiles.mic), ("system", SessionFiles.system)] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let asset = AVURLAsset(url: url)
            guard
                let source = try await asset.loadTracks(withMediaType: .audio).first,
                let target = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else { continue }

            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else {
                // An empty track is the signature of a capture that failed;
                // inserting it would only widen the file with silence.
                Log.warn("\(dir.lastPathComponent): \(name) is empty — leaving it out of the mix")
                continue
            }

            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: CMTime(value: CMTimeValue(offsets[key] ?? 0), timescale: 1000)
            )
            added += 1
        }
        guard added > 0 else { throw MixError.noTracks }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw MixError.exportUnavailable }

        let output = dir.appendingPathComponent(SessionFiles.mixedAudio)
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            throw MixError.exportFailed(error)
        }
    }

    private static func startOffsets(in dir: URL) -> [String: Int] {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offsets = json["start_offset_ms"] as? [String: Int]
        else { return [:] }
        return offsets
    }

    /// Add the mix to meta.json's `files`, preserving everything else. The mix
    /// is built after the session has already stopped and written its metadata,
    /// so this is a patch rather than part of the original write — keeping the
    /// menu's "finishing…" window short is worth the extra read.
    private static func record(_ name: String, in dir: URL) {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard
            let data = try? Data(contentsOf: url),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var files = json["files"] as? [String: String] ?? [:]
        files["mixed"] = name
        json["files"] = files

        guard let updated = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? updated.write(to: url, options: .atomic)
    }
}
