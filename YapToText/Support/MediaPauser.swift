import AppKit
import CoreAudio

/// Pauses whatever media is playing when dictation starts and resumes it afterwards, by
/// synthesizing the keyboard Play/Pause media key. "Is anything playing?" is answered by
/// asking CoreAudio whether the default OUTPUT device is rendering right now (music, video,
/// a podcast - anything audible), so silence never gets an unwanted play command.
@MainActor
enum MediaPauser {
    private static var pausedByUs = false
    /// True when a resume is pending (we paused something and haven't resumed it yet).
    /// Lets the controller release voice processing ONLY when playback is actually about
    /// to come back - releasing it unconditionally suppressed every VP prewarm and
    /// silently disabled noise reduction.
    static var isPendingResume: Bool { pausedByUs }
    /// Set once output is observed SILENT after our pause - proof the pause actually took.
    /// If output later reads "running" again, the user resumed playback themselves.
    private static var sawSilenceAfterPause = false

    static func pauseIfPlaying() {
        pausedByUs = false
        // Our OWN start/stop cues keep the output device "running" for a few seconds - that
        // false positive made the play/pause key fire with nothing playing, which STARTS
        // Music. If one of our sounds just played, trust silence over the device flag.
        guard Date().timeIntervalSince(Sound.lastPlayedAt) > 3 else { return }
        // Nothing playing? Then nothing to do - and, critically, nothing to "resume" later.
        guard outputIsRunning() else { return }
        guard sendPlayPause() else {
            yapdiag("media: play/pause event could not be posted; leaving playback alone")
            return
        }
        pausedByUs = true
        sawSilenceAfterPause = false
        // VERIFY over several beats: many players keep their output unit "running" for a
        // few seconds after pausing (fade-outs, warm buffers), so a single early check
        // wrongly concluded the pause failed and the resume never fired. Sample a few
        // times; the first silent reading proves the pause took.
        for delay in [0.8, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard pausedByUs, !sawSilenceAfterPause else { return }
                if !outputIsRunning() {
                    sawSilenceAfterPause = true
                    yapdiag("media: pause verified (output silent at +\(delay)s)")
                }
            }
        }
        yapdiag("media: paused playback for dictation")
    }

    static func resumeIfPaused() {
        guard pausedByUs else { return }
        pausedByUs = false
        // Skip ONLY when the pause verifiably took (silence was observed) and output is
        // running again - that means the user resumed playback themselves mid-dictation,
        // and sending the key would pause it. A warm-but-paused output unit that never
        // read silent must NOT block the resume (that was the "never resumes" bug).
        if outputIsRunning(), sawSilenceAfterPause {
            yapdiag("media: playback already running again; skipping resume")
            return
        }
        if sendPlayPause() {
            yapdiag("media: resumed playback after dictation")
        } else {
            yapdiag("media: resume event could not be posted")
        }
    }

    /// True when some OTHER app is actively rendering audio output. The naive
    /// DeviceIsRunningSomewhere check counted US: the warm-mic AVAudioEngine initializes an
    /// output unit even though we never play through it, so the device always read "running"
    /// and the play/pause key fired with nothing playing (starting Music out of nowhere).
    /// The per-process object list makes it exact: only foreign processes with live OUTPUT count.
    private static func outputIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &processes) == noErr else { return false }
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        for process in processes {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ourPID else { continue }
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(process, &runAddress, 0, nil, &runSize, &running) == noErr,
               running != 0 {
                // ONLY a process the Play/Pause key actually controls counts. Plenty of
                // apps render output without being "music" - voice chats, Electron apps,
                // notification sounds - and treating them as playback fired the media key
                // into MUSIC, toggling songs the user never started ("it pauses/resumes my
                // background music on its own"). Unknown renderers are ignored entirely.
                let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                if Self.mediaKeyPlayers.contains(bundle)
                    || Self.mediaKeyPlayerPrefixes.contains(where: { bundle.hasPrefix($0) }) {
                    yapdiag("media: playback running in \(bundle) (pid \(pid))")
                    return true
                }
                yapdiag("media: ignoring non-player output from \(bundle.isEmpty ? "pid \(pid)" : bundle)")
            }
        }
        return false
    }

    /// Apps the hardware Play/Pause key genuinely controls: real players and browsers
    /// (which register media sessions for YouTube etc.). Everything else that renders
    /// audio - calls, games, other tools - must never trigger the key.
    private static let mediaKeyPlayers: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.podcasts",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let mediaKeyPlayerPrefixes = ["com.apple.WebKit"]   // Safari's media renders in helpers

    /// Synthesize the hardware Play/Pause media key (NX_KEYTYPE_PLAY = 16).
    /// Returns false if either half of the key event could not be built or posted -
    /// callers must NOT assume playback state changed in that case.
    @discardableResult
    private static func sendPlayPause() -> Bool {
        func post(down: Bool) -> Bool {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
            let data1 = Int((16 << 16) | ((down ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = event.cgEvent else { return false }
            cg.post(tap: .cghidEventTap)
            return true
        }
        let downOK = post(down: true)
        let upOK = post(down: false)
        return downOK && upOK
    }
}
