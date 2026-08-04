import AVFoundation
import ArgumentParser
import CoreAudio
import Foundation

/// `trailmix mic` — report what the microphone input actually delivers.
///
/// This exists because the format the input node *reports* and the format it
/// *delivers* are not the same thing once voice processing is switched on, and
/// getting that wrong is silent: the tap runs, buffers arrive, the file is
/// written, and every sample in it is zero. A 28-second `mic.caf` holding 5 KB
/// of AAC silence looks exactly like a 28-second recording until you play it.
///
/// Must be run from inside the app bundle, like everything else that touches
/// the microphone — the bare binary has no usage string and macOS kills it:
///
///     dist/Trailmix.app/Contents/MacOS/trailmix mic
struct Mic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic",
        abstract: "Report the real microphone format and signal level, with and without voice processing."
    )

    @Option(name: .long, help: "Seconds of audio to sample.")
    var seconds: Double = 2

    @Flag(name: .long, help: "Skip voice processing (raw ScreenCaptureKit-style input).")
    var raw = false

    @Option(name: .long, help: "Also record through the real MicrophoneCapture path to this file.")
    var write: String?

    func run() throws {
        print("default input device: \(Self.defaultInputName() ?? "unknown")")

        let engine = AVAudioEngine()
        let input = engine.inputNode

        print("before voice processing:")
        Self.report("  inputFormat ", input.inputFormat(forBus: 0))
        Self.report("  outputFormat", input.outputFormat(forBus: 0))

        if !raw {
            do {
                try input.setVoiceProcessingEnabled(true)
                print("voice processing: enabled")
            } catch {
                print("voice processing: FAILED — \(error.localizedDescription)")
            }
            Self.report("  inputFormat ", input.inputFormat(forBus: 0))
            Self.report("  outputFormat", input.outputFormat(forBus: 0))
        }

        // format: nil is the whole point of this exercise. Passing the format
        // read above is what produced a 9-channel tap on a 1-channel device.
        let box = Probe()
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            box.observe(buffer)
        }

        engine.prepare()
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
        input.removeTap(onBus: 0)
        engine.stop()

        box.printSummary()

        if let write { try recordThroughRealPath(to: URL(fileURLWithPath: write)) }
    }

    /// The probe above taps the node directly, which is not the code that
    /// writes recordings. This runs the actual MicrophoneCapture and
    /// AudioTrackWriter and then reads back what landed on disk — the only
    /// check that would have caught nine channels collapsing to silence.
    private func recordThroughRealPath(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        print("\nrecording \(seconds)s through MicrophoneCapture -> \(url.lastPathComponent)")

        let writer = AudioTrackWriter(url: url, downmixToMono: true)
        let capture = MicrophoneCapture(writer: writer)
        try capture.start()
        Thread.sleep(forTimeInterval: seconds)
        capture.stop()
        writer.close()

        guard let file = try? AVAudioFile(forReading: url) else {
            print("  FAILED — nothing readable was written")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        print("  \(size) bytes, \(file.length) frames, "
            + "\(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount)ch, "
            + "write failure: \(writer.hadFailure)")

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ),
            (try? file.read(into: buffer)) != nil,
            let data = buffer.floatChannelData
        else {
            print("  couldn't decode it back")
            return
        }
        var peak: Float = 0
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(data[0][i]))
            sum += Double(data[0][i]) * Double(data[0][i])
        }
        let rms = buffer.frameLength > 0 ? (sum / Double(buffer.frameLength)).squareRoot() : 0
        print("  decoded peak \(String(format: "%.5f", peak)), "
            + "rms \(String(format: "%.6f", rms)) "
            + "(\(rms > 0 ? String(format: "%.1f dBFS", 20 * log10(rms)) : "silent"))")
        print(peak > 0.0001
            ? "  FILE HAS AUDIO"
            : "  FILE IS SILENT — this is the bug")
    }

    private static func report(_ label: String, _ format: AVAudioFormat) {
        print("\(label): \(Int(format.sampleRate)) Hz, \(format.channelCount)ch, "
            + "\(format.commonFormat.rawValue == 1 ? "float32" : "fmt\(format.commonFormat.rawValue)")"
            + (format.isInterleaved ? ", interleaved" : ""))
    }

    private static func defaultInputName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        address.mScope = kAudioObjectPropertyScopeGlobal
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &nameSize, &name
        ) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Accumulates what the tap actually handed over. The tap runs on a real-time
/// thread, so it does arithmetic and nothing else.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var frames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var samples = 0
    private var format: AVAudioFormat?
    private var perChannelPeak: [Float] = []
    private var perChannelSum: [Double] = []
    private var perChannelCount = 0

    func observe(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        frames += AVAudioFramePosition(buffer.frameLength)
        if format == nil { format = buffer.format }
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        if perChannelPeak.count != channels {
            perChannelPeak = Array(repeating: 0, count: channels)
            perChannelSum = Array(repeating: 0, count: channels)
            perChannelCount = 0
        }
        for channel in 0..<channels {
            for i in 0..<Int(buffer.frameLength) {
                let v = data[channel][i]
                peak = max(peak, abs(v))
                sumSquares += Double(v) * Double(v)
                samples += 1
                perChannelPeak[channel] = max(perChannelPeak[channel], abs(v))
                perChannelSum[channel] += Double(v) * Double(v)
            }
        }
        perChannelCount += Int(buffer.frameLength)
    }

    func printSummary() {
        lock.lock()
        defer { lock.unlock() }
        print("tap delivered:")
        guard let format, buffers > 0 else {
            print("  NOTHING — no buffers arrived")
            return
        }
        print("  buffer format: \(Int(format.sampleRate)) Hz, \(format.channelCount)ch")
        print("  \(buffers) buffers, \(frames) frames "
            + "(\(String(format: "%.2f", Double(frames) / format.sampleRate))s)")
        let rms = samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0
        let db = rms > 0 ? 20 * log10(rms) : -.infinity
        print("  peak \(String(format: "%.4f", peak)), "
            + "rms \(String(format: "%.6f", rms)) (\(String(format: "%.1f", db)) dBFS)")
        print(peak > 0.0001
            ? "  SIGNAL PRESENT"
            : "  SILENT — the tap is running but every sample is zero")
        guard perChannelPeak.count > 1 else { return }
        print("  per channel (which one actually carries the mic):")
        for (i, p) in perChannelPeak.enumerated() {
            let r = perChannelCount > 0
                ? (perChannelSum[i] / Double(perChannelCount)).squareRoot() : 0
            let d = r > 0 ? 20 * log10(r) : -Double.infinity
            print("    ch\(i): peak \(String(format: "%.5f", p)) "
                + "rms \(String(format: "%.6f", r)) "
                + "(\(r > 0 ? String(format: "%.1f dBFS", d) : "silent"))")
        }
    }
}
