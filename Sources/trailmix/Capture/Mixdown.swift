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
        case verificationFailed

        var description: String {
            switch self {
            case .noTracks: return "no audio tracks to mix"
            case .exportUnavailable: return "the system offers no m4a export preset"
            case .exportFailed(let e): return "export failed\(e.map { ": \($0)" } ?? "")"
            case .verificationFailed: return "the exported mix didn't come back readable"
            }
        }
    }

    /// Build `mixed.m4a` for a session and record it in meta.json.
    ///
    /// Offsets come from meta.json's `start_offset_ms`, so the tracks line up
    /// the same way the transcript does. The mic and system streams do not
    /// begin on the same buffer and a naive concatenation at zero would drift
    /// them apart by a couple of hundred milliseconds.
    ///
    /// `mixed.m4a` is also the marker that says the mix is done, so what this
    /// does with an existing one decides whether a session can ever be
    /// repaired. Existence alone is not enough to go on: a process killed
    /// mid-export leaves bytes at that name too. meta.json records the mix only
    /// after the export returned and the result read back, which makes a
    /// recorded mix free to trust; an unrecorded one is either from a build
    /// that predates the record or the debris of an interrupted export, and is
    /// read back before it is believed. Anything unreadable is thrown away and
    /// built again, because nothing else in the pipeline ever will.
    static func run(in dir: URL) async {
        let existing = dir.appendingPathComponent(SessionFiles.mixedAudio)
        if FileManager.default.fileExists(atPath: existing.path) {
            if recordedMix(in: dir) { return }
            if await isPlayable(existing) {
                record(SessionFiles.mixedAudio, in: dir)
                return
            }
            Log.warn(
                "\(dir.lastPathComponent): \(SessionFiles.mixedAudio) isn't readable, rebuilding it"
            )
            try? FileManager.default.removeItem(at: existing)
        }

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
            guard let source = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }

            // Checked before a composition track is added rather than after, so
            // a failed capture leaves nothing behind in the composition. An
            // empty track is the signature of one; inserting it would only
            // widen the file with silence.
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else {
                Log.warn("\(dir.lastPathComponent): \(name) is empty, leaving it out of the mix")
                continue
            }

            guard let target = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

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

        // Exported beside the destination and moved onto it only once it reads
        // back, the same verify-then-replace `Remux` does and for the same
        // reason. Exporting straight onto `mixed.m4a` means a process killed
        // mid-export leaves a partial file wearing the name that marks the mix
        // finished, and `run` above would skip it on every later launch.
        let output = dir.appendingPathComponent(SessionFiles.mixedAudio)
        let temp = dir.appendingPathComponent(SessionFiles.mixTemp)
        try? FileManager.default.removeItem(at: temp)
        do {
            try await export.export(to: temp, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw MixError.exportFailed(error)
        }
        guard await isPlayable(temp) else {
            try? FileManager.default.removeItem(at: temp)
            throw MixError.verificationFailed
        }
        // replaceItemAt needs something to replace; a first mix has nothing.
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
    }

    /// Whether a file is a finished mix rather than the remains of an
    /// interrupted export: an audio track, and a duration to go with it.
    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
            let duration = try? await asset.load(.duration), duration.seconds > 0
        else { return false }
        return true
    }

    /// Whether meta.json records a finished mix under the name this session
    /// actually has on disk. Matched rather than merely present, since a
    /// receipt for some other filename is not a receipt for this file.
    private static func recordedMix(in dir: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { return false }
        return files["mixed"] == SessionFiles.mixedAudio
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
    /// so this is a patch rather than part of the original write. Keeping the
    /// menu's "finishing…" window short is worth the extra read.
    ///
    /// Failure is logged rather than swallowed. It is recoverable (the file is
    /// there, and the next launch reads it back and records it again), but a
    /// silent one leaves meta.json describing a session that has a mix as one
    /// that doesn't, which is exactly the kind of quiet disagreement between
    /// disk and metadata this pipeline keeps having to repair.
    private static func record(_ name: String, in dir: URL) {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard
            let data = try? Data(contentsOf: url),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Log.warn("\(dir.lastPathComponent): can't record \(name) in \(SessionFiles.meta): unreadable")
            return
        }

        var files = json["files"] as? [String: String] ?? [:]
        files["mixed"] = name
        json["files"] = files

        do {
            let updated = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try updated.write(to: url, options: .atomic)
        } catch {
            Log.warn("\(dir.lastPathComponent): can't record \(name) in \(SessionFiles.meta): \(error)")
        }
    }
}
