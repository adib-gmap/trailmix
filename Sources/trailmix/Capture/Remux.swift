import AVFoundation
import Foundation

/// Replaces the video's audio track with the mixed one.
///
/// With echo cancellation on, the mic is no longer part of the SCStream, so
/// SCRecordingOutput muxes system audio and nothing else: a screen recording
/// of a call where you can't hear yourself. This puts the full mix back, which
/// also means the video ends up with the echo-cancelled mic rather than the
/// raw one it used to get. It is what makes `mixed.mp4` deserve the name.
///
/// Passthrough export: the video is copied stream-for-stream, never re-encoded,
/// so this costs a container rewrite rather than a transcode and nothing is
/// lost. The original is replaced only after the new file is written and
/// verified, and `replaceItemAt` makes the swap atomic, so an interrupted remux
/// leaves the original video exactly as it was.
enum Remux {
    enum RemuxError: Error, CustomStringConvertible {
        case noVideoTrack
        case exportUnavailable
        case verificationFailed

        var description: String {
            switch self {
            case .noVideoTrack: return "the recording has no video track"
            case .exportUnavailable: return "the system offers no passthrough export preset"
            case .verificationFailed: return "the remuxed file didn't come back readable"
            }
        }
    }

    static func mixedAudioIntoVideo(in dir: URL) async {
        let audio = dir.appendingPathComponent(SessionFiles.mixedAudio)
        guard
            let video = SessionFiles.video(in: dir),
            FileManager.default.fileExists(atPath: audio.path)
        else { return }

        do {
            try await swap(video: video, audio: audio, videoOffsetMs: videoOffsetMs(in: dir))
            Log.info("\(dir.lastPathComponent): \(video.lastPathComponent) now carries the mixed audio")
        } catch {
            // The original is untouched on every failure path, so this
            // degrades to "video has system audio only" rather than losing it.
            Log.warn("\(dir.lastPathComponent): can't remux \(video.lastPathComponent): \(error)")
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

    private static func swap(video: URL, audio: URL, videoOffsetMs: Int) async throws {
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
        try destVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceVideo,
            at: .zero
        )
        // Carried across explicitly; a composition track doesn't inherit it,
        // and losing it would rotate the video on playback.
        destVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let audioAsset = AVURLAsset(url: audio)
        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let destAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            // mixed.m4a's zero is the *earliest* track of the session, which is
            // not necessarily the video: audio and screen buffers arrive off
            // the same SCStream in whichever order the stream happens to
            // deliver them, and `start_offset_ms` records that per track. So
            // the mix is read from the video's own offset rather than from its
            // start, which is what puts the two on the same clock. Usually the
            // video is first and the offset is zero, making this a no-op; when
            // it isn't, this is the difference between synced audio and audio
            // running early by however long the video took to produce a frame.
            //
            // Clamped to the video length so a longer audio tail can't stretch
            // the file past its last frame.
            let audioDuration = try await audioAsset.load(.duration)
            let start = CMTime(value: CMTimeValue(videoOffsetMs), timescale: 1000)
            let available = audioDuration - start
            if available > .zero {
                try destAudio.insertTimeRange(
                    CMTimeRange(start: start, duration: min(available, duration)),
                    of: sourceAudio,
                    at: .zero
                )
            }
        }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { throw RemuxError.exportUnavailable }

        // Written beside the original and exported to whatever container the
        // original uses, so a pre-rename screen.mov is remuxed as a .mov and
        // stays where it is rather than becoming a second file.
        let isMP4 = video.pathExtension.lowercased() == "mp4"
        let temp = video.deletingLastPathComponent()
            .appendingPathComponent("remux.tmp.\(video.pathExtension)")
        try? FileManager.default.removeItem(at: temp)
        try await export.export(to: temp, as: isMP4 ? .mp4 : .mov)

        // Read it back before trusting it with the only copy of the video.
        let check = AVURLAsset(url: temp)
        guard try await !check.loadTracks(withMediaType: .video).isEmpty,
              try await check.load(.duration).seconds > 0
        else {
            try? FileManager.default.removeItem(at: temp)
            throw RemuxError.verificationFailed
        }

        _ = try FileManager.default.replaceItemAt(video, withItemAt: temp)
    }
}
