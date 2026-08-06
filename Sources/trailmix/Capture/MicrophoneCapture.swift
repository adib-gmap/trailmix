import AVFoundation
import Foundation

/// Microphone capture with acoustic echo cancellation.
///
/// ScreenCaptureKit's `captureMicrophone` hands over the raw input, so
/// anything playing through the speakers lands in the mic track as well as the
/// system track. The visible symptom was a transcript that said everything
/// twice, once as `Mic` and once as `System`, a second apart. The real cost is
/// worse: a mic recording of a call is half the far side, at whatever volume
/// the speakers happened to be at.
///
/// macOS will do the subtraction, but only through the voice-processing IO
/// unit, which ScreenCaptureKit does not expose. So the mic comes off
/// AVAudioEngine instead, with `setVoiceProcessingEnabled(true)`, and only
/// system audio and video stay on the SCStream.
///
/// The trade is that voice processing is a bundle: echo cancellation arrives
/// with automatic gain control and noise suppression, and the mic will sound
/// processed compared to before. `echo_cancellation: false` in the config puts
/// the mic back on ScreenCaptureKit, raw, exactly as it used to be.
///
/// Losing the shared ScreenCaptureKit timebase costs less than it looks: the
/// tracks never started on the same buffer anyway, which is why every session
/// records a per-track `start_offset_ms` measured from the first buffer's
/// arrival. That mechanism is unchanged and covers this the same way.
final class MicrophoneCapture: @unchecked Sendable {
    enum MicError: Error, CustomStringConvertible {
        case noInputFormat

        var description: String {
            switch self {
            case .noInputFormat:
                return "the input device reported no usable format. Is a microphone connected?"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let writer: AudioTrackWriter
    private var tapped = false

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    /// True if echo cancellation is actually engaged, as opposed to requested.
    private(set) var echoCancelled = false

    func start() throws {
        let input = engine.inputNode

        // Must precede any format query and the engine start. A device that
        // won't do voice processing (some aggregate and virtual devices) is
        // worth recording raw rather than not at all.
        do {
            try input.setVoiceProcessingEnabled(true)
            echoCancelled = true
        } catch {
            Log.warn(
                "echo cancellation unavailable on this input, recording raw: "
                    + error.localizedDescription
            )
        }

        // Voice processing assumes it is powering a chat app, so by default it
        // ducks everything else on the machine to make the far side easier to
        // hear. In a recorder that is backwards: it quietens the very audio
        // being recorded, and the user hears their own video drop in volume
        // the instant they press record.
        //
        // `.min` rather than off, because there is no off. Advanced ducking,
        // which ducks dynamically on detected speech, is switched off too, so
        // at least the level stays put instead of pumping.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.noInputFormat
        }

        // `nil`, not `format`. The node's reported format is not a promise
        // about what the tap delivers, and passing it back is how you install
        // a tap that disagrees with its own buffers.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [writer] buffer, _ in
            guard let mono = Self.firstChannel(of: buffer) else { return }
            writer.append(mono)
        }
        tapped = true

        engine.prepare()
        try engine.start()
        Log.info(
            "microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount)ch, "
                + "echo cancellation \(echoCancelled ? "on" : "off")"
        )
    }

    /// Take channel 0 and discard the rest.
    ///
    /// The voice-processing input node reports **nine channels on a
    /// one-channel device**, verified with `trailmix mic` on the built-in
    /// MacBook Pro microphone, which presents 1ch before
    /// `setVoiceProcessingEnabled(true)` and 9ch after. All nine carry the
    /// identical processed mono signal, to the last decimal of peak and RMS.
    ///
    /// Handing that to the writer's mono downmix produced silent recordings:
    /// `AVAudioConverter` has no channel layout to reason about above two
    /// channels, so a 9→1 conversion yields near-nothing rather than failing
    /// loudly. A 28-second `mic.caf` came out holding 5 KB of AAC silence,
    /// which is indistinguishable from a real recording until you play it.
    ///
    /// Taking one channel of a duplicated set loses nothing. It would matter
    /// on a genuinely multi-capsule input, but voice processing collapses
    /// anything it is given to mono before this point.
    ///
    /// Internal rather than private so the tests can reach it. It is the fix
    /// for a bug whose only symptom was a silent file, and everything around it
    /// (the engine, the tap, the device) needs a microphone to exercise.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer }
        guard
            let source = buffer.floatChannelData,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: buffer.format.sampleRate,
                channels: 1
            ),
            let mono = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: buffer.frameLength
            ),
            let destination = mono.floatChannelData
        else { return nil }

        mono.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return mono
    }

    /// Idempotent. Does not close the writer: the session closes every track
    /// together so they finalize on one path.
    func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
    }
}
