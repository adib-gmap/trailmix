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

    /// Append one sample buffer. Called on the stream's sample-handler queue.
    /// The output file is created lazily from the first buffer's format, since
    /// ScreenCaptureKit reports the mic's format only once samples flow.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let sourceFormat = sampleBuffer.formatDescription
            .flatMap({ AVAudioFormat(cmAudioFormatDescription: $0) })
        else { return }

        lock.lock()
        defer { lock.unlock() }

        if firstBuffer == nil { firstBuffer = Date() }
        if file == nil {
            do {
                try openFile(sourceFormat: sourceFormat)
            } catch {
                reportOnce("track open failed: \(error)")
                return
            }
        }
        guard let file, let outputFormat else { return }

        do {
            let source = try Self.pcmBuffer(from: sampleBuffer, format: sourceFormat)
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
        }
    }

    /// Finalize. Idempotent; safe to call from a signal handler path.
    func close() {
        lock.lock()
        defer { lock.unlock() }
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
