import AVFoundation
import CoreMedia
import Foundation

/// Replaces the video's audio track with the mixed one, and cuts out whatever
/// was recorded while the session was paused.
///
/// With echo cancellation on, the mic is no longer part of the SCStream, so
/// SCRecordingOutput muxes system audio and nothing else: a screen recording
/// of a call where you can't hear yourself. This puts the full mix back, which
/// also means the video ends up with the echo-cancelled mic rather than the
/// raw one it used to get. It is what makes `mixed.mp4` deserve the name.
///
/// A pause does not stop the stream, so the raw video still holds the paused
/// stretches while the audio tracks (which dropped their buffers) do not.
/// meta.json's `paused_ms` says where those stretches fall, in the video's own
/// time; the kept ranges either side are laid back to back and the gapless mix
/// is read straight across them, which puts the two on one clock again.
///
/// Either way this is a passthrough export: the video is copied
/// stream-for-stream, never re-encoded, so it costs a container rewrite rather
/// than a transcode and nothing is lost. A cut that lands between keyframes
/// comes out as one edit-list entry per kept range, each starting mid-GOP
/// with the frames from the previous keyframe carried along for the decoder
/// to discard. QuickTime and AVFoundation honour that, and so do ffmpeg and
/// Chrome (whose file playback demuxes through ffmpeg); verified 2026-10-30
/// on a mid-GOP cut with an on-screen clock. (Asking for the HEVC
/// highest-quality preset instead changes nothing: the exporter still passes
/// the samples through when they already fit the preset, byte-identical
/// parameter sets and all, so there is no re-encode to buy anything with.)
///
/// The original is replaced only after the new file is written and verified,
/// and `replaceItemAt` makes the swap atomic, so an interrupted remux leaves
/// the original video exactly as it was.
enum Remux {
    enum RemuxError: Error, CustomStringConvertible {
        case noVideoTrack
        case noAudioTrack
        case audioEndsBeforeVideo
        case nothingKept
        case exportUnavailable
        case verificationFailed
        case metaUnreadable

        var description: String {
            switch self {
            case .metaUnreadable: return "can't read \(SessionFiles.meta) to record the swap"
            case .noVideoTrack: return "the recording has no video track"
            case .noAudioTrack: return "the mix has no audio track to swap in"
            case .audioEndsBeforeVideo: return "the mix ends before the video starts"
            case .nothingKept: return "every frame of the video falls inside a pause"
            case .exportUnavailable: return "the system offers no suitable export preset"
            case .verificationFailed: return "the remuxed file didn't come back readable"
            }
        }
    }

    /// Whether the video already carries the mix.
    ///
    /// Recorded in meta.json rather than inferred from the file, because a
    /// video that came off the stream with system audio already has an audio
    /// track and looks identical from outside. The marker is what lets a
    /// session interrupted between the mixdown and the swap be repaired on the
    /// next launch without re-swapping every session that is already done.
    static func alreadySwapped(in dir: URL) -> Bool {
        marker("mixed_audio_in_video", in: dir)
    }

    /// Whether the paused stretches have been cut out of the video. Set by
    /// both paths below, since the swap cuts them in the same export.
    static func pausesRemoved(in dir: URL) -> Bool {
        marker("pauses_removed", in: dir)
    }

    private static func marker(_ key: String, in dir: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json[key] as? Bool ?? false
    }

    /// Everything the video needs after a stop, each step guarded by its own
    /// marker so it can be reached again from recovery: the mix swapped in
    /// (which also cuts the pauses), or, for a session with no mix to swap, the
    /// pauses cut on their own. A video with neither to do is left alone.
    static func finalize(in dir: URL) async {
        guard SessionFiles.video(in: dir) != nil else { return }
        let mixed = dir.appendingPathComponent(SessionFiles.mixedAudio)
        if FileManager.default.fileExists(atPath: mixed.path) {
            guard !alreadySwapped(in: dir) else { return }
            await mixedAudioIntoVideo(in: dir)
        } else {
            guard !pausedRanges(in: dir).isEmpty, !pausesRemoved(in: dir) else { return }
            await removePauses(in: dir)
        }
    }

    static func mixedAudioIntoVideo(in dir: URL) async {
        let audio = dir.appendingPathComponent(SessionFiles.mixedAudio)
        guard
            let video = SessionFiles.video(in: dir),
            FileManager.default.fileExists(atPath: audio.path)
        else { return }

        let pauses = pausedRanges(in: dir)
        do {
            try await swap(
                video: video, audio: audio, videoOffsetMs: videoOffsetMs(in: dir), pauses: pauses
            )
        } catch {
            // The original is untouched on every failure path, so this
            // degrades to "video has system audio only" rather than losing it.
            // Unmarked, so the next launch tries again.
            Log.warn("\(dir.lastPathComponent): can't remux \(video.lastPathComponent): \(error)")
            return
        }

        // Reported separately from the swap, because the two fail differently.
        // The marker is what stops the next launch remuxing this video again,
        // so a swap whose marker didn't land is a real state, not a footnote:
        // the audio is in the file and the session still looks unfinished.
        // Claiming plain success there would be a lie in the one log anybody
        // reads when a session comes out wrong. Redoing the swap is wasteful
        // rather than harmful, since it replaces the video's audio with the
        // same mix.
        do {
            try recordSwap(in: dir, pausesRemoved: !pauses.isEmpty)
            Log.info(
                "\(dir.lastPathComponent): \(video.lastPathComponent) now carries the mixed audio"
                    + (pauses.isEmpty ? "" : " with \(pauses.count) pause(s) cut out")
            )
        } catch {
            Log.warn(
                "\(dir.lastPathComponent): \(video.lastPathComponent) carries the mixed audio, "
                    + "but \(SessionFiles.meta) didn't record it: \(error). it will be remuxed again"
            )
        }
    }

    /// Cut the pauses out of a video that has no mix to swap in: a video-only
    /// session, or one whose mixdown failed. The file's own audio track, if the
    /// stream muxed one in, is cut the same way so it stays in step.
    static func removePauses(in dir: URL) async {
        guard let video = SessionFiles.video(in: dir) else { return }
        let pauses = pausedRanges(in: dir)
        guard !pauses.isEmpty else { return }

        do {
            try await cut(video: video, pauses: pauses)
        } catch {
            Log.warn("\(dir.lastPathComponent): can't cut pauses from \(video.lastPathComponent): \(error)")
            return
        }
        do {
            try patchMeta(in: dir) { $0["pauses_removed"] = true }
            Log.info("\(dir.lastPathComponent): \(pauses.count) pause(s) cut out of \(video.lastPathComponent)")
        } catch {
            Log.warn(
                "\(dir.lastPathComponent): pauses were cut out of \(video.lastPathComponent), "
                    + "but \(SessionFiles.meta) didn't record it: \(error). it will be cut again"
            )
        }
    }

    /// How far the video track started after the earliest track in the session,
    /// which is the same zero point `mixed.m4a` was built around.
    ///
    /// Zero for a session recorded before offsets were captured, for one
    /// recovered after a hard kill, and for any session where the video really
    /// did come first, which is the common case.
    static func videoOffsetMs(in dir: URL) -> Int {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offsets = json["start_offset_ms"] as? [String: Int],
            let offset = offsets["video"]
        else { return 0 }
        return max(0, offset)
    }

    /// The paused stretches, in the video file's time, from `paused_ms`.
    /// Absent (every session recorded before pausing existed) means none. An
    /// end of -1 is a pause the recording was stopped in: it runs to the end
    /// of the file, however far the recorder wrote past the last sample the
    /// stream saw. Anything malformed is dropped rather than guessed at.
    static func pausedRanges(in dir: URL) -> [CMTimeRange] {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pairs = json["paused_ms"] as? [[Int]]
        else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, pair[0] >= 0, pair[1] > pair[0] || pair[1] == -1 else { return nil }
            return CMTimeRange(
                start: CMTime(value: CMTimeValue(pair[0]), timescale: 1000),
                end: pair[1] == -1 ? .positiveInfinity : CMTime(value: CMTimeValue(pair[1]), timescale: 1000)
            )
        }
    }

    /// What is left of `[0, duration]` once the pauses are taken out, in
    /// order. Pauses are clamped to the video, merged where they overlap, and
    /// a pause that runs to the end simply shortens the last range. Empty when
    /// nothing survives.
    static func kept(_ duration: CMTime, minus pauses: [CMTimeRange]) -> [CMTimeRange] {
        guard duration > .zero else { return [] }
        let whole = CMTimeRange(start: .zero, duration: duration)
        let cuts = pauses
            // An open-ended pause (stopped while paused) reaches the end.
            .map { CMTimeRange(start: $0.start, end: CMTimeMinimum($0.end, duration)) }
            .map { $0.intersection(whole) }
            .filter { $0.duration > .zero }
            .sorted { $0.start < $1.start }

        var merged: [CMTimeRange] = []
        for cut in cuts {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1] = CMTimeRange(
                    start: last.start, end: CMTimeMaximum(last.end, cut.end)
                )
            } else {
                merged.append(cut)
            }
        }

        var result: [CMTimeRange] = []
        var cursor = CMTime.zero
        for cut in merged {
            if cut.start > cursor {
                result.append(CMTimeRange(start: cursor, end: cut.start))
            }
            cursor = cut.end
        }
        if duration > cursor {
            result.append(CMTimeRange(start: cursor, end: duration))
        }
        return result
    }

    // MARK: - Compositions

    private static func swap(
        video: URL, audio: URL, videoOffsetMs: Int, pauses: [CMTimeRange]
    ) async throws {
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: video)
        guard
            let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
            let destVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { throw RemuxError.noVideoTrack }

        let duration = try await videoAsset.load(.duration)
        let keptTotal = try insert(sourceVideo, into: destVideo, duration: duration, pauses: pauses)
        // Carried across explicitly; a composition track doesn't inherit it,
        // and losing it would rotate the video on playback.
        destVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        // Required, not optional. This replaces the video's own audio, so a mix
        // that turns out to have no usable track would swap in silence and
        // throw away the system audio the recording came off the stream with.
        // Failing leaves the original alone instead.
        let audioAsset = AVURLAsset(url: audio)
        guard
            let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let destAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { throw RemuxError.noAudioTrack }

        // mixed.m4a's zero is the *earliest* track of the session, which is
        // not necessarily the video: audio and screen buffers arrive off the
        // same SCStream in whichever order the stream happens to deliver them,
        // and `start_offset_ms` records that per track. So the mix is read from
        // the video's own offset rather than from its start, which is what puts
        // the two on the same clock. Usually the video is first and the offset
        // is zero, making this a no-op; when it isn't, this is the difference
        // between synced audio and audio running early by however long the
        // video took to produce a frame.
        //
        // The mix is gapless (the writers dropped the paused buffers), so it
        // is read straight across the kept video ranges, and clamped to their
        // total so a longer audio tail can't stretch the file past its last
        // frame.
        let audioDuration = try await audioAsset.load(.duration)
        let start = CMTime(value: CMTimeValue(videoOffsetMs), timescale: 1000)
        let available = audioDuration - start
        // A mix that ends before the video's offset would insert nothing at
        // all, which is the same silent swap as a missing track.
        guard available > .zero else { throw RemuxError.audioEndsBeforeVideo }
        try destAudio.insertTimeRange(
            CMTimeRange(start: start, duration: min(available, keptTotal)),
            of: sourceAudio,
            at: .zero
        )

        try await export(composition, replacing: video, requireAudio: true)
    }

    private static func cut(video: URL, pauses: [CMTimeRange]) async throws {
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: video)
        guard
            let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
            let destVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { throw RemuxError.noVideoTrack }

        let duration = try await asset.load(.duration)
        _ = try insert(sourceVideo, into: destVideo, duration: duration, pauses: pauses)
        destVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var hasAudio = false
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
            let destAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        {
            _ = try insert(sourceAudio, into: destAudio, duration: duration, pauses: pauses)
            hasAudio = true
        }

        try await export(composition, replacing: video, requireAudio: hasAudio)
    }

    /// Lay the parts of `source` outside the pauses back to back in `dest`.
    /// Returns the total laid down, which is the output's length.
    private static func insert(
        _ source: AVAssetTrack,
        into dest: AVMutableCompositionTrack,
        duration: CMTime,
        pauses: [CMTimeRange]
    ) throws -> CMTime {
        let ranges = kept(duration, minus: pauses)
        guard !ranges.isEmpty else { throw RemuxError.nothingKept }
        var cursor = CMTime.zero
        for range in ranges {
            try dest.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        return cursor
    }

    /// Export beside the original, read the result back, then swap it in.
    /// Always passthrough; see the type comment for why a cut needs no more.
    private static func export(
        _ composition: AVMutableComposition,
        replacing video: URL,
        requireAudio: Bool
    ) async throws {
        let preset = AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: composition, presetName: preset)
        else { throw RemuxError.exportUnavailable }

        // Written beside the original and exported to whatever container the
        // original uses, so a pre-rename screen.mov is remuxed as a .mov and
        // stays where it is rather than becoming a second file.
        let isMP4 = video.pathExtension.lowercased() == "mp4"
        let temp = video.deletingLastPathComponent()
            .appendingPathComponent("remux.tmp.\(video.pathExtension)")
        try? FileManager.default.removeItem(at: temp)
        try await export.export(to: temp, as: isMP4 ? .mp4 : .mov)

        // Read it back before trusting it with the only copy of the video. Both
        // tracks, not just the video: the whole point of the exercise is the
        // audio, and a passthrough export that dropped it would otherwise
        // replace a video that had system audio with one that has none.
        let check = AVURLAsset(url: temp)
        let hasVideo = try await !check.loadTracks(withMediaType: .video).isEmpty
        let hasAudio = try await !check.loadTracks(withMediaType: .audio).isEmpty
        let seconds = try await check.load(.duration).seconds
        guard hasVideo, hasAudio || !requireAudio, seconds > 0
        else {
            try? FileManager.default.removeItem(at: temp)
            throw RemuxError.verificationFailed
        }

        _ = try FileManager.default.replaceItemAt(video, withItemAt: temp)
    }

    // MARK: - meta.json

    /// Mark the swap done in meta.json, the same read-modify-write patch
    /// `Mixdown` uses to record the mix. Written only after `replaceItemAt`
    /// has returned, so an interruption anywhere before that leaves the session
    /// looking exactly like one that never got here.
    ///
    /// Throws rather than failing quietly. This one write is the difference
    /// between a finished session and one that gets remuxed on every launch
    /// forever, and the caller says so in the log.
    static func recordSwap(in dir: URL, pausesRemoved: Bool = false) throws {
        try patchMeta(in: dir) { json in
            json["mixed_audio_in_video"] = true
            if pausesRemoved { json["pauses_removed"] = true }
        }
    }

    private static func patchMeta(in dir: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        guard
            let data = try? Data(contentsOf: url),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RemuxError.metaUnreadable }

        change(&json)
        let updated = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: url, options: .atomic)
    }
}
