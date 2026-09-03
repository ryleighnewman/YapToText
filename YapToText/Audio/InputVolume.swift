import Foundation
import CoreAudio

/// The Mac's own input volume for a microphone (the slider in System Settings > Sound >
/// Input). A low slider is the single biggest reason quiet speech transcribes badly: the
/// mic delivers the room and the voice at nearly the same level, and no gain applied
/// afterwards can separate them again. Read to warn; set only when the user asks.
enum InputVolume {
    /// 0...1, or nil when the device exposes no input volume control (many USB interfaces).
    static func read(deviceUID: String?) -> Float? {
        guard let id = deviceID(for: deviceUID) else { return nil }
        for element in candidateElements(id) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    /// Set every settable input channel to `value` (0...1). Returns true when at least one
    /// channel accepted it.
    @discardableResult
    static func set(_ value: Float, deviceUID: String?) -> Bool {
        guard let id = deviceID(for: deviceUID) else { return false }
        var written = false
        var v: Float32 = min(1, max(0, value))
        for element in candidateElements(id) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &address),
                  AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                written = true
            }
        }
        return written
    }

    /// Main element first, then the individual channels (some devices only expose those).
    private static func candidateElements(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    private static func deviceID(for uid: String?) -> AudioObjectID? {
        if let uid, let device = AudioInputDevices.device(forUID: uid) { return device.id }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }
}

import SwiftUI

/// Shown under the microphone controls when the Mac's own input slider is low. One line
/// of why, and the two ways out: let the app raise it, or open Sound settings.
struct InputVolumeNotice: View {
    @Environment(AppState.self) private var state
    @State private var volume: Float?
    @State private var raised = false
    private let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let volume, volume < 0.5 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.1")
                            .foregroundStyle(.orange)
                        Text("Your Mac's input volume is at \(Int((volume * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                    }
                    Text("At this level quiet speech reaches the app at almost the room's own level, and no boost afterwards can separate the two. Raising the input volume is the one change that helps most.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Raise to 80%") {
                            if InputVolume.set(0.8, deviceUID: state.settings.inputDeviceUID) { raised = true; refresh() }
                        }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                        Button("Open Sound Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                    }
                }
                .padding(.top, 2)
            } else if raised {
                Caption("Input volume raised. Try a quiet sentence.")
            }
        }
        .onAppear(perform: refresh)
        .onReceive(ticks) { _ in refresh() }
        .onChange(of: state.settings.inputDeviceUID) { refresh() }
    }

    private func refresh() {
        volume = InputVolume.read(deviceUID: state.settings.inputDeviceUID)
    }
}
