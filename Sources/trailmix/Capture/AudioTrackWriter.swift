import AVFoundation
import CoreMedia
import Foundation

/// Streams one ScreenCaptureKit audio output into a CAF file, encoding AAC.
///
/// One writer per track: `.audio` becomes system.caf, `.microphone` becomes
/// mic.caf. Keeping them in separate files is what gives trailmix
/// two-party diarization without a speaker-identification model, and it's the
/// reason the recording output's muxed audio isn't enough on its own.
///
/// CAF on purpose, matching the old recorders: unlike m4a it needs no
/// finalization pass, so a process killed mid-meeting still leaves everything
/// already written readable.
final class AudioTrackWriter: @unchecked Sendable {
    enum WriterError: Error, CustomStringConvertible {
        case unsupportedFormat
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .unsupportedFormat: return "can't derive an output format for the track"
            case .fileCreationFailed(let e): return "track file creation failed: \(e)"
            }
        }
    }

    private let url: URL
    private let downmixToMono: Bool

    // Everything below is touched from the stream's sample-handler queue and
    // read from the main actor at stop time. The lock covers all of it.
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var failed = false
    private var firstBuffer: Date?
    /// Set by `close()` and never cleared. See `append`: without it, a buffer
    /// arriving after the close reopens the file and erases the recording.
    private var closed = false
    /// Set while the recording is paused. Buffers are dropped rather than
    /// written, so the track comes out gapless: paused time is simply absent
    /// from the file, which is what keeps it on the same clock as the video
    /// once `Remux` has cut the same ranges out of that.
    private var paused = false

    /// - Parameter downmixToMono: true for the mic track. Parakeet wants one
    ///   channel, and the mic's native format follows the capture device, so
    ///   it can arrive multichannel. System audio keeps its native stereo.
    init(url: URL, downmixToMono: Bool) {
        self.url = url
        self.downmixToMono = downmixToMono
    }

    /// Wall-clock time of the first sample buffer: this track's true start,
    /// used to offset-align transcript timestamps across tracks.
    var firstBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return firstBuffer
    }

    /// True if any write failed. Surfaced after stop so a full disk or an
    /// encoder error doesn't pass silently.
    var hadFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// Whether anything was actually written. A track that never received a
    /// buffer leaves a zero-length file that the transcriber can't read.
    var wroteAnything: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstBuffer != nil
    }

    /// Append one ScreenCaptureKit sample buffer, from the stream's
    /// sample-handler queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let sourceFormat = sampleBuffer.formatDescription
            .flatMap({ AVAudioFormat(cmAudioFormatDescription: $0) })
        else { return }

        let source: AVAudioPCMBuffer
        do {
            source = try Self.pcmBuffer(from: sampleBuffer, format: sourceFormat)
        } catch {
            lock.lock()
            reportOnce("track write failed: \(error)")
            lock.unlock()
            return
        }
        append(source)
    }

    /// Append one PCM buffer, from an AVAudioEngine tap.
    ///
    /// The output file is created lazily from the first buffer's format:
    /// neither ScreenCaptureKit nor a voice-processing input node commits to
    /// one until samples actually flow.
    ///
    /// Note that `firstBuffer` is published only once a write has actually
    /// landed, so a track whose file can't be opened or whose every buffer
    /// fails to convert never counts as having written anything. That is what
    /// stops a path that doesn't exist from being listed in meta.json as a real
    /// track: `wroteAnything` reads this field, and setting it on the way in
    /// meant an unwritable recordings folder reported a failure *and* a track.
    /// The timestamp is taken on arrival rather than after the encode, since it
    /// is the track's start and not the moment the encoder caught up.
    ///
    /// A buffer arriving after `close()` is dropped, and that guard is
    /// load-bearing rather than tidy. Reopening lazily is what makes the first
    /// buffer's format decide the file, but `AVAudioFile(forWriting:)` erases
    /// whatever is already at the path, so one late buffer replaces the whole
    /// recording with a fraction of a second of audio, silently. Buffers do
    /// arrive after the close: `stream(_:didStopWithError:)` closes both
    /// writers while the mic engine is still running and its tap still firing,
    /// and `stop()` gives up on `stopCapture()` after five seconds and closes
    /// regardless while the stream may still be delivering.
    func append(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        guard !closed, !paused else { return }
        let arrival = Date()
        if file == nil {
            do {
                try openFile(sourceFormat: source.format)
            } catch {
                reportOnce("track open failed: \(error)")
                return
            }
        }
        guard let file, let outputFormat else { return }

        do {
            if let converter {
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: source.frameLength
                ) else { return }
                try converter.convert(to: converted, from: source)
                try file.write(from: converted)
            } else {
                try file.write(from: source)
            }
        } catch {
            reportOnce("track write failed: \(error)")
            return
        }
        if firstBuffer == nil { firstBuffer = arrival }
    }

    /// Drop every buffer until `setPaused(false)`. The capture keeps running
    /// (stopping and restarting the stream is what a pause is *not*), so the
    /// gate lives here, at the one place every buffer passes through. The
    /// source stays unaware: the mic unit and the SCStream deliver as before.
    ///
    /// Harmless after `close()`, since the closed guard runs first.
    func setPaused(_ on: Bool) {
        lock.lock()
        paused = on
        lock.unlock()
    }

    /// Finalize. Idempotent, and terminal: the track cannot be reopened, so a
    /// late buffer is dropped rather than erasing the file. See `append`.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file = nil
        converter = nil
    }

    // MARK: -

    private func openFile(sourceFormat: AVAudioFormat) throws {
        let target: AVAudioFormat
        if downmixToMono, sourceFormat.channelCount != 1 {
            guard let mono = AVAudioFormat(
                commonFormat: sourceFormat.commonFormat,
                sampleRate: sourceFormat.sampleRate,
                channels: 1,
                interleaved: sourceFormat.isInterleaved
            ) else { throw WriterError.unsupportedFormat }
            guard let conv = AVAudioConverter(from: sourceFormat, to: mono) else {
                throw WriterError.unsupportedFormat
            }
            converter = conv
            target = mono
        } else {
            target = sourceFormat
        }

        // Same AAC-in-CAF settings the Core Audio recorders used.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: target.channelCount,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: target.commonFormat,
                interleaved: target.isInterleaved
            )
        } catch {
            throw WriterError.fileCreationFailed(error)
        }
        outputFormat = target
    }

    /// Wrap a CMSampleBuffer's audio in an AVAudioPCMBuffer without copying
    /// the samples.
    ///
    /// The buffer list is sized by asking, not by assuming. `AudioBufferList`
    /// is a variable-length C struct and the Swift type has room for exactly
    /// one `AudioBuffer`, so `MemoryLayout<AudioBufferList>.size` fits mono
    /// and nothing else. ScreenCaptureKit delivers non-interleaved stereo as
    /// two buffers, which made this fail with
    /// `kCMSampleBufferError_ArrayTooSmall` on every single system-audio
    /// buffer: `system.caf` got its header written from the first buffer's
    /// format and then not one sample. The mic track escaped because the
    /// downmix runs at the *other* end, so its source was already mono.
    private static func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, listSize >= MemoryLayout<AudioBufferList>.size else {
            throw WriterError.unsupportedFormat
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            raw.deallocate()
            throw WriterError.unsupportedFormat
        }

        // The samples live in the block buffer, which therefore has to outlive
        // the PCM buffer pointing at them. Capturing it in the deallocator ties
        // the two together. The previous `withExtendedLifetime(blockBuffer) {}`
        // ran before the caller had touched a single sample and guaranteed
        // nothing at all.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: list,
            deallocator: { _ in
                withExtendedLifetime(blockBuffer) {}
                raw.deallocate()
            }
        ) else {
            raw.deallocate()
            throw WriterError.unsupportedFormat
        }
        return buffer
    }

    /// Log the first failure only. A full disk produces one of these per
    /// buffer, which is hundreds per second.
    private func reportOnce(_ message: String) {
        guard !failed else { return }
        failed = true
        Log.warn("\(url.lastPathComponent): \(message)")
    }
}
