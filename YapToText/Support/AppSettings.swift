import Foundation
import Observation

enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable {
    case appleSpeech
    case whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appleSpeech: return "Apple Speech (on-device)"
        case .whisper: return "Downloaded model (Whisper / others)"
        }
    }
}

enum InsertionMethod: String, Codable, CaseIterable, Identifiable {
    case paste
    case type
    case clipboardOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paste: return "Paste (fast, recommended)"
        case .type: return "Type character-by-character"
        case .clipboardOnly: return "Copy to clipboard only"
        }
    }
}

enum HotkeyBehavior: String, Codable, CaseIterable, Identifiable {
    case toggle
    case pushToTalk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toggle: return "Toggle (press to start, press to stop)"
        case .pushToTalk: return "Push-to-talk (hold to record)"
        }
    }
}

enum PanelPosition: String, Codable, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter
    case nearMenuBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .nearMenuBar: return "Near menu bar"
        }
    }
}

enum PanelAnimation: String, Codable, CaseIterable, Identifiable {
    case none
    case fade
    case scale
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .scale: return "Scale + fade"
        }
    }
}

enum ModifierTrigger: String, Codable, CaseIterable, Identifiable {
    case off
    case toggle
    case pushToTalk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .toggle: return "Tap to start / stop"
        case .pushToTalk: return "Hold to talk"
        }
    }
}

enum PanelStyle: String, Codable, CaseIterable, Identifiable {
    case expanded
    case compact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expanded: return "Expanded (live transcript)"
        case .compact: return "Compact (one row)"
        }
    }
}

enum PanelSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    /// Panel width in points; the height follows the content.
    var width: CGFloat {
        switch self {
        case .small: return 300
        case .medium: return 380
        case .large: return 464
        }
    }
    /// Scale applied to fonts and the waveform relative to the medium baseline.
    var scale: CGFloat { width / 380 }
}

enum HistoryRetention: String, Codable, CaseIterable, Identifiable {
    case all
    case last500
    case last100
    case sessionOnly
    case off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Keep everything"
        case .last500: return "Keep last 500"
        case .last100: return "Keep last 100"
        case .sessionOnly: return "This session only"
        case .off: return "Don't save history"
        }
    }
    /// Cap for persisted records, or nil for unbounded.
    var limit: Int? {
        switch self {
        case .all, .sessionOnly: return nil
        case .last500: return 500
        case .last100: return 100
        case .off: return 0
        }
    }
    var persists: Bool { self != .sessionOnly && self != .off }
}

/// Central, observable user preferences. Persisted as JSON in UserDefaults; every
/// mutation autosaves. UI binds to this directly.
@Observable
final class AppSettings {
    // Core
    var engine: TranscriptionEngineKind { didSet { save() } }
    var localeIdentifier: String { didSet { save() } }
    var insertionMethod: InsertionMethod { didSet { save() } }
    var hotkey: KeyCombo { didSet { save() } }
    var hotkeyBehavior: HotkeyBehavior { didSet { save() } }
    var pauseHotkey: KeyCombo? { didSet { save() } }
    var cycleModeHotkey: KeyCombo? { didSet { save() } }
    var switcherHotkey: KeyCombo? { didSet { save() } }
    var aiActionsHotkey: KeyCombo? { didSet { save() } }
    var historyPaletteHotkey: KeyCombo? { didSet { save() } }
    var rightCommandTrigger: ModifierTrigger { didSet { save() } }
    var rightCommandSpaceSwitcher: Bool { didSet { save() } }   // Right Command + Space opens the mode switcher
    var cancelOnDoubleEscape: Bool { didSet { save() } }
    var activeModeID: UUID { didSet { save() } }
    var perAppModeOverrides: [String: UUID] { didSet { save() } }

    // You - fed to the AI so it can sign emails etc. with your real name instead of "[Your Name]".
    var userName: String { didSet { save() } }

    // Output
    var autoInsert: Bool { didSet { save() } }
    var restoreClipboard: Bool { didSet { save() } }
    var trimTrailingNewlines: Bool { didSet { save() } }
    var appendSpaceAfterInsert: Bool { didSet { save() } }
    /// Energy: seconds of idle before the loaded speech/AI models are unloaded from memory.
    /// 0 = right after each dictation (max energy saving), -1 = keep loaded (max speed).
    var modelCooldownSeconds: Int { didSet { save() } }
    var aiCleanupEnabled: Bool { didSet { save() } }   // master switch for the AI polish stage
    var inputGain: Double { didSet { save() } }            // manual mic boost, 1.0 = off
    var autoAmplifyInput: Bool { didSet { save() } }       // AGC: auto-boost quiet speech

    // Recording behavior
    var silenceTimeout: Double { didSet { save() } }        // seconds of silence to auto-stop; 0 = off
    var maxRecordingSeconds: Double { didSet { save() } }   // hard cap; 0 = off

    // Models
    var selectedSpeechModelID: String { didSet { save() } }
    var selectedLanguageModelID: String { didSet { save() } }

    // Feedback / panel
    var showMenuBarIcon: Bool { didSet { save() } }
    var showDockIcon: Bool { didSet { save() } }
    /// The Home page's "one key is all it takes" note, dismissible via its close button.
    var hasDismissedHomeNote: Bool { didSet { save() } }
    /// UID of the chosen audio input device; nil follows the system default.
    var inputDeviceUID: String? { didSet { save() } }
    var showRecordingPanel: Bool { didSet { save() } }
    var livePreviewEnabled: Bool { didSet { save() } }   // periodic Whisper partials while recording
    var panelStyle: PanelStyle { didSet { save() } }
    var panelPosition: PanelPosition { didSet { save() } }
    var panelSize: PanelSize { didSet { save() } }
    var panelAnimation: PanelAnimation { didSet { save() } }
    var playSounds: Bool { didSet { save() } }

    // History + audio
    var saveHistory: Bool { didSet { save() } }
    var historyRetention: HistoryRetention { didSet { save() } }
    var clearHistoryOnQuit: Bool { didSet { save() } }
    var saveAudio: Bool { didSet { save() } }               // keep the audio recording with each dictation
    var autoDeleteDays: Int { didSet { save() } }           // delete history + audio older than N days; 0 = never

    // System
    var launchAtLogin: Bool { didSet { save() } }
    var offeredModelDownloads: Bool { didSet { save() } }
    var hasCompletedOnboarding: Bool { didSet { save() } }

    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let defaultsKey = "com.ryleighnewman.YapToText.settings"

    struct Snapshot: Codable {
        var engine: TranscriptionEngineKind
        var localeIdentifier: String
        var insertionMethod: InsertionMethod
        var hotkey: KeyCombo
        var hotkeyBehavior: HotkeyBehavior
        var pauseHotkey: KeyCombo?
        var cycleModeHotkey: KeyCombo?
        var switcherHotkey: KeyCombo?
        var aiActionsHotkey: KeyCombo?
        var historyPaletteHotkey: KeyCombo?
        var rightCommandTrigger: ModifierTrigger?
        var rightCommandSpaceSwitcher: Bool?
        var cancelOnDoubleEscape: Bool?
        var activeModeID: UUID
        var perAppModeOverrides: [String: UUID]
        var userName: String?
        var autoInsert: Bool
        var restoreClipboard: Bool
        var trimTrailingNewlines: Bool
        var appendSpaceAfterInsert: Bool?
        var modelCooldownSeconds: Int?
        var aiCleanupEnabled: Bool?
        var inputGain: Double?
        var autoAmplifyInput: Bool?
        var silenceTimeout: Double
        var maxRecordingSeconds: Double
        var selectedSpeechModelID: String
        var selectedLanguageModelID: String
        var showMenuBarIcon: Bool?
        var showDockIcon: Bool?
        var hasDismissedHomeNote: Bool?
        var inputDeviceUID: String?
        var showRecordingPanel: Bool
        var livePreviewEnabled: Bool?
        var panelStyle: PanelStyle?
        var panelPosition: PanelPosition
        var panelSize: PanelSize?
        var panelAnimation: PanelAnimation
        var playSounds: Bool
        var saveHistory: Bool
        var historyRetention: HistoryRetention
        var clearHistoryOnQuit: Bool
        var saveAudio: Bool
        var autoDeleteDays: Int
        var launchAtLogin: Bool
        var offeredModelDownloads: Bool?
        var hasCompletedOnboarding: Bool
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        let loaded: Snapshot? = {
            guard let data = defaults.data(forKey: AppSettings.defaultsKey) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }()
        engine = loaded?.engine ?? .appleSpeech
        localeIdentifier = loaded?.localeIdentifier ?? Locale.current.identifier
        insertionMethod = loaded?.insertionMethod ?? .paste
        hotkey = loaded?.hotkey ?? .default
        hotkeyBehavior = loaded?.hotkeyBehavior ?? .toggle
        pauseHotkey = loaded?.pauseHotkey
        cycleModeHotkey = loaded?.cycleModeHotkey
        switcherHotkey = loaded?.switcherHotkey
        aiActionsHotkey = loaded?.aiActionsHotkey
        historyPaletteHotkey = loaded?.historyPaletteHotkey
        rightCommandTrigger = loaded?.rightCommandTrigger ?? .toggle
        rightCommandSpaceSwitcher = loaded?.rightCommandSpaceSwitcher ?? true   // Right ⌘ is the default trigger
        cancelOnDoubleEscape = loaded?.cancelOnDoubleEscape ?? true   // Esc closes/cancels the panel by default
        activeModeID = loaded?.activeModeID ?? BuiltInModes.rawTranscriptionID   // Raw is the default: instant, and Whisper alone is already clean
        perAppModeOverrides = loaded?.perAppModeOverrides ?? [:]
        userName = loaded?.userName ?? ""
        autoInsert = loaded?.autoInsert ?? true
        restoreClipboard = loaded?.restoreClipboard ?? true
        trimTrailingNewlines = loaded?.trimTrailingNewlines ?? true
        appendSpaceAfterInsert = loaded?.appendSpaceAfterInsert ?? true
        modelCooldownSeconds = loaded?.modelCooldownSeconds ?? 120
        aiCleanupEnabled = loaded?.aiCleanupEnabled ?? true
        inputGain = loaded?.inputGain ?? 1.0
        autoAmplifyInput = loaded?.autoAmplifyInput ?? true
        silenceTimeout = loaded?.silenceTimeout ?? 0
        maxRecordingSeconds = loaded?.maxRecordingSeconds ?? 0
        selectedSpeechModelID = loaded?.selectedSpeechModelID ?? "whisper-large-v3-turbo"   // superwhisper's "Ultra V3 Turbo"
        selectedLanguageModelID = loaded?.selectedLanguageModelID ?? "phi-3.5-mini-instruct-q4"   // the bundled Phi is the DEFAULT cleanup brain - fully self-contained, no Apple Intelligence dependency
        showMenuBarIcon = loaded?.showMenuBarIcon ?? true
        showDockIcon = loaded?.showDockIcon ?? true
        hasDismissedHomeNote = loaded?.hasDismissedHomeNote ?? false
        inputDeviceUID = loaded?.inputDeviceUID
        showRecordingPanel = loaded?.showRecordingPanel ?? true
        livePreviewEnabled = loaded?.livePreviewEnabled ?? true
        panelStyle = loaded?.panelStyle ?? .expanded
        panelPosition = loaded?.panelPosition ?? .bottomCenter
        panelSize = loaded?.panelSize ?? .medium
        panelAnimation = loaded?.panelAnimation ?? .scale
        playSounds = loaded?.playSounds ?? false   // quiet by default; opt in to chimes
        saveHistory = loaded?.saveHistory ?? true
        historyRetention = loaded?.historyRetention ?? .last500
        clearHistoryOnQuit = loaded?.clearHistoryOnQuit ?? false
        saveAudio = loaded?.saveAudio ?? true
        autoDeleteDays = loaded?.autoDeleteDays ?? 30
        launchAtLogin = loaded?.launchAtLogin ?? false
        offeredModelDownloads = loaded?.offeredModelDownloads ?? false
        hasCompletedOnboarding = loaded?.hasCompletedOnboarding ?? false
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            engine: engine, localeIdentifier: localeIdentifier, insertionMethod: insertionMethod,
            hotkey: hotkey, hotkeyBehavior: hotkeyBehavior, pauseHotkey: pauseHotkey, cycleModeHotkey: cycleModeHotkey,
            switcherHotkey: switcherHotkey, aiActionsHotkey: aiActionsHotkey,
            historyPaletteHotkey: historyPaletteHotkey, rightCommandTrigger: rightCommandTrigger, rightCommandSpaceSwitcher: rightCommandSpaceSwitcher,
            cancelOnDoubleEscape: cancelOnDoubleEscape,
            activeModeID: activeModeID, perAppModeOverrides: perAppModeOverrides, userName: userName,
            autoInsert: autoInsert, restoreClipboard: restoreClipboard, trimTrailingNewlines: trimTrailingNewlines,
            appendSpaceAfterInsert: appendSpaceAfterInsert, modelCooldownSeconds: modelCooldownSeconds, aiCleanupEnabled: aiCleanupEnabled,
            inputGain: inputGain, autoAmplifyInput: autoAmplifyInput,
            silenceTimeout: silenceTimeout, maxRecordingSeconds: maxRecordingSeconds,
            selectedSpeechModelID: selectedSpeechModelID, selectedLanguageModelID: selectedLanguageModelID,
            showMenuBarIcon: showMenuBarIcon, showDockIcon: showDockIcon,
            hasDismissedHomeNote: hasDismissedHomeNote, inputDeviceUID: inputDeviceUID,
            showRecordingPanel: showRecordingPanel, livePreviewEnabled: livePreviewEnabled, panelStyle: panelStyle, panelPosition: panelPosition, panelSize: panelSize, panelAnimation: panelAnimation,
            playSounds: playSounds, saveHistory: saveHistory, historyRetention: historyRetention,
            clearHistoryOnQuit: clearHistoryOnQuit, saveAudio: saveAudio, autoDeleteDays: autoDeleteDays,
            launchAtLogin: launchAtLogin, offeredModelDownloads: offeredModelDownloads,
            hasCompletedOnboarding: hasCompletedOnboarding)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: AppSettings.defaultsKey)
        }
    }
}
