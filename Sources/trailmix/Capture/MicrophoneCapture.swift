import AVFoundation
import AudioToolbox
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
/// unit, which ScreenCaptureKit does not expose. So the mic comes off that
/// unit instead, and only system audio and video stay on the SCStream.
///
/// The unit is driven directly through AudioToolbox rather than through
/// `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`. The engine
/// wrapper is not reliable: on a 16" MacBook Pro (M2 Pro, macOS 15.6) with the
/// built-in microphone and speakers as the defaults, the engine reports a
/// 3-channel (sometimes 9-channel) input format after enabling voice
/// processing, starts without error, and then never delivers a single tap
/// buffer. Connecting the input to the output exposes the underlying failure:
/// `-10875`, "client-side input and output formats do not match", from
/// AUVPAggregate. The same `kAudioUnitSubType_VoiceProcessingIO` unit, created
/// and started by hand on the same Mac, delivers echo-cancelled mono at 48 kHz
/// without complaint. Apple's forums carry the same report (threads 772006
/// and 771530) with no fix on the engine side.
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
        case noVoiceProcessingUnit
        case audioUnit(String, OSStatus)

        var description: String {
            switch self {
            case .noInputFormat:
                return "the input device reported no usable format. Is a microphone connected?"
            case .noVoiceProcessingUnit:
                return "macOS has no VoiceProcessingIO audio unit"
            case .audioUnit(let step, let status):
                return "VoiceProcessingIO \(step) failed (\(status))"
            }
        }
    }

    /// What the unit hands over and what the writer receives: mono float at
    /// 48 kHz. Voice processing collapses the input to one channel regardless
    /// of the device, so asking for mono costs nothing and spares the writer a
    /// downmix.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private let writer: AudioTrackWriter
    private var unit: AudioUnit?

    /// Used only when the voice-processing unit cannot be set up: a device
    /// that will not do voice processing is worth recording raw rather than
    /// not at all.
    private var rawEngine: AVAudioEngine?
    private var tapped = false

    init(writer: AudioTrackWriter) {
        self.writer = writer
    }

    /// True if echo cancellation is actually engaged, as opposed to requested.
    private(set) var echoCancelled = false

    func start() throws {
        do {
            try startVoiceProcessing()
            echoCancelled = true
            Log.info("microphone: 48000 Hz, 1ch, echo cancellation on")
        } catch {
            Log.warn(
                "echo cancellation unavailable on this input, recording raw: "
                    + "\(error)"
            )
            try startRaw()
        }
    }

    // MARK: - Voice-processing unit

    private func startVoiceProcessing() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicError.noVoiceProcessingUnit
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "create")
        guard let au = instance else { throw MicError.noVoiceProcessingUnit }
        unit = au

        // Element 1 is the input (microphone) side, element 0 the output
        // (speaker) side. Both have to be enabled: the echo canceller needs
        // the output stream as its reference, even though nothing is played.
        var enabled: UInt32 = 1
        try check(AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enabled, UInt32(MemoryLayout<UInt32>.size)
        ), "enable input")
        try check(AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enabled, UInt32(MemoryLayout<UInt32>.size)
        ), "enable output")

        // Client-side formats: what we read from the input element and what
        // we feed the output element. Same mono format on both sides, which
        // is what the unit's aggregate wants to see.
        var asbd = format.streamDescription.pointee
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, asbdSize
        ), "set input format")
        try check(AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &asbd, asbdSize
        ), "set output format")

        // Voice processing assumes it is powering a chat app, so by default it
        // ducks everything else on the machine to make the far side easier to
        // hear. In a recorder that is backwards: it quietens the very audio
        // being recorded, and the user hears their own video drop in volume
        // the instant they press record.
        //
        // `.min` rather than off, because there is no off. Advanced ducking,
        // which ducks dynamically on detected speech, is switched off too, so
        // at least the level stays put instead of pumping. Not fatal if the
        // property is refused: the recording is still right, only quieter.
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: .min
        )
        let duckStatus = AudioUnitSetProperty(
            au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
            &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
        )
        if duckStatus != noErr {
            Log.warn("microphone: could not limit other-audio ducking (\(duckStatus))")
        }

        // The input callback fires once per hardware buffer with the processed
        // microphone signal ready to be pulled with AudioUnitRender. The
        // output callback has to exist too, and it supplies silence.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var inputCallback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frames, _ in
                Unmanaged<MicrophoneCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .pullInput(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: refCon
        )
        try check(AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1,
            &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "set input callback")

        var outputCallback = AURenderCallbackStruct(
            inputProc: { _, flags, _, _, _, ioData in
                if let ioData {
                    for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                }
                flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                return noErr
            },
            inputProcRefCon: nil
        )
        try check(AudioUnitSetProperty(
            au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "set output callback")

        try check(AudioUnitInitialize(au), "initialize")
        try check(AudioOutputUnitStart(au), "start")
    }

    /// Runs on the unit's real-time I/O thread. Pulls one buffer of processed
    /// microphone audio and hands it to the writer, which does its own
    /// locking and encoding.
    private func pullInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(
            unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }
        writer.append(buffer)
        return noErr
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            tearDownUnit()
            throw MicError.audioUnit(step, status)
        }
    }

    private func tearDownUnit() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    // MARK: - Raw fallback

    private func startRaw() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.noInputFormat
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [writer] buffer, _ in
            guard let mono = Self.firstChannel(of: buffer) else { return }
            writer.append(mono)
        }
        tapped = true
        rawEngine = engine
        engine.prepare()
        try engine.start()
        Log.info(
            "microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount)ch, "
                + "echo cancellation off"
        )
    }

    /// Take channel 0 and discard the rest.
    ///
    /// Used by the raw fallback, where the engine's input node can present a
    /// multichannel format whose channels all carry the same signal. Handing
    /// that to the writer's mono downmix produced silent recordings:
    /// `AVAudioConverter` has no channel layout to reason about above two
    /// channels, so a 9→1 conversion yields near-nothing rather than failing
    /// loudly.
    ///
    /// Internal rather than private so the tests can reach it.
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
        tearDownUnit()
        if tapped {
            rawEngine?.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if let rawEngine, rawEngine.isRunning { rawEngine.stop() }
        rawEngine = nil
    }
}
