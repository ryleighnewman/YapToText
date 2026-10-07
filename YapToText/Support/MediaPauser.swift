import AppKit
import ApplicationServices
import CoreAudio
import IOKit.pwr_mgt

/// Pauses whatever media is playing when dictation starts and resumes it afterwards.
///
/// Music is asked and controlled directly over AppleScript. Every other player can only be
/// reached through the keyboard Play/Pause media key, which TOGGLES whichever app holds the
/// system's Now Playing seat, so the key may only ever fire at something that is really
/// playing. "Really playing" comes from power assertions: a media player holds one exactly
/// while it plays (QuickTime's appears ~0.3 s after play and drops ~2 s after pause). A running
/// audio OUTPUT is no proof on its own: AVFoundation players keep it running for ~7 s after a
/// pause, and a paused video read as "playing" is exactly what the key then STARTED ("it
/// resumes my paused QuickTime video when I start dictating", 2026-09-28). Players that take
/// no assertion still fall back to the output check.
@MainActor
enum MediaPauser {
    /// What showed that a source was playing. An assertion is proof; a running output unit
    /// is only a hint, because paused players keep it warm for a few seconds.
    private enum Evidence { case assertion, output }

    private static var pausedByUs = false
    /// True when the pause was a direct AppleScript pause of Music (resume mirrors it).
    private static var pausedMusicDirectly = false
    /// True when a resume is pending (we paused something and haven't resumed it yet).
    /// Lets the controller release voice processing ONLY when playback is actually about
    /// to come back - releasing it unconditionally suppressed every VP prewarm and
    /// silently disabled noise reduction.
    static var isPendingResume: Bool { pausedByUs }
    /// Every source we key-paused was later seen stopped: proof the pause took. After that,
    /// a paused source playing again means the user resumed it themselves.
    private static var pauseVerified = false
    /// The sources we key-paused this session, keyed as in playingSources().
    private static var pausedSources: [String: Evidence] = [:]
    /// Bumped by every pause and resume, so checks still pending from an earlier dictation
    /// stand down instead of acting on this one.
    private static var generation = 0

    static func pauseIfPlaying() {
        generation += 1
        let session = generation
        pausedByUs = false
        pausedMusicDirectly = false
        pauseVerified = false
        pausedSources = [:]
        // Our OWN start/stop cues keep the output device "running" for a few seconds - that
        // false positive made the play/pause key fire with nothing playing, which STARTS
        // Music. If one of our sounds just played, trust silence over the device flag.
        guard Date().timeIntervalSince(Sound.lastPlayedAt) > 3 else { return }
        // MUSIC: asked directly and controlled directly - no media-key routing at all. Its
        // output unit stays warm while it is paused, so its output proves nothing either way.
        guard musicOutputRunning() else {
            pauseByKey(session: session, musicWasRunning: false)
            return
        }
        // Asynchronous on purpose: dictation start NEVER waits on Apple Events.
        Task { @MainActor in
            let musicPlaying = await musicIsActuallyPlaying()
            guard session == generation else { return }
            guard musicPlaying else {
                pauseByKey(session: session, musicWasRunning: true)
                return
            }
            // Playing Music almost certainly holds the Now Playing seat, so the key would land
            // on Music rather than on any other player: pause Music alone, directly.
            if await musicSet(playing: false), session == generation {
                pausedByUs = true
                pausedMusicDirectly = true
                yapdiag("media: paused Music directly")
            }
        }
    }

    /// Pauses what is proven to be playing with the Play/Pause key (the only tool for
    /// everything but Music), then watches that the key paused it and started nothing else.
    private static func pauseByKey(session: Int, musicWasRunning: Bool) {
        // Nothing proven to be playing? Done - and critically, nothing to "resume" later.
        let before = playingSources()
        guard !before.isEmpty else { return }
        guard sendPlayPause() else {
            yapdiag("media: play/pause event could not be posted; leaving playback alone")
            return
        }
        pausedByUs = true
        pausedSources = before
        yapdiag("media: paused playback for dictation (\(describe(before)))")
        if musicWasRunning {
            // Paused Music's warm output cannot show whether the key started it: ask Music.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard session == generation, pausedByUs, await musicIsActuallyPlaying(),
                      session == generation else { return }
                yapdiag("media: key STARTED Music - pausing it again and leaving the rest alone")
                pausedByUs = false
                pausedSources = [:]
                _ = await musicSet(playing: false)
            }
        }
        // VERIFY over several beats: a player's assertion drops about 2 s after it pauses and
        // a warm output unit later still, so a single early check wrongly concluded the pause
        // failed. The first reading with every paused source stopped proves the pause took.
        //
        // MISFIRE UNDO: the media key is GLOBAL - macOS routes it to the system's Now
        // Playing app, which is not always the one we saw playing. That routing STARTED
        // paused music instead of pausing the browser (caught live: "I hit transcribe and my
        // music started playing"). If a source that was NOT playing before the key is playing
        // after it, the key started someone - send it again immediately to undo, and stand
        // down for this session.
        let checks = [0.3, 0.8, 1.5, 2.2, 3.0, 4.0, 5.0]
        for delay in checks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard session == generation, pausedByUs, !pauseVerified else { return }
                let now = playingSources()
                var started = Set(now.keys).subtracting(before.keys)
                if !musicWasRunning, musicOutputRunning() { started.insert("com.apple.Music") }
                if !started.isEmpty {
                    yapdiag("media: key STARTED \(started.sorted().joined(separator: ",")) - undoing")
                    pausedByUs = false
                    pausedSources = [:]
                    _ = sendPlayPause()
                    return
                }
                let stillPlaying = before.filter { isPlaying($0.key, provenBy: $0.value, in: now) }
                if stillPlaying.isEmpty {
                    pauseVerified = true
                    yapdiag("media: pause verified at +\(delay)s")
                } else if delay == checks.last, stillPlaying.values.contains(.assertion) {
                    // A player that PROVED it was playing still is, seconds later: the key did
                    // not pause it. Either it went to another app, or it toggled a player that
                    // was paused a moment before dictation and whose assertion had not dropped
                    // yet, starting it. Either way the key changed the wrong thing: undo it.
                    yapdiag("media: \(stillPlaying.keys.sorted().joined(separator: ",")) still playing after the key - undoing")
                    pausedByUs = false
                    pausedSources = [:]
                    _ = sendPlayPause()
                }
            }
        }
    }

    static func resumeIfPaused() {
        generation += 1
        let session = generation
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
        let targets = pausedSources
        pausedSources = [:]
        let before = playingSources()
        // Skip ONLY when the pause verifiably took and a paused source is playing again - the
        // user resumed it themselves mid-dictation, and the key would pause it. An unverified
        // pause must NOT block the resume: a warm output unit, or an assertion still inside its
        // ~2 s drop after a short dictation, looks like playback (that was the "never resumes"
        // bug).
        if pauseVerified, targets.contains(where: { isPlaying($0.key, provenBy: $0.value, in: before) }) {
            yapdiag("media: playback already running again; skipping resume")
            return
        }
        guard sendPlayPause() else {
            yapdiag("media: resume event could not be posted")
            return
        }
        yapdiag("media: resume key sent (target \(targets.isEmpty ? "none" : describe(targets)))")
        // RESUME MISFIRE UNDO: the Play/Pause key is GLOBAL and routes to whatever holds the
        // system Now Playing seat, which is NOT always the app we paused. When it misroutes
        // it STARTS that app - the reported "a browser started playing when I ended
        // dictation". Verify the player WE paused is back within a beat or two; if it isn't,
        // the key hit something else, so toggle once more to undo it. Erring toward silence is
        // correct here: a media app the user must un-pause by hand is far better than audio
        // blasting unbidden.
        guard !targets.isEmpty else { return }
        var attempt = 0
        func verifyResumed() {
            guard session == generation else { return }
            attempt += 1
            let now = playingSources()
            if targets.keys.contains(where: { now[$0] != nil }) {
                yapdiag("media: resume verified - \(targets.keys.sorted().joined(separator: ",")) playing again")
                return
            }
            let started = Set(now.keys).subtracting(before.keys)
            if !started.isEmpty || attempt >= 4 {
                yapdiag("media: target never resumed; resume key misrouted\(started.isEmpty ? "" : " to \(started.sorted().joined(separator: ","))") - undoing")
                _ = sendPlayPause()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { verifyResumed() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { verifyResumed() }
    }

    /// Whether a source still plays. One that proved itself with an assertion is judged by
    /// the assertion alone, since its output unit stays warm for seconds after a pause.
    private static func isPlaying(_ key: String, provenBy evidence: Evidence, in now: [String: Evidence]) -> Bool {
        evidence == .assertion ? now[key] == .assertion : now[key] != nil
    }

    private static func describe(_ sources: [String: Evidence]) -> String {
        sources.map { "\($0.key) by \($0.value == .assertion ? "assertion" : "output")" }
            .sorted().joined(separator: ", ")
    }

    /// Everything playing right now that the Play/Pause key controls, keyed by bundle id, or
    /// "WebKit#pid" for web media, with what proved it. Music is left out: it is asked directly.
    private static func playingSources() -> [String: Evidence] {
        let outputs = pidsRunningOutput()
        let assertions = playbackAssertions()
        var found: [String: Evidence] = [:]
        for pid in outputs.union(assertions.map { Set($0.keys) } ?? []) {
            let held = assertions?[pid] ?? []
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let name = bundle.isEmpty ? (held.first?.process ?? "") : bundle
            if bundle == "com.apple.Music" { continue }
            if mediaKeyPlayers.contains(bundle) {
                let coreMedia = coreMediaPlayers.contains(bundle)
                if coreMedia ? held.contains(where: \.isCoreMediaPlayback) : !held.isEmpty {
                    found[bundle] = .assertion
                    yapdiag("media: playback running in \(bundle) (pid \(pid))")
                } else if outputs.contains(pid) {
                    if coreMedia, assertions != nil {
                        yapdiag("media: \(bundle) output is warm but it is not playing; leaving it alone")
                    } else {
                        found[bundle] = .output
                        yapdiag("media: playback running in \(bundle) (pid \(pid)), by its output")
                    }
                }
                continue
            }
            // Browsers keep an output unit warm around the clock, so their OUTPUT says nothing
            // (probed live: com.apple.WebKit.GPU rendering with nothing playing) - firing the key
            // on that noise is what kept starting paused Music. Their playback assertions are
            // exact: WebKit's media process (Safari, web apps, apps built on web views) holds
            // "CoreMedia Playback" only while media with sound plays, and Chromium browsers hold
            // "Playing audio".
            if chromiumBrowsers.contains(where: { bundle.hasPrefix($0) }),
               held.contains(where: { $0.name == "Playing audio" }) {
                found[bundle] = .assertion
                yapdiag("media: web audio playing in \(bundle) (pid \(pid))")
            } else if name.hasPrefix("com.apple.WebKit"), held.contains(where: { $0.name == "CoreMedia Playback" }) {
                found["WebKit#\(pid)"] = .assertion
                yapdiag("media: web media playing in \(name) (pid \(pid))")
            } else if outputs.contains(pid) {
                yapdiag("media: ignoring non-player output from \(name.isEmpty ? "pid \(pid)" : name)")
            }
        }
        return found
    }

    private static func musicOutputRunning() -> Bool {
        let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !music.isEmpty else { return false }
        return !pidsRunningOutput().isDisjoint(with: music.map(\.processIdentifier))
    }

    /// The pids of every OTHER process rendering audio output right now. The naive
    /// DeviceIsRunningSomewhere check counted US: the warm-mic AVAudioEngine initializes an
    /// output unit even though we never play through it, so the device always read "running"
    /// and the play/pause key fired with nothing playing (starting Music out of nowhere).
    /// The per-process object list makes it exact.
    private static func pidsRunningOutput() -> Set<pid_t> {
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
        var found: Set<pid_t> = []
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
                found.insert(pid)
            }
        }
        return found
    }

    private struct Assertion {
        let name: String
        let process: String
        /// What CoreMedia (AVFoundation) holds while it plays: "CoreMedia Playback", or the
        /// video pipeline's display assertion "com.apple.coremedia.iq.ca.client-N".
        var isCoreMediaPlayback: Bool { name == "CoreMedia Playback" || name.hasPrefix("com.apple.coremedia.") }
    }

    /// powerd's sleep assertions by pid - the kind media players hold while they play. nil
    /// when the table cannot be read, so callers fall back to the output check.
    private static func playbackAssertions() -> [pid_t: [Assertion]]? {
        var table: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&table) == kIOReturnSuccess,
              let byPID = table?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            yapdiag("media: power assertions unreadable; judging by output alone")
            return nil
        }
        var result: [pid_t: [Assertion]] = [:]
        for (pid, entries) in byPID {
            let held = entries.compactMap { entry -> Assertion? in
                let type = (entry["AssertionTrueType"] ?? entry[kIOPMAssertionTypeKey as String]) as? String ?? ""
                guard sleepAssertionTypes.contains(type),
                      (entry[kIOPMAssertionLevelKey as String] as? Int ?? 0) != 0 else { return nil }
                return Assertion(name: entry[kIOPMAssertionNameKey as String] as? String ?? "",
                                 process: entry["Process Name"] as? String ?? "")
            }
            if !held.isEmpty { result[pid.int32Value] = held }
        }
        return result
    }

    private static let sleepAssertionTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    /// Music's REAL player state via Apple Events - the only reliable signal. The warm
    /// output unit reads "running" while Music is paused, which is what fired the media
    /// key into a paused player and STARTED it. Guarded so it never launches Music.
    /// Apple Events BLOCK the calling thread (first consent prompt, busy Music) - a
    /// synchronous call from the main thread froze the whole app at dictation start
    /// (caught live via sample: 2+ minutes inside AESendMessage). Every script therefore
    /// runs on a background thread with an AppleScript-side timeout as the backstop.
    /// The Automation (Apple Events) consent for Music, asked for ONCE per launch, with no
    /// timeout. The first script used to carry the 2 s AppleScript timeout into macOS's own
    /// consent dialog: the event was abandoned before the user could click Allow, so nothing
    /// was recorded and the dialog came back on every dictation ("it wants to access Music
    /// every time", 2026-09-16, six prompts in one minute, every one ending in -1712).
    /// noErr = allowed; -1743 = the user said no, and the scripts stay silent for the rest
    /// of the launch instead of asking again.
    nonisolated private static let permissionLock = NSLock()
    nonisolated(unsafe) private static var musicPermission: OSStatus?
    nonisolated private static func musicAutomationAllowed() async -> Bool {
        permissionLock.lock(); let cached = musicPermission; permissionLock.unlock()
        if let cached { return cached == noErr }
        let status: OSStatus = await Task.detached(priority: .userInitiated) { () -> OSStatus in
            let bundleID = "com.apple.Music"
            var target = AEAddressDesc()
            let made = bundleID.withCString { ptr in
                AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
            }
            guard made == noErr else { return OSStatus(made) }
            defer { AEDisposeDesc(&target) }
            // Blocks while the consent dialog is up; that is the point.
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
        }.value
        permissionLock.lock(); musicPermission = status; permissionLock.unlock()
        yapdiag("media: Music automation permission \(status == noErr ? "granted" : "status \(status)")")
        return status == noErr
    }

    nonisolated private static func runMusicScript(_ body: String) async -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
        else { return nil }
        guard await musicAutomationAllowed() else { return nil }
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

    /// Apps the hardware Play/Pause key genuinely controls. Everything else that renders
    /// audio - calls, games, other tools - must never trigger the key. (Music is asked
    /// directly; browsers are matched by their playback assertions in playingSources.)
    private static let mediaKeyPlayers: Set<String> = [
        "com.spotify.client", "com.apple.TV", "com.apple.podcasts",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
    ]
    /// AVFoundation players: they hold a CoreMedia assertion exactly while they play, and
    /// their output unit stays warm for seconds after a pause, so only the assertion counts.
    private static let coreMediaPlayers: Set<String> = ["com.apple.QuickTimePlayerX", "com.apple.TV"]
    private static let chromiumBrowsers = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

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
