import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import trailmix

/// The three worst bugs this project has had were all here, and all three were
/// silent: a file of the right length, holding nothing, with no error logged
/// anywhere. `system.caf` was 28672 bytes of CAF header and zero audio packets
/// on *every recording ever made* before 2026-08-04, and it stayed hidden
/// because the mic track was picking up the same audio through the speakers.
///
/// Each one was found with a throwaway harness that fed synthetic buffers
/// through the real writer and measured what came out, and that harness was
/// written and thrown away three times. This is that harness, kept.
///
/// Nothing here needs a microphone, a screen, or a click. It does use the
/// system AAC encoder, which is the point: the failures were in the handoff
/// between a sample buffer and the encoder, so a test that stopped short of the
/// file on disk would have caught none of them.
@Suite("AudioTrackWriter")
struct AudioTrackWriterTests {

    // MARK: - Fixtures

    private static let sampleRate = 48000.0
    private static let frames = 12000  // 0.25 s, enough for several AAC packets

    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailmix-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// A loud sine tone, non-interleaved float32, which is the shape ScreenCaptureKit
    /// delivers. Every channel gets the same tone, so a downmix that drops
    /// channels and one that sums them are both still audible; what is being
    /// checked is that *something* survives, since the bugs produced zero.
    private func tone(channels: AVAudioChannelCount, frames: Int = frames) throws
        -> AVAudioPCMBuffer
    {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< frames {
                data[channel][frame] = 0.5 * sinf(
                    2 * .pi * 440 * Float(frame) / Float(Self.sampleRate)
                )
            }
        }
        return buffer
    }

    /// Wrap a PCM buffer as a `CMSampleBuffer`, the way ScreenCaptureKit hands
    /// one over.
    ///
    /// A non-interleaved multi-channel buffer becomes an `AudioBufferList` with
    /// one `AudioBuffer` *per channel*, which is the detail the writer used to
    /// get wrong: `MemoryLayout<AudioBufferList>.size` has room for exactly one,
    /// so stereo came back `kCMSampleBufferError_ArrayTooSmall` and every buffer
    /// was dropped.
    private func sampleBuffer(from pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var asbd = pcm.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        try #require(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ) == noErr
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        try #require(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: CMItemCount(pcm.frameLength),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ) == noErr
        )
        let created = try #require(sampleBuffer)
        try #require(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                created,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: pcm.audioBufferList
            ) == noErr
        )
        return created
    }

    /// What actually landed on disk. Peak is the discriminator: the bugs all
    /// produced a readable file whose every sample was zero.
    private struct Decoded {
        let frames: AVAudioFramePosition
        let channels: AVAudioChannelCount
        let sampleRate: Double
        let peak: Float

        var isSilent: Bool { peak < 0.0001 }
    }

    private func decode(_ url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        var peak: Float = 0
        if file.length > 0,
           let buffer = AVAudioPCMBuffer(
               pcmFormat: file.processingFormat,
               frameCapacity: AVAudioFrameCount(file.length)
           ),
           (try? file.read(into: buffer)) != nil,
           let data = buffer.floatChannelData
        {
            for channel in 0 ..< Int(buffer.format.channelCount) {
                for frame in 0 ..< Int(buffer.frameLength) {
                    peak = max(peak, abs(data[channel][frame]))
                }
            }
        }
        return Decoded(
            frames: file.length,
            channels: file.fileFormat.channelCount,
            sampleRate: file.fileFormat.sampleRate,
            peak: peak
        )
    }

    // MARK: - The system track: non-interleaved stereo off ScreenCaptureKit

    /// The regression test for the empty `system.caf`.
    ///
    /// Against the old implementation this produced a 28672-byte file with zero
    /// frames, because the `AudioBufferList` was sized with
    /// `MemoryLayout<AudioBufferList>.size` and stereo needs room for two
    /// `AudioBuffer`s. The header still got written, since it comes from the
    /// first buffer's *format*, which parses fine, so the file looked real.
    @Test("stereo system audio reaches the file")
    func stereoSystemAudio() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.system)
            let writer = AudioTrackWriter(url: url, downmixToMono: false)
            for _ in 0 ..< 4 {
                writer.append(try sampleBuffer(from: try tone(channels: 2)))
            }
            writer.close()

            let decoded = try decode(url)
            #expect(!decoded.isSilent, "system.caf is the right length and silent: the old bug")
            #expect(decoded.frames > 0)
            #expect(decoded.channels == 2, "system audio keeps its native stereo")
            #expect(decoded.sampleRate == Self.sampleRate)
            #expect(writer.hadFailure == false)
            #expect(writer.wroteAnything)
        }
    }

    /// Mono is the case that always worked, and the reason the stereo bug hid
    /// for as long as it did: the mic happens to arrive mono.
    @Test("mono audio reaches the file")
    func monoAudio() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            writer.append(try sampleBuffer(from: try tone(channels: 1)))
            writer.close()

            let decoded = try decode(url)
            #expect(!decoded.isSilent)
            #expect(decoded.channels == 1)
            #expect(writer.hadFailure == false)
        }
    }

    /// A stereo source on the mic track exercises the downmix, which the real
    /// mic has never hit here, since the built-in input arrives mono. It would have
    /// failed identically to the system track before the sizing fix, so this is
    /// the half of that bug nobody could reproduce on this machine.
    @Test("a stereo source on the mic track is downmixed, not dropped")
    func stereoDownmixedToMono() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            for _ in 0 ..< 4 {
                writer.append(try sampleBuffer(from: try tone(channels: 2)))
            }
            writer.close()

            let decoded = try decode(url)
            #expect(!decoded.isSilent)
            #expect(decoded.channels == 1, "the mic track is mono for parakeet")
            #expect(decoded.frames > 0)
            #expect(writer.hadFailure == false)
        }
    }

    /// The duration has to survive too. A writer that kept one buffer out of
    /// four would still pass a "not silent" check.
    @Test("every buffer is written, not just the first")
    func allBuffersAreWritten() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.system)
            let writer = AudioTrackWriter(url: url, downmixToMono: false)
            let buffers = 8
            for _ in 0 ..< buffers {
                writer.append(try sampleBuffer(from: try tone(channels: 2)))
            }
            writer.close()

            // AAC pads with priming frames, so this is a band rather than an
            // equality: what it rules out is a fraction of the input surviving.
            let expected = Double(buffers * Self.frames)
            let actual = Double(try decode(url).frames)
            #expect(actual > expected * 0.9)
            #expect(actual < expected * 1.2)
        }
    }

    // MARK: - The mic track: PCM buffers off an AVAudioEngine tap

    /// The other entry point. `MicrophoneCapture` taps the voice-processing
    /// node and hands PCM buffers straight over, never a CMSampleBuffer.
    @Test("PCM buffers from a tap reach the file")
    func pcmBufferPath() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            for _ in 0 ..< 4 {
                writer.append(try tone(channels: 1))
            }
            writer.close()

            let decoded = try decode(url)
            #expect(!decoded.isSilent)
            #expect(decoded.channels == 1)
        }
    }

    // MARK: - Pausing

    /// A pause drops buffers instead of writing them, so the file holds only
    /// the unpaused ones, back to back. That gap-free file is what keeps the
    /// audio on the same clock as a video that has had the same stretch cut
    /// out of it.
    @Test("buffers while paused are dropped and writing resumes")
    func pausedBuffersAreDropped() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            let buffer = try tone(channels: 1)

            writer.append(buffer)
            writer.append(buffer)
            writer.setPaused(true)
            writer.append(buffer)
            writer.append(buffer)
            writer.append(buffer)
            writer.setPaused(false)
            writer.append(buffer)
            writer.close()

            let decoded = try decode(url)
            // Three buffers' worth, not six. AAC pads the tail by up to a
            // packet, so this is a window rather than an exact count.
            let written = Double(decoded.frames) / Double(Self.frames)
            #expect(written > 2.7 && written < 3.6, "expected 3 buffers, decoded \(written)")
            #expect(!decoded.isSilent)
            #expect(!writer.hadFailure)
        }
    }

    /// Pausing before the first buffer ever lands must not break the lazy
    /// open: the file is created by the first buffer written after the
    /// resume, and that buffer is the track's start.
    @Test("a pause before the first buffer still opens the file on resume")
    func pauseBeforeFirstBuffer() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            let buffer = try tone(channels: 1)

            writer.setPaused(true)
            writer.append(buffer)
            #expect(!writer.wroteAnything, "a dropped buffer is not a start")
            #expect(!FileManager.default.fileExists(atPath: url.path))
            writer.setPaused(false)
            writer.append(buffer)
            writer.close()

            #expect(writer.wroteAnything)
            #expect(!(try decode(url)).isSilent)
        }
    }

    /// `close()` is terminal; flipping the pause flag afterwards must not
    /// reopen the track or erase it.
    @Test("setPaused after close is harmless")
    func setPausedAfterClose() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            let buffer = try tone(channels: 1)
            writer.append(buffer)
            writer.close()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int

            writer.setPaused(true)
            writer.setPaused(false)
            writer.append(buffer)

            let after = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            #expect(after == size, "the closed track was touched")
        }
    }

    // MARK: - The track contract RecordingSession depends on

    /// `wroteAnything` is what decides whether a track is listed in meta.json.
    /// Getting it wrong in the optimistic direction promises the transcriber a
    /// file it can't read.
    @Test("a writer that received nothing reports nothing written")
    func emptyWriterWroteNothing() throws {
        try inTemporaryDirectory { dir in
            let writer = AudioTrackWriter(
                url: dir.appendingPathComponent(SessionFiles.mic),
                downmixToMono: true
            )
            #expect(!writer.wroteAnything)
            #expect(writer.firstBufferAt == nil)
            #expect(!writer.hadFailure)
            writer.close()
            #expect(!writer.wroteAnything)
        }
    }

    /// A zero-frame buffer must not count as a start. It would put a
    /// `start_offset_ms` in meta.json for a track with no audio, and shift the
    /// whole transcript against it.
    @Test("an empty buffer doesn't count as the first")
    func emptyBufferIsIgnored() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            writer.append(try tone(channels: 1, frames: 0))
            #expect(!writer.wroteAnything)

            writer.append(try tone(channels: 1))
            #expect(writer.wroteAnything)
            #expect(writer.firstBufferAt != nil)
            writer.close()
        }
    }

    /// `close()` runs from the stop path and again from
    /// `stream(_:didStopWithError:)` when a capture dies on its own, so both can
    /// land for one recording.
    @Test("close is idempotent")
    func closeIsIdempotent() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.system)
            let writer = AudioTrackWriter(url: url, downmixToMono: false)
            writer.append(try sampleBuffer(from: try tone(channels: 2)))
            writer.close()
            writer.close()
            #expect(!(try decode(url)).isSilent)
        }
    }

    /// A buffer arriving after the close must not erase the recording.
    ///
    /// The file is opened lazily from the first buffer's format, and
    /// `AVAudioFile(forWriting:)` truncates whatever is already at the path. So
    /// before `close()` was made terminal, one late buffer reopened the file
    /// and replaced eight buffers of audio with one: measured here at 96000
    /// frames before and 12000 after, with nothing logged and a file that still
    /// plays. The right length is the *only* thing this project's silent-audio
    /// bugs have ever got wrong, and this one gets even that right.
    ///
    /// It is reachable two ways, and the first is not a race at all.
    /// `stream(_:didStopWithError:)` closes both writers without stopping the
    /// mic engine, so every tap callback between there and
    /// `MicrophoneCapture.stop()` lands after the close: that is a captured
    /// window being shut mid-recording, and it takes a main-actor hop plus a
    /// bounded `stopCapture()` to come back. `stop()` is the second: it gives
    /// up on `stopCapture()` after five seconds and closes anyway, while the
    /// stream may still be delivering system audio.
    @Test("a buffer arriving after close doesn't erase the recording")
    func lateBufferDoesNotEraseTheFile() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.system)
            let writer = AudioTrackWriter(url: url, downmixToMono: false)
            for _ in 0 ..< 8 {
                writer.append(try sampleBuffer(from: try tone(channels: 2)))
            }
            writer.close()
            let afterClose = try decode(url).frames

            writer.append(try sampleBuffer(from: try tone(channels: 2)))
            writer.append(try tone(channels: 2))

            let afterLateBuffers = try decode(url)
            #expect(
                afterLateBuffers.frames == afterClose,
                "a late buffer reopened the file and erased the recording"
            )
            #expect(!afterLateBuffers.isSilent)
        }
    }

    /// The mic track's own entry point, since the guaranteed-window case above
    /// is the tap and not the stream.
    @Test("a late tap buffer doesn't erase the mic track")
    func lateTapBufferDoesNotEraseTheFile() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            for _ in 0 ..< 8 {
                writer.append(try tone(channels: 1))
            }
            writer.close()
            let afterClose = try decode(url).frames

            for _ in 0 ..< 4 {
                writer.append(try tone(channels: 1))
            }

            #expect(try decode(url).frames == afterClose)
        }
    }

    /// A track that received nothing before the close stays absent rather than
    /// being conjured into existence by a late buffer. `wroteAnything` is what
    /// puts a track in meta.json, and a file created after the session wrote
    /// its metadata is one the transcriber is never told about.
    @Test("a late buffer on an empty track creates no file")
    func lateBufferOnEmptyTrackCreatesNothing() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.mic)
            let writer = AudioTrackWriter(url: url, downmixToMono: true)
            writer.close()

            writer.append(try tone(channels: 1))

            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(!writer.wroteAnything)
            #expect(writer.firstBufferAt == nil)
        }
    }

    /// The file is opened from the first buffer's format, because neither
    /// ScreenCaptureKit nor a voice-processing node commits to one until samples
    /// flow. Nothing should exist on disk before then.
    @Test("no file is created until a buffer arrives")
    func fileIsCreatedLazily() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent(SessionFiles.system)
            let writer = AudioTrackWriter(url: url, downmixToMono: false)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            writer.append(try sampleBuffer(from: try tone(channels: 2)))
            writer.close()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// A path that can't be created is a full disk or a recordings folder that
    /// went away mid-recording. It has to be reported rather than passed over,
    /// since `failedTracks` is the only signal the user gets.
    ///
    /// And it must not also report a track. `firstBuffer` used to be set on the
    /// way in, before the file was opened, so this path came back
    /// `hadFailure == true` *and* `wroteAnything == true` at once: meta.json
    /// then listed a track for a file that was never created, and the
    /// transcriber was pointed at a path that doesn't exist.
    @Test("an unwritable path fails loudly rather than silently")
    func unwritablePathReportsFailure() throws {
        let url = URL(fileURLWithPath: "/no/such/directory/\(SessionFiles.mic)")
        let writer = AudioTrackWriter(url: url, downmixToMono: true)
        writer.append(try tone(channels: 1))
        #expect(writer.hadFailure)
        #expect(!writer.wroteAnything, "a track that was never opened was reported as written")
        #expect(writer.firstBufferAt == nil)
        writer.close()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// The mic recorded silence for a day because of this one function.
///
/// The voice-processing input node reports (and delivers) **nine channels on
/// a one-channel device**, all carrying the identical processed mono signal.
/// Handing that to `AudioTrackWriter`'s downmix asked `AVAudioConverter` for
/// 9→1, which has no channel layout to reason about above two channels and
/// returns near-silence instead of an error. Taking channel 0 is the fix.
@Suite("MicrophoneCapture.firstChannel")
struct MicrophoneChannelTests {

    /// Above two channels there is no standard layout to ask for:
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` and the
    /// `commonFormat` initializer both return nil for nine, so the format has
    /// to be built from an explicit discrete layout. Which is itself a hint at
    /// why nothing downstream knew what to do with a 9-channel buffer.
    private func tone(channels: AVAudioChannelCount, amplitude: Float = 0.5) throws
        -> AVAudioPCMBuffer
    {
        let layout = try #require(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            interleaved: false,
            channelLayout: layout
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let data = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< 1024 {
                data[channel][frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / 48000)
            }
        }
        return buffer
    }

    /// Nine identical channels in, one carrying the same signal out. The old
    /// code path produced a buffer whose peak was effectively zero.
    @Test("nine duplicated channels collapse to one that still has signal")
    func nineChannels() throws {
        let source = try tone(channels: 9)
        let mono = try #require(MicrophoneCapture.firstChannel(of: source))

        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == source.frameLength)
        #expect(mono.format.sampleRate == source.format.sampleRate)

        let data = try #require(mono.floatChannelData)
        var peak: Float = 0
        for frame in 0 ..< Int(mono.frameLength) {
            peak = max(peak, abs(data[0][frame]))
        }
        #expect(peak > 0.4, "channel 0 of a duplicated set carries the full signal")
    }

    /// Sample-for-sample, not just loud enough. Taking a channel must not
    /// resample, rescale, or reorder anything.
    @Test("the samples are channel 0 exactly")
    func samplesAreChannelZero() throws {
        let source = try tone(channels: 9)
        let mono = try #require(MicrophoneCapture.firstChannel(of: source))
        let input = try #require(source.floatChannelData)
        let output = try #require(mono.floatChannelData)
        for frame in 0 ..< Int(mono.frameLength) {
            #expect(output[0][frame] == input[0][frame])
        }
    }

    /// A genuinely mono buffer is passed through untouched, the common case on
    /// a device that never had voice processing applied.
    @Test("a mono buffer is returned as-is")
    func monoPassesThrough() throws {
        let source = try tone(channels: 1)
        let mono = try #require(MicrophoneCapture.firstChannel(of: source))
        #expect(mono === source)
    }

    /// Stereo takes the same path as nine. Nothing here is special-cased to the
    /// number the built-in microphone happens to report.
    @Test("stereo takes the same path")
    func stereo() throws {
        let mono = try #require(MicrophoneCapture.firstChannel(of: try tone(channels: 2)))
        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 1024)
    }
}
