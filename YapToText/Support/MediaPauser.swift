import AppKit
import CoreAudio

/// Pauses whatever media is playing when dictation starts and resumes it afterwards, by
/// synthesizing the keyboard Play/Pause media key. "Is anything playing?" is answered by
/// asking CoreAudio whether the default OUTPUT device is rendering right now (music, video,
/// a podcast - anything audible), so silence never gets an unwanted play command.
@MainActor
enum MediaPauser {
    private static var pausedByUs = false
    /// True when the pause was a direct AppleScript pause of Music (resume mirrors it).
    private static var pausedMusicDirectly = false
    /// True when a resume is pending (we paused something and haven't resumed it yet).
    /// Lets the controller release voice processing ONLY when playback is actually about
    /// to come back - releasing it unconditionally suppressed every VP prewarm and
    /// silently disabled noise reduction.
    static var isPendingResume: Bool { pausedByUs }
    /// Set once output is observed SILENT after our pause - proof the pause actually took.
    /// If output later reads "running" again, the user resumed playback themselves.
    private static var sawSilenceAfterPause = false
    /// The whitelisted players we key-paused this session (Music is handled separately).
    /// Resume verifies THESE come back; if they don't, the resume key was misrouted to
    /// some other app (a browser holding the Now Playing seat) and started it instead.
    private static var pausedPlayers: Set<String> = []

    static func pauseIfPlaying() {
        pausedByUs = false
        // Our OWN start/stop cues keep the output device "running" for a few seconds - that
        // false positive made the play/pause key fire with nothing playing, which STARTS
        // Music. If one of our sounds just played, trust silence over the device flag.
        guard Date().timeIntervalSince(Sound.lastPlayedAt) > 3 else { return }
        // MUSIC: asked directly and controlled directly - no media-key routing at all.
        // Its warm-while-paused output unit is excluded from the key path entirely.
        pausedMusicDirectly = false
        var playersBefore = runningPlayerBundles()
        if playersBefore.contains("com.apple.Music") {
            playersBefore.remove("com.apple.Music")
            // Asynchronous on purpose: dictation start NEVER waits on Apple Events.
            Task { @MainActor in
                if await musicIsActuallyPlaying(), await musicSet(playing: false) {
                    pausedByUs = true
                    pausedMusicDirectly = true
                    sawSilenceAfterPause = true   // AppleScript pause is definitive
                    yapdiag("media: paused Music directly")
                }
            }
        }
        // Everything else (browsers, Spotify): the key remains the only tool. Nothing
        // detected? Done - and critically, nothing to "resume" later.
        guard !playersBefore.isEmpty else { pausedPlayers = []; return }
        pausedPlayers = playersBefore
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
        //
        // MISFIRE UNDO: the media key is GLOBAL - macOS routes it to the system's Now
        // Playing app, which is not always the app we detected rendering (a browser tab
        // with a warm audio unit reads "running" while Music holds the Now Playing seat).
        // That routing STARTED paused music instead of pausing the browser (caught live:
        // "I hit transcribe and my music started playing"). If a player that was NOT
        // audible before the key is audible after it, the key started someone - send it
        // again immediately to undo, and stand down for this session.
        for delay in [0.3, 0.8, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard pausedByUs, !sawSilenceAfterPause else { return }
                let playersNow = runningPlayerBundles()
                let started = playersNow.subtracting(playersBefore)
                if !started.isEmpty {
                    yapdiag("media: key STARTED \(started.joined(separator: ",")) - undoing")
                    pausedByUs = false
                    _ = sendPlayPause()
                    return
                }
                if playersNow.isEmpty {
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
        if pausedMusicDirectly {
            pausedMusicDirectly = false
            Task { @MainActor in
                _ = await musicSet(playing: true)
                yapdiag("media: resumed Music directly")
            }
            return
        }
        // Skip ONLY when the pause verifiably took (silence was observed) and output is
        // running again - that means the user resumed playback themselves mid-dictation,
        // and sending the key would pause it. A warm-but-paused output unit that never
        // read silent must NOT block the resume (that was the "never resumes" bug).
        if outputIsRunning(), sawSilenceAfterPause {
            yapdiag("media: playback already running again; skipping resume")
            return
        }
        let target = pausedPlayers
        pausedPlayers = []
        guard sendPlayPause() else {
            yapdiag("media: resume event could not be posted")
            return
        }
        yapdiag("media: resume key sent (target \(target.isEmpty ? "none" : target.joined(separator: ",")))")
        // RESUME MISFIRE UNDO: the Play/Pause key is GLOBAL and routes to whatever holds the
        // system Now Playing seat, which is NOT always the app we paused. When it misroutes
        // it STARTS that app - the reported "a browser started playing when I ended
        // dictation". Verify the player WE paused is audibly back within a beat or two; if it
        // isn't, the key hit something else (often a browser, invisible to the output check),
        // so toggle once more to undo it. Erring toward silence is correct here: a media app
        // the user must un-pause by hand is far better than audio blasting unbidden.
        guard !target.isEmpty else { return }
        var attempt = 0
        func verifyResumed() {
            attempt += 1
            if !runningPlayerBundles().isDisjoint(with: target) {
                yapdiag("media: resume verified - \(target.joined(separator: ",")) playing again")
                return
            }
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { verifyResumed() }
            } else {
                yapdiag("media: target never resumed; resume key misrouted - undoing")
                _ = sendPlayPause()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { verifyResumed() }
    }

    /// True when some OTHER app is actively rendering audio output. The naive
    /// DeviceIsRunningSomewhere check counted US: the warm-mic AVAudioEngine initializes an
    /// output unit even though we never play through it, so the device always read "running"
    /// and the play/pause key fired with nothing playing (starting Music out of nowhere).
    /// The per-process object list makes it exact: only foreign processes with live OUTPUT count.
    private static func outputIsRunning() -> Bool {
        !runningPlayerBundles().isEmpty
    }

    /// The bundle ids of every WHITELISTED player currently rendering audio output.
    /// (See outputIsRunning's history for why only known players count.)
    private static func runningPlayerBundles() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &processes) == noErr else { return [] }
        var found: Set<String> = []
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
                    found.insert(bundle)
                } else {
                    yapdiag("media: ignoring non-player output from \(bundle.isEmpty ? "pid \(pid)" : bundle)")
                }
            }
        }
        return found
    }

    /// Music's REAL player state via Apple Events - the only reliable signal. The warm
    /// output unit reads "running" while Music is paused, which is what fired the media
    /// key into a paused player and STARTED it. Guarded so it never launches Music.
    /// Apple Events BLOCK the calling thread (first consent prompt, busy Music) - a
    /// synchronous call from the main thread froze the whole app at dictation start
    /// (caught live via sample: 2+ minutes inside AESendMessage). Every script therefore
    /// runs on a background thread with an AppleScript-side timeout as the backstop.
    nonisolated private static func runMusicScript(_ body: String) async -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
        else { return nil }
        let source = "with timeout of 2 seconds\ntell application \"Music\" to \(body)\nend timeout"
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error { yapdiag("media: Music script failed \(error)"); return nil }
            return result?.stringValue ?? ""
        }.value
    }

    private static func musicIsActuallyPlaying() async -> Bool {
        await runMusicScript("get player state as string") == "playing"
    }

    private static func musicSet(playing: Bool) async -> Bool {
        await runMusicScript(playing ? "play" : "pause") != nil
    }

    /// Apps the hardware Play/Pause key genuinely controls: real players and browsers
    /// (which register media sessions for YouTube etc.). Everything else that renders
    /// audio - calls, games, other tools - must never trigger the key.
    private static let mediaKeyPlayers: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.podcasts",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
    ]
    // Browsers are OFF the list on purpose: their GPU/media helpers keep an output unit
    // warm around the clock (probed live: com.apple.WebKit.GPU rendering with nothing
    // playing), so "browser output running" carries no information - and firing the
    // global key on that noise is exactly what kept starting paused Music. The cost is
    // that browser video no longer auto-pauses; the win is the key can no longer fire
    // into silence.
    private static let mediaKeyPlayerPrefixes: [String] = []

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
