import AVFoundation
import AudioToolbox
import CoreAudio

/// Microphone capture straight from a CoreAudio HAL output unit, bypassing AVAudioEngine.
///
/// AVAudioEngine's input node follows the system default input device. It accepts
/// `kAudioOutputUnitProperty_CurrentDevice`, but when the chosen device and the default run
/// at different sample rates (a Bluetooth hearing aid at 8 kHz as the default, the built-in
/// microphone at 48 kHz chosen) the engine keeps the default's format in its cache and
/// `start()` fails with -10868, or starts and delivers nothing (measured 2026-09-11 and
/// 2026-09-16, `rate.swift` trials A and B). A bare HALOutput unit has no such cache: it
/// binds to the device it is told, reports that device's real format, and delivers audio.
///
/// Used only when the engine cannot route; every buffer goes into the same tap path the
/// engine's buffers use, so nothing downstream knows the difference.
final class DirectInput {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat?
    private(set) var deviceUID: String?
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var scratch: AVAudioPCMBuffer?
    /// Frames are gathered into 100 ms chunks before delivery, the size AVAudioEngine's tap
    /// hands the pipeline (4800 at 48 kHz). The HAL calls back every 512 frames, and the AGC's
    /// trackers step once per buffer: fed nine times as often they hunted, the floor estimate
    /// climbed into speech, and whole sentences came out as noise (2026-09-16 16:50).
    private var chunk: AVAudioPCMBuffer?
    private var chunkFrames: UInt32 = 4800
    private let frames: UInt32 = 4096

    /// Bind to `deviceUID`, read its hardware format, and start pulling. Throws with the
    /// CoreAudio status when any step refuses.
    func start(deviceUID: String, deviceID: AudioDeviceID, sink: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw DirectInputError.status(-1, "no HAL output unit") }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "instance")
        guard let au else { throw DirectInputError.status(-1, "no instance") }
        unit = au
        var one: UInt32 = 1, zero: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        var dev = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "set device")
        // The device's own format on the input side; the client side gets the same rate and
        // channel count as non-interleaved Float32, which is what an AVAudioPCMBuffer holds.
        var hw = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read hardware format")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else { throw DirectInputError.status(-1, "device reports no format") }
        let channels = min(hw.mChannelsPerFrame, 2)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate, channels: channels, interleaved: false) else {
            throw DirectInputError.status(-1, "client format")
        }
        var client = fmt.streamDescription.pointee
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set client format")
        var maxFrames = frames
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
        format = fmt
        self.deviceUID = deviceUID
        self.sink = sink
        scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames * 2)
        chunkFrames = UInt32(max(1024, Int(fmt.sampleRate * 0.1)))
        chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames)
        chunk?.frameLength = 0
        var cb = AURenderCallbackStruct(inputProc: DirectInput.inputProc,
                                        inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(au), "initialize")
        try check(AudioOutputUnitStart(au), "start")
    }

    var isRunning: Bool { unit != nil }

    func stop() {
        guard let au = unit else { return }
        unit = nil
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        sink = nil
        scratch = nil
        chunk = nil
    }

    deinit { stop() }

    /// Pulls the frames CoreAudio just captured into the scratch buffer and hands a copy to
    /// the sink. Runs on the HAL's IO thread: no allocation beyond the deep copy the tap path
    /// already makes for engine buffers.
    private static let inputProc: AURenderCallback = { refCon, flags, timestamp, bus, frameCount, _ in
        let me = Unmanaged<DirectInput>.fromOpaque(refCon).takeUnretainedValue()
        guard let au = me.unit, let buf = me.scratch, frameCount <= buf.frameCapacity, let sink = me.sink else { return noErr }
        buf.frameLength = frameCount
        let status = AudioUnitRender(au, flags, timestamp, bus, frameCount, buf.mutableAudioBufferList)
        guard status == noErr, frameCount > 0, let chunk = me.chunk else { return status }
        // Append to the chunk, channel by channel; deliver whenever 100 ms is complete.
        var offset: UInt32 = 0
        let channels = Int(buf.format.channelCount)
        while offset < frameCount {
            let room = chunk.frameCapacity - chunk.frameLength
            let take = min(room, frameCount - offset)
            if let src = buf.floatChannelData, let dst = chunk.floatChannelData {
                for ch in 0..<channels {
                    memcpy(dst[ch] + Int(chunk.frameLength), src[ch] + Int(offset), Int(take) * MemoryLayout<Float>.size)
                }
            }
            chunk.frameLength += take
            offset += take
            if chunk.frameLength == chunk.frameCapacity {
                sink(chunk)              // the tap path deep-copies before it leaves this thread
                chunk.frameLength = 0
            }
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { stop(); throw DirectInputError.status(status, what) }
    }
}

enum DirectInputError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    var description: String {
        switch self { case let .status(s, what): return "direct input: \(what) failed (\(s))" }
    }
}
