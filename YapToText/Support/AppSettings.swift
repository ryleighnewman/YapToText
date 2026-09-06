import Foundation
import Observation
import SwiftUI

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

/// What happens right after a dictation lands in a particular app. Chat apps and AI
/// assistants want the message SENT as soon as it is typed; the user picks the key that
/// sends there (Return in most, Command-Return in some), and the app presses it.
enum AfterInsertAction: String, Codable, CaseIterable, Identifiable {
    case none
    case returnKey
    case commandReturn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Nothing"
        case .returnKey: return "Press Return"
        case .commandReturn: return "Press \u{2318}Return"
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
    case center
    case topCenter
    case nearMenuBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .center: return "Center of screen"
        case .topCenter: return "Top center"
        case .nearMenuBar: return "Near menu bar"
        }
    }
    /// How the card pins inside its fixed window at each position.
    var cardAlignment: SwiftUI.Alignment {
        switch self {
        case .bottomCenter: return .bottom
        case .center: return .center
        case .topCenter, .nearMenuBar: return .top
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

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case capybara
    case microphone
    case waveform
    case bubble
    case dot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .capybara: return "Capybara"
        case .microphone: return "Microphone"
        case .waveform: return "Mini waveform"
        case .bubble: return "Speech bubble"
        case .dot: return "Minimal dot"
        }
    }
}

/// How the floating panel's glass is tinted. Always-on by default, mapped to the accent.
enum PanelTintStyle: String, Codable, CaseIterable, Identifiable {
    case off
    case accent
    case custom
    case rainbow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "None"
        case .accent: return "Match accent"
        case .custom: return "Custom color"
        case .rainbow: return "RGB"
        }
    }
}

extension AppSettings {
    /// The Quick Edit card's stock color (the app's purple preset): different from the
    /// dictation pop-up's accent-matched look on purpose.
    static let quickEditDefaultHex = "#BF5AF2"
}

/// How the pop-up WAVE is coloured - independent of the glass behind it.
enum WaveColorStyle: String, Codable, CaseIterable, Identifiable {
    case accent
    case custom
    case rgb
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accent: return "Match accent"
        case .custom: return "Custom color"
        case .rgb: return "RGB"
        }
    }
}

/// WHICH physical key is the primary dictation trigger. Right Command is the classic; any
/// of these bare modifier keys works through the same monitor.
enum PrimaryTriggerKey: Codable, Identifiable, Equatable, Hashable {
    case rightCommand
    case rightControl
    case leftControl
    case fnGlobe
    case rightOption
    case leftOption
    case rightShift
    case capsLock
    /// ANY other physical key - a letter, F-key, number pad key, whatever. Watched by a
    /// swallowing CGEvent tap, so the key stops typing and becomes the trigger.
    case custom(UInt16)

    /// The bare-modifier keys the flagsChanged monitor can watch (custom keys ride the
    /// event tap instead, so they don't belong in this list).
    static var allCases: [PrimaryTriggerKey] {
        [.rightCommand, .rightControl, .leftControl, .fnGlobe,
         .rightOption, .leftOption, .rightShift, .capsLock]
    }

    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .rightCommand: return "rightCommand"
        case .rightControl: return "rightControl"
        case .leftControl: return "leftControl"
        case .fnGlobe: return "fnGlobe"
        case .rightOption: return "rightOption"
        case .leftOption: return "leftOption"
        case .rightShift: return "rightShift"
        case .capsLock: return "capsLock"
        case .custom(let code): return "custom:\(code)"
        }
    }
    init?(rawValue: String) {
        switch rawValue {
        case "rightCommand": self = .rightCommand
        case "rightControl": self = .rightControl
        case "leftControl": self = .leftControl
        case "fnGlobe": self = .fnGlobe
        case "rightOption": self = .rightOption
        case "leftOption": self = .leftOption
        case "rightShift": self = .rightShift
        case "capsLock": self = .capsLock
        default:
            guard rawValue.hasPrefix("custom:"), let code = UInt16(rawValue.dropFirst(7)) else { return nil }
            self = .custom(code)
        }
    }
    /// Codable as the raw string, so existing saved settings decode unchanged.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PrimaryTriggerKey(rawValue: raw) ?? .rightCommand
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var isCustom: Bool { if case .custom = self { return true }; return false }

    var label: String {
        switch self {
        case .rightCommand: return "Right \u{2318}"
        case .rightControl: return "Right \u{2303}"
        case .leftControl: return "Left \u{2303}"
        case .fnGlobe: return "Fn \u{1F310}"
        case .rightOption: return "Right \u{2325}"
        case .leftOption: return "Left \u{2325}"
        case .rightShift: return "Right \u{21E7}"
        case .capsLock: return "\u{21EA} Caps Lock"
        case .custom(let code): return Self.keyName(code)
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .rightControl: return 62
        case .leftControl: return 59
        case .fnGlobe: return 63
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightShift: return 60
        case .capsLock: return 57
        case .custom(let code): return code
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand: return .command
        case .rightControl, .leftControl: return .control
        case .fnGlobe: return .function
        case .rightOption, .leftOption: return .option
        case .rightShift: return .shift
        case .capsLock: return .capsLock
        case .custom: return []
        }
    }
    var cgFlag: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightControl, .leftControl: return .maskControl
        case .fnGlobe: return .maskSecondaryFn
        case .rightOption, .leftOption: return .maskAlternate
        case .rightShift: return .maskShift
        case .capsLock: return .maskAlphaShift
        case .custom: return []
        }
    }

    /// Human name for a custom keycode (common keys mapped, everything else numbered).
    static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
            116: "Page Up", 121: "Page Down", 115: "Home", 119: "End", 114: "Help",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
            43: ",", 47: ".", 44: "/",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
            38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
            15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return names[code] ?? "Key \(code)"
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
    case mini
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expanded: return "Expanded (live transcript)"
        case .compact: return "Compact (one row)"
        case .mini: return "Mini (just the waveform)"
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
    /// Redo shortcut (unbound by default): erase the last inserted dictation, re-run it
    /// through its AI pipeline, and insert the fresh result in its place.
    var redoLastHotkey: KeyCombo? { didSet { save() } }
    var rightCommandTrigger: ModifierTrigger { didSet { save() } }
    var fnKeyTrigger: ModifierTrigger { didSet { save() } }   // the Fn/Globe key as a dictation trigger
    var rightCommandSpaceSwitcher: Bool { didSet { save() } }   // Right Command + Space opens the mode switcher
    var cancelOnDoubleEscape: Bool { didSet { save() } }
    var activeModeID: UUID { didSet { save() } }
    var perAppModeOverrides: [String: UUID] { didSet { save() } }

    // You - fed to the AI so it can sign emails etc. with your real name instead of "[Your Name]".
    var userName: String { didSet { save() } }

    // Output
    var autoInsert: Bool { didSet { save() } }
    /// Experimental: type finalized words at the cursor WHILE you speak (Raw-style sessions only;
    /// AI modes still deliver after cleanup). Needs Accessibility, works best with Apple Speech.
    var liveTyping: Bool { didSet { save() } }
    /// Say "scratch that" (or "replace X with Y") right after an insert to edit the text you
    /// just dictated instead of typing the phrase. Whole-utterance match only, 30s window.
    var quickEditDetection: Bool { didSet { save() } }
    /// Learn recurring fixes: suggest vocabulary replacements from patterns in your history.
    var smartDictionary: Bool { didSet { save() } }
    /// Quick Edit key: select text anywhere, hold Right Option, speak what to change
    /// ("capitalize this", "make it a question"), release to apply it with AI.
    var quickEditKeyEnabled: Bool { didSet { save() } }
    /// How the Quick Edit key fires - same choices as the dictation key (tap to
    /// start/stop, hold to talk, or off). Replaces the old on/off toggle.
    var quickEditTrigger: ModifierTrigger { didSet { save() } }
    /// Which physical key runs Quick Edit (hold over a selection, speak, release).
    var quickEditTriggerKey: PrimaryTriggerKey { didSet { save() } }
    /// Which physical key is the primary dictation trigger (behavior comes from
    /// `rightCommandTrigger`, kept under its historic name for settings compatibility).
    var primaryTriggerKey: PrimaryTriggerKey { didSet { save() } }
    /// Review before insert: finished text appears in an editable buffer first; Return inserts,
    /// Esc discards. For people who want to see what landed before it touches their document.
    var reviewBeforeInsert: Bool { didSet { save() } }
    /// Scope the review buffer to LONG dictations only (200+ characters) - short phrases
    /// auto-insert as usual; the ones where a silent wrong guess really hurts get a look first.
    var reviewLongTextOnly: Bool { didSet { save() } }
    /// Per-app insertion method pins for apps that hate simulated paste (or typing).
    /// Keyed by bundle identifier; wins over the mode's and the global method.
    var appInsertionOverrides: [String: InsertionMethod] { didSet { save() } }
    /// Per-app key pressed after a dictation is inserted (send the message). Empty = never.
    var appAfterInsert: [String: AfterInsertAction] { didSet { save() } }
    /// Pause whatever's playing (music, video) when dictation starts, resume when it ends.
    var pauseMediaDuringDictation: Bool { didSet { save() } }
    /// Digit mode-switching while dictating (press 1-9 to pick the post-processing mode).
    /// Off = number keys type normally during dictation.
    var digitModeSwitching: Bool { didSet { save() } }
    /// On: the pop-up returns to its chosen Position for every dictation. Off (the default):
    /// it stays wherever you dragged it, across dictations and launches.
    var panelSnapsBack: Bool { didSet { save() } }
    /// Where the pop-up was last dragged to (screen points, window origin). nil = never moved.
    var panelDraggedX: Double? { didSet { save() } }
    var panelDraggedY: Double? { didSet { save() } }
    /// Where the Quick Edit pop-up opens, and where it was last dragged to (stays there).
    var quickEditPosition: PanelPosition { didSet { save() } }
    var quickEditSnapsBack: Bool { didSet { save() } }
    /// The last non-off Quick Edit trigger, so the on/off switch brings back Hold to talk
    /// instead of silently resetting to tap.
    var quickEditPreferredTrigger: ModifierTrigger { didSet { save() } }
    var quickEditDraggedX: Double? { didSet { save() } }
    var quickEditDraggedY: Double? { didSet { save() } }
    /// The last app version whose What's New sheet was shown (nil = never). Existing users see
    /// the sheet once per version; fresh installs get stamped at onboarding so they never do.
    var lastSeenWhatsNewVersion: String? { didSet { save() } }
    /// Optional color for the menu bar waveform visualizer. nil = follow the accent color;
    /// only applies while "Colored status in the menu bar" is on.
    var visualizerColorHex: String? { didSet { save() } }
    var restoreClipboard: Bool { didSet { save() } }
    /// Context-aware insertion: adapt capitalization/spacing to the text around the cursor.
    var adaptToSurroundings: Bool { didSet { save() } }
    /// Escape cancels a dictation immediately by default; this opt-in requires a second
    /// press within 0.6s (for people who fat-finger Esc).
    var doubleEscapeToCancel: Bool { didSet { save() } }
    /// The AI model Quick Edit uses. nil = the same model as dictation cleanup.
    var quickEditModelID: String? { didSet { save() } }
    var trimTrailingNewlines: Bool { didSet { save() } }
    var appendSpaceAfterInsert: Bool { didSet { save() } }
    /// Energy: seconds of idle before the loaded speech/AI models are unloaded from memory.
    /// 0 = right after each dictation (max energy saving), -1 = keep loaded (max speed).
    var modelCooldownSeconds: Int { didSet { save() } }
    var aiCleanupEnabled: Bool { didSet { save() } }   // master switch for the AI polish stage
    /// Auto mode: read each dictation and pick the post-processor automatically
    /// (email -> Email, casual chat -> as spoken, everything else -> Clean Up).
    var autoContextMode: Bool { didSet { save() } }
    var inputGain: Double { didSet { save() } }            // manual mic boost, 1.0 = off
    var autoAmplifyInput: Bool { didSet { save() } }       // AGC: auto-boost quiet speech
    var reduceBackgroundNoise: Bool { didSet { save() } }  // software noise conditioning (AUVoiceIO is permanently off - it wrecked system playback)
    /// Keep the input route running for a few minutes after each dictation, so the next one
    /// captures from the very first syllable (a cold route eats the first 1-2 seconds).
    var keepMicWarm: Bool { didSet { save() } }
    /// How long (minutes) the warm input route is held after a dictation before it's released.
    var micWarmMinutes: Double { didSet { save() } }

    // Recording behavior
    var silenceTimeout: Double { didSet { save() } }        // seconds of silence to auto-stop; 0 = off
    var maxRecordingSeconds: Double { didSet { save() } }   // hard cap; 0 = off

    // Models
    var selectedSpeechModelID: String { didSet { save() } }
    var selectedLanguageModelID: String { didSet { save() } }
    // Energy-adaptive models: when enabled, the speech model follows the power source.
    // nil pluggen/battery IDs fall back to selectedSpeechModelID.
    var energyAdaptive: Bool { didSet { save() } }
    var speechModelPluggedID: String? { didSet { save() } }
    var speechModelBatteryID: String? { didSet { save() } }
    // The cleanup model follows the power source too: a 2.3GB local LLM is the single
    // heaviest thing the app runs, so "lighter on battery" matters most here.
    var languageModelPluggedID: String? { didSet { save() } }
    var languageModelBatteryID: String? { didSet { save() } }
    /// One-time 1.3 offer to move to the new default speech model.
    var q5SwitchOfferShown: Bool { didSet { save() } }

    // Feedback / panel
    var showMenuBarIcon: Bool { didSet { save() } }
    var menuBarIconStyle: MenuBarIconStyle { didSet { save() } }
    var menuBarColoredStatus: Bool { didSet { save() } }   // off = all icon styles stay monochrome
    // Appearance: user-chosen colors. nil = follow the system accent.
    var accentColorHex: String? { didSet { save() } }
    var panelTintHex: String? { didSet { save() } }
    /// The pop-up WAVEFORM's own accent. nil = follow the app accent. Independent of the
    /// pop-up's glass tint, so the wave can sing in a different colour than its background.
    var waveColorHex: String? { didSet { save() } }
    var waveColorStyle: WaveColorStyle { didSet { save() } }
    /// Vividness of the wave's ribbons: 0 = washed out pastel, 1 = full saturation.
    var waveStrength: Double { didSet { save() } }
    /// RGB mode dials - how fast the spectrum cycles, and how far apart the ribbons sit
    /// in hue (0 = all one colour at once, high = a full rainbow spread across the wave).
    var waveRGBSpeed: Double { didSet { save() } }
    var waveRGBSpread: Double { didSet { save() } }
    /// How fast the pop-up's GLASS drifts through the spectrum in RGB mode.
    var panelRGBSpeed: Double { didSet { save() } }
    var panelTintStrength: Double { didSet { save() } }   // 0 = off ... 1 = strong
    /// Pop-up tint style: on by default, mapped to the accent color; custom and rainbow for fun.
    var panelTintStyle: PanelTintStyle { didSet { save() } }
    /// The Quick Edit card's OWN colors, independent of the dictation pop-up so the two
    /// read as different things at a glance. Purple out of the box.
    var quickEditTintStyle: PanelTintStyle { didSet { save() } }
    var quickEditTintHex: String? { didSet { save() } }
    var quickEditTintStrength: Double { didSet { save() } }
    var quickEditRGBSpeed: Double { didSet { save() } }
    var quickEditWaveColorStyle: WaveColorStyle { didSet { save() } }
    var quickEditWaveColorHex: String? { didSet { save() } }
    var quickEditWaveStrength: Double { didSet { save() } }
    var quickEditWaveRGBSpeed: Double { didSet { save() } }
    var quickEditWaveRGBSpread: Double { didSet { save() } }
    /// Selectable sound cues (system sound names). Sounds themselves are on by default.
    var soundStart: String { didSet { save(); Sound.startName = soundStart } }
    var soundStop: String { didSet { save(); Sound.stopName = soundStop } }
    var soundError: String { didSet { save(); Sound.errorName = soundError } }
    var showDockIcon: Bool { didSet { save() } }
    /// The Home page's "one key is all it takes" note, dismissible via its close button.
    var hasDismissedHomeNote: Bool { didSet { save() } }
    var hasDismissedDictionaryTip: Bool { didSet { save() } }
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
    var recordCancelledDictations: Bool { didSet { save() } }   // transcribe + save a cancelled recording to History instead of discarding it
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
        var redoLastHotkey: KeyCombo?
        var rightCommandTrigger: ModifierTrigger?
        var fnKeyTrigger: ModifierTrigger?
        var rightCommandSpaceSwitcher: Bool?
        var cancelOnDoubleEscape: Bool?
        var activeModeID: UUID
        var perAppModeOverrides: [String: UUID]
        var userName: String?
        var autoInsert: Bool
        var liveTyping: Bool?
        var quickEditDetection: Bool?
        var smartDictionary: Bool?
        var quickEditKeyEnabled: Bool?
        var quickEditTrigger: ModifierTrigger?
        var primaryTriggerKey: PrimaryTriggerKey?
        var quickEditTriggerKey: PrimaryTriggerKey?
        var reviewBeforeInsert: Bool?
        var reviewLongTextOnly: Bool?
        var appInsertionOverrides: [String: InsertionMethod]?
        var appAfterInsert: [String: AfterInsertAction]?
        var pauseMediaDuringDictation: Bool?
        var digitModeSwitching: Bool?
        var panelSnapsBack: Bool?
        var panelDraggedX: Double?
        var panelDraggedY: Double?
        var quickEditPosition: PanelPosition?
        var quickEditSnapsBack: Bool?
        var quickEditPreferredTrigger: ModifierTrigger?
        var quickEditDraggedX: Double?
        var quickEditDraggedY: Double?
        var lastSeenWhatsNewVersion: String?
        var visualizerColorHex: String?
        var restoreClipboard: Bool
        var adaptToSurroundings: Bool?
        var doubleEscapeToCancel: Bool?
        var quickEditModelID: String?
        var trimTrailingNewlines: Bool
        var appendSpaceAfterInsert: Bool?
        var modelCooldownSeconds: Int?
        var aiCleanupEnabled: Bool?
        var autoContextMode: Bool?
        var inputGain: Double?
        var autoAmplifyInput: Bool?
        var reduceBackgroundNoise: Bool?
        var keepMicWarm: Bool?
        var micWarmMinutes: Double?
        var silenceTimeout: Double
        var maxRecordingSeconds: Double
        var selectedSpeechModelID: String
        var energyAdaptive: Bool? = nil
        var speechModelPluggedID: String? = nil
        var speechModelBatteryID: String? = nil
        var languageModelPluggedID: String? = nil
        var languageModelBatteryID: String? = nil
        var q5SwitchOfferShown: Bool? = nil
        var selectedLanguageModelID: String
        var showMenuBarIcon: Bool?
        var menuBarIconStyle: MenuBarIconStyle?
        var menuBarColoredStatus: Bool?
        var accentColorHex: String?
        var panelTintHex: String?
        var waveColorHex: String?
        var waveColorStyle: WaveColorStyle?
        var waveStrength: Double?
        var waveRGBSpeed: Double?
        var waveRGBSpread: Double?
        var panelRGBSpeed: Double?
        var panelTintStrength: Double?
        var panelTintStyle: PanelTintStyle?
        var quickEditTintStyle: PanelTintStyle?
        var quickEditTintHex: String?
        var quickEditTintStrength: Double?
        var quickEditRGBSpeed: Double?
        var quickEditWaveColorStyle: WaveColorStyle?
        var quickEditWaveColorHex: String?
        var quickEditWaveStrength: Double?
        var quickEditWaveRGBSpeed: Double?
        var quickEditWaveRGBSpread: Double?
        var soundStart: String?
        var soundStop: String?
        var soundError: String?
        var showDockIcon: Bool?
        var hasDismissedHomeNote: Bool?
        var hasDismissedDictionaryTip: Bool?
        var dictionaryTipV2Reset: Bool?
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
        var recordCancelledDictations: Bool?
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
        redoLastHotkey = loaded?.redoLastHotkey
        rightCommandTrigger = loaded?.rightCommandTrigger ?? .toggle
        fnKeyTrigger = loaded?.fnKeyTrigger ?? .off
        rightCommandSpaceSwitcher = loaded?.rightCommandSpaceSwitcher ?? true   // Right ⌘ is the default trigger
        cancelOnDoubleEscape = loaded?.cancelOnDoubleEscape ?? true   // Esc closes/cancels the panel by default
        activeModeID = loaded?.activeModeID ?? BuiltInModes.rawTranscriptionID   // Raw is the default: instant, and Whisper alone is already clean
        perAppModeOverrides = loaded?.perAppModeOverrides ?? [:]
        userName = loaded?.userName ?? ""
        autoInsert = loaded?.autoInsert ?? true
        liveTyping = loaded?.liveTyping ?? false
        quickEditDetection = loaded?.quickEditDetection ?? true
        smartDictionary = loaded?.smartDictionary ?? true
        quickEditKeyEnabled = loaded?.quickEditKeyEnabled ?? true   // on by default
        // Migrate the old on/off toggle: enabled -> hold-to-talk (its historic behavior).
        quickEditTrigger = loaded?.quickEditTrigger ?? ((loaded?.quickEditKeyEnabled ?? true) ? .toggle : .off)
        quickEditTriggerKey = loaded?.quickEditTriggerKey ?? .rightOption
        primaryTriggerKey = loaded?.primaryTriggerKey ?? .rightCommand
        reviewBeforeInsert = loaded?.reviewBeforeInsert ?? false
        reviewLongTextOnly = loaded?.reviewLongTextOnly ?? true
        appInsertionOverrides = loaded?.appInsertionOverrides ?? [:]
        appAfterInsert = loaded?.appAfterInsert ?? [:]
        pauseMediaDuringDictation = loaded?.pauseMediaDuringDictation ?? true
        digitModeSwitching = loaded?.digitModeSwitching ?? true
        panelSnapsBack = loaded?.panelSnapsBack ?? false
        panelDraggedX = loaded?.panelDraggedX
        panelDraggedY = loaded?.panelDraggedY
        quickEditPosition = loaded?.quickEditPosition ?? .bottomCenter
        quickEditSnapsBack = loaded?.quickEditSnapsBack ?? false
        quickEditPreferredTrigger = loaded?.quickEditPreferredTrigger ?? (loaded?.quickEditTrigger.flatMap { $0 == .off ? nil : $0 } ?? .toggle)
        quickEditDraggedX = loaded?.quickEditDraggedX
        quickEditDraggedY = loaded?.quickEditDraggedY
        lastSeenWhatsNewVersion = loaded?.lastSeenWhatsNewVersion
        visualizerColorHex = loaded?.visualizerColorHex
        restoreClipboard = loaded?.restoreClipboard ?? true
        adaptToSurroundings = loaded?.adaptToSurroundings ?? true
        doubleEscapeToCancel = loaded?.doubleEscapeToCancel ?? false
        quickEditModelID = loaded?.quickEditModelID
        trimTrailingNewlines = loaded?.trimTrailingNewlines ?? true
        appendSpaceAfterInsert = loaded?.appendSpaceAfterInsert ?? true
        modelCooldownSeconds = loaded?.modelCooldownSeconds ?? 120
        aiCleanupEnabled = loaded?.aiCleanupEnabled ?? true
        autoContextMode = loaded?.autoContextMode ?? true   // the headline feature ships ON
        inputGain = loaded?.inputGain ?? 1.0
        autoAmplifyInput = loaded?.autoAmplifyInput ?? true
        reduceBackgroundNoise = loaded?.reduceBackgroundNoise ?? true
        // Off by default (user's call): the launch prewarm still heats the first session;
        // idle gaps then pay the route wake-up. Turning this on keeps every start instant.
        keepMicWarm = loaded?.keepMicWarm ?? false
        micWarmMinutes = loaded?.micWarmMinutes ?? 5
        silenceTimeout = loaded?.silenceTimeout ?? 0
        maxRecordingSeconds = loaded?.maxRecordingSeconds ?? 0
        selectedSpeechModelID = loaded?.selectedSpeechModelID ?? "whisper-large-v3-turbo-q5"   // measured vs fp16 on real dictations: near-identical accuracy, 1/3 the memory, faster load
        energyAdaptive = loaded?.energyAdaptive ?? false
        speechModelPluggedID = loaded?.speechModelPluggedID
        speechModelBatteryID = loaded?.speechModelBatteryID
        languageModelPluggedID = loaded?.languageModelPluggedID
        languageModelBatteryID = loaded?.languageModelBatteryID
        q5SwitchOfferShown = loaded?.q5SwitchOfferShown ?? false
        selectedLanguageModelID = loaded?.selectedLanguageModelID ?? "phi-3.5-mini-instruct-q4"   // the bundled Phi is the DEFAULT cleanup brain - fully self-contained, no Apple Intelligence dependency
        showMenuBarIcon = loaded?.showMenuBarIcon ?? true
        menuBarIconStyle = loaded?.menuBarIconStyle ?? .capybara
        menuBarColoredStatus = loaded?.menuBarColoredStatus ?? true
        accentColorHex = loaded?.accentColorHex
        panelTintHex = loaded?.panelTintHex
        waveColorHex = loaded?.waveColorHex
        // Migrate: a saved wave colour means the user had picked "custom" before styles existed.
        waveColorStyle = loaded?.waveColorStyle ?? (loaded?.waveColorHex != nil ? .custom : .accent)
        waveStrength = loaded?.waveStrength ?? 1.0
        waveRGBSpeed = loaded?.waveRGBSpeed ?? 1.0
        waveRGBSpread = loaded?.waveRGBSpread ?? 0.12
        panelRGBSpeed = loaded?.panelRGBSpeed ?? 1.0
        // Tint is ON by default (accent-mapped). Migration: an old install that had picked a
        // custom color keeps it; strength 0 becomes a gentle default so "on" is visible.
        panelTintStyle = loaded?.panelTintStyle
            ?? ((loaded?.panelTintHex != nil && (loaded?.panelTintStrength ?? 0) > 0) ? .custom : .accent)
        let loadedStrength = loaded?.panelTintStrength ?? 0
        panelTintStrength = loadedStrength > 0.01 ? loadedStrength : 0.35
        // A file that already knows about the card's colors may legitimately hold no hex
        // (Custom with no color picked, or matched to an untinted dictation pop-up); only a
        // file from before the feature gets the purple default.
        quickEditTintStyle = loaded?.quickEditTintStyle ?? .custom
        quickEditTintHex = loaded?.quickEditTintStyle == nil ? AppSettings.quickEditDefaultHex : loaded?.quickEditTintHex
        quickEditTintStrength = loaded?.quickEditTintStrength ?? 0.35
        quickEditRGBSpeed = loaded?.quickEditRGBSpeed ?? 1.0
        quickEditWaveColorStyle = loaded?.quickEditWaveColorStyle ?? .custom
        quickEditWaveColorHex = loaded?.quickEditWaveColorStyle == nil ? AppSettings.quickEditDefaultHex : loaded?.quickEditWaveColorHex
        quickEditWaveStrength = loaded?.quickEditWaveStrength ?? 1.0
        quickEditWaveRGBSpeed = loaded?.quickEditWaveRGBSpeed ?? 1.0
        quickEditWaveRGBSpread = loaded?.quickEditWaveRGBSpread ?? 0.12
        let sStart = loaded?.soundStart ?? "Purr"
        let sStop = loaded?.soundStop ?? "Bottle"
        let sError = loaded?.soundError ?? "Blow"
        soundStart = sStart
        soundStop = sStop
        soundError = sError
        Sound.startName = sStart
        Sound.stopName = sStop
        Sound.errorName = sError
        showDockIcon = loaded?.showDockIcon ?? true
        hasDismissedHomeNote = loaded?.hasDismissedHomeNote ?? false
        // The tip gained the Quick Edit "add this to my dictionary" paragraph - re-show it ONCE
        // to everyone who had dismissed the old version (one-time reset, marker below).
        if loaded?.dictionaryTipV2Reset != true {
            hasDismissedDictionaryTip = false
        } else {
            hasDismissedDictionaryTip = loaded?.hasDismissedDictionaryTip ?? false
        }
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
        recordCancelledDictations = loaded?.recordCancelledDictations ?? false
        autoDeleteDays = loaded?.autoDeleteDays ?? 30
        launchAtLogin = loaded?.launchAtLogin ?? false
        offeredModelDownloads = loaded?.offeredModelDownloads ?? false
        hasCompletedOnboarding = loaded?.hasCompletedOnboarding ?? false
        isLoading = false
        // The pop-up used to snap back to its preset position by default. Staying where it
        // was dragged is the behavior people expect, so existing installs move to the new
        // default once; anyone who wants snap-back turns it on again in Settings.
        if !defaults.bool(forKey: "panel.stayMigrated") {
            defaults.set(true, forKey: "panel.stayMigrated")
            if panelSnapsBack { panelSnapsBack = false }
        }
        // Quick Edit's key used to default to hold-to-talk; tap to start and stop matches the
        // dictation key and is easier on hands that cannot hold a key down. Once.
        if !defaults.bool(forKey: "quickedit.tapMigrated") {
            defaults.set(true, forKey: "quickedit.tapMigrated")
            if quickEditTrigger == .pushToTalk { quickEditTrigger = .toggle }
        }
    }

    /// See Persistence.writesSuspended: after an erase, no setting may write itself back.
    nonisolated(unsafe) static var writesSuspended = false

    private func save() {
        guard !isLoading, !AppSettings.writesSuspended else { return }
        if let data = try? JSONEncoder().encode(snapshot()) {
            defaults.set(data, forKey: AppSettings.defaultsKey)
        }
    }

    /// Every preference as one value: what save() persists, what a restore undoes.
    func snapshot() -> Snapshot {
        Snapshot(
            engine: engine, localeIdentifier: localeIdentifier, insertionMethod: insertionMethod,
            hotkey: hotkey, hotkeyBehavior: hotkeyBehavior, pauseHotkey: pauseHotkey, cycleModeHotkey: cycleModeHotkey,
            switcherHotkey: switcherHotkey, aiActionsHotkey: aiActionsHotkey,
            historyPaletteHotkey: historyPaletteHotkey, redoLastHotkey: redoLastHotkey, rightCommandTrigger: rightCommandTrigger, fnKeyTrigger: fnKeyTrigger, rightCommandSpaceSwitcher: rightCommandSpaceSwitcher,
            cancelOnDoubleEscape: cancelOnDoubleEscape,
            activeModeID: activeModeID, perAppModeOverrides: perAppModeOverrides, userName: userName,
            autoInsert: autoInsert, liveTyping: liveTyping, quickEditDetection: quickEditDetection, smartDictionary: smartDictionary, quickEditKeyEnabled: quickEditKeyEnabled, quickEditTrigger: quickEditTrigger, primaryTriggerKey: primaryTriggerKey, quickEditTriggerKey: quickEditTriggerKey, reviewBeforeInsert: reviewBeforeInsert, reviewLongTextOnly: reviewLongTextOnly, appInsertionOverrides: appInsertionOverrides, appAfterInsert: appAfterInsert, pauseMediaDuringDictation: pauseMediaDuringDictation, digitModeSwitching: digitModeSwitching, panelSnapsBack: panelSnapsBack, panelDraggedX: panelDraggedX, panelDraggedY: panelDraggedY, quickEditPosition: quickEditPosition, quickEditSnapsBack: quickEditSnapsBack, quickEditPreferredTrigger: quickEditPreferredTrigger, quickEditDraggedX: quickEditDraggedX, quickEditDraggedY: quickEditDraggedY, lastSeenWhatsNewVersion: lastSeenWhatsNewVersion, visualizerColorHex: visualizerColorHex, restoreClipboard: restoreClipboard, adaptToSurroundings: adaptToSurroundings, doubleEscapeToCancel: doubleEscapeToCancel, quickEditModelID: quickEditModelID, trimTrailingNewlines: trimTrailingNewlines,
            appendSpaceAfterInsert: appendSpaceAfterInsert, modelCooldownSeconds: modelCooldownSeconds, aiCleanupEnabled: aiCleanupEnabled, autoContextMode: autoContextMode,
            inputGain: inputGain, autoAmplifyInput: autoAmplifyInput, reduceBackgroundNoise: reduceBackgroundNoise, keepMicWarm: keepMicWarm, micWarmMinutes: micWarmMinutes,
            silenceTimeout: silenceTimeout, maxRecordingSeconds: maxRecordingSeconds,
            selectedSpeechModelID: selectedSpeechModelID,
            energyAdaptive: energyAdaptive,
            speechModelPluggedID: speechModelPluggedID,
            speechModelBatteryID: speechModelBatteryID,
            languageModelPluggedID: languageModelPluggedID,
            languageModelBatteryID: languageModelBatteryID,
            q5SwitchOfferShown: q5SwitchOfferShown,
            selectedLanguageModelID: selectedLanguageModelID,
            showMenuBarIcon: showMenuBarIcon, menuBarIconStyle: menuBarIconStyle, menuBarColoredStatus: menuBarColoredStatus, accentColorHex: accentColorHex, panelTintHex: panelTintHex, waveColorHex: waveColorHex, waveColorStyle: waveColorStyle, waveStrength: waveStrength, waveRGBSpeed: waveRGBSpeed, waveRGBSpread: waveRGBSpread, panelRGBSpeed: panelRGBSpeed, panelTintStrength: panelTintStrength, panelTintStyle: panelTintStyle, quickEditTintStyle: quickEditTintStyle, quickEditTintHex: quickEditTintHex, quickEditTintStrength: quickEditTintStrength, quickEditRGBSpeed: quickEditRGBSpeed, quickEditWaveColorStyle: quickEditWaveColorStyle, quickEditWaveColorHex: quickEditWaveColorHex, quickEditWaveStrength: quickEditWaveStrength, quickEditWaveRGBSpeed: quickEditWaveRGBSpeed, quickEditWaveRGBSpread: quickEditWaveRGBSpread, soundStart: soundStart, soundStop: soundStop, soundError: soundError, showDockIcon: showDockIcon,
            hasDismissedHomeNote: hasDismissedHomeNote, hasDismissedDictionaryTip: hasDismissedDictionaryTip, dictionaryTipV2Reset: true, inputDeviceUID: inputDeviceUID,
            showRecordingPanel: showRecordingPanel, livePreviewEnabled: livePreviewEnabled, panelStyle: panelStyle, panelPosition: panelPosition, panelSize: panelSize, panelAnimation: panelAnimation,
            playSounds: playSounds, saveHistory: saveHistory, historyRetention: historyRetention,
            clearHistoryOnQuit: clearHistoryOnQuit, saveAudio: saveAudio, recordCancelledDictations: recordCancelledDictations, autoDeleteDays: autoDeleteDays,
            launchAtLogin: launchAtLogin, offeredModelDownloads: offeredModelDownloads,
            hasCompletedOnboarding: hasCompletedOnboarding)
    }

    // MARK: Restore defaults

    /// The settings as they were just before the last Restore Defaults, kept for the
    /// session so one click puts everything back. Cleared by undo or by quitting.
    var restoreUndo: Snapshot?

    /// Put every preference back to its first-launch value. State that is not a
    /// preference survives: onboarding done, offers already shown, tips dismissed, and
    /// the login item (a system registration the toggle must keep matching).
    func restoreDefaults() {
        let previous = snapshot()
        let suite = "com.ryleighnewman.YapToText.restore-scratch"
        let scratch = UserDefaults(suiteName: suite) ?? .standard
        scratch.removePersistentDomain(forName: suite)
        var fresh = AppSettings(defaults: scratch).snapshot()
        fresh.hasCompletedOnboarding = previous.hasCompletedOnboarding
        fresh.lastSeenWhatsNewVersion = previous.lastSeenWhatsNewVersion
        fresh.q5SwitchOfferShown = previous.q5SwitchOfferShown
        fresh.offeredModelDownloads = previous.offeredModelDownloads
        fresh.hasDismissedHomeNote = previous.hasDismissedHomeNote
        fresh.hasDismissedDictionaryTip = previous.hasDismissedDictionaryTip
        fresh.launchAtLogin = previous.launchAtLogin
        apply(fresh)
        restoreUndo = previous
        yapdiag("settings: restored defaults (undo available)")
    }

    func undoRestore() {
        guard let previous = restoreUndo else { return }
        apply(previous)
        restoreUndo = nil
        yapdiag("settings: restore undone")
    }

    /// Assign every preference from a snapshot in one pass, saving once at the end.
    private func apply(_ s: Snapshot) {
        isLoading = true
        engine = s.engine
        localeIdentifier = s.localeIdentifier
        insertionMethod = s.insertionMethod
        hotkey = s.hotkey
        hotkeyBehavior = s.hotkeyBehavior
        pauseHotkey = s.pauseHotkey
        cycleModeHotkey = s.cycleModeHotkey
        switcherHotkey = s.switcherHotkey
        aiActionsHotkey = s.aiActionsHotkey
        historyPaletteHotkey = s.historyPaletteHotkey
        redoLastHotkey = s.redoLastHotkey
        if let v = s.rightCommandTrigger { rightCommandTrigger = v }
        if let v = s.fnKeyTrigger { fnKeyTrigger = v }
        if let v = s.rightCommandSpaceSwitcher { rightCommandSpaceSwitcher = v }
        if let v = s.cancelOnDoubleEscape { cancelOnDoubleEscape = v }
        activeModeID = s.activeModeID
        perAppModeOverrides = s.perAppModeOverrides
        if let v = s.userName { userName = v }
        autoInsert = s.autoInsert
        if let v = s.liveTyping { liveTyping = v }
        if let v = s.quickEditDetection { quickEditDetection = v }
        if let v = s.smartDictionary { smartDictionary = v }
        if let v = s.quickEditKeyEnabled { quickEditKeyEnabled = v }
        if let v = s.quickEditTrigger { quickEditTrigger = v }
        if let v = s.primaryTriggerKey { primaryTriggerKey = v }
        if let v = s.quickEditTriggerKey { quickEditTriggerKey = v }
        if let v = s.reviewBeforeInsert { reviewBeforeInsert = v }
        if let v = s.reviewLongTextOnly { reviewLongTextOnly = v }
        if let v = s.appInsertionOverrides { appInsertionOverrides = v }
        if let v = s.appAfterInsert { appAfterInsert = v }
        if let v = s.pauseMediaDuringDictation { pauseMediaDuringDictation = v }
        if let v = s.digitModeSwitching { digitModeSwitching = v }
        if let v = s.panelSnapsBack { panelSnapsBack = v }
        panelDraggedX = s.panelDraggedX
        panelDraggedY = s.panelDraggedY
        if let v = s.quickEditPosition { quickEditPosition = v }
        if let v = s.quickEditSnapsBack { quickEditSnapsBack = v }
        if let v = s.quickEditPreferredTrigger { quickEditPreferredTrigger = v }
        quickEditDraggedX = s.quickEditDraggedX
        quickEditDraggedY = s.quickEditDraggedY
        lastSeenWhatsNewVersion = s.lastSeenWhatsNewVersion
        visualizerColorHex = s.visualizerColorHex
        restoreClipboard = s.restoreClipboard
        if let v = s.adaptToSurroundings { adaptToSurroundings = v }
        if let v = s.doubleEscapeToCancel { doubleEscapeToCancel = v }
        quickEditModelID = s.quickEditModelID
        trimTrailingNewlines = s.trimTrailingNewlines
        if let v = s.appendSpaceAfterInsert { appendSpaceAfterInsert = v }
        if let v = s.modelCooldownSeconds { modelCooldownSeconds = v }
        if let v = s.aiCleanupEnabled { aiCleanupEnabled = v }
        if let v = s.autoContextMode { autoContextMode = v }
        if let v = s.inputGain { inputGain = v }
        if let v = s.autoAmplifyInput { autoAmplifyInput = v }
        if let v = s.reduceBackgroundNoise { reduceBackgroundNoise = v }
        if let v = s.keepMicWarm { keepMicWarm = v }
        if let v = s.micWarmMinutes { micWarmMinutes = v }
        silenceTimeout = s.silenceTimeout
        maxRecordingSeconds = s.maxRecordingSeconds
        selectedSpeechModelID = s.selectedSpeechModelID
        if let v = s.energyAdaptive { energyAdaptive = v }
        speechModelPluggedID = s.speechModelPluggedID
        speechModelBatteryID = s.speechModelBatteryID
        languageModelPluggedID = s.languageModelPluggedID
        languageModelBatteryID = s.languageModelBatteryID
        if let v = s.q5SwitchOfferShown { q5SwitchOfferShown = v }
        selectedLanguageModelID = s.selectedLanguageModelID
        if let v = s.showMenuBarIcon { showMenuBarIcon = v }
        if let v = s.menuBarIconStyle { menuBarIconStyle = v }
        if let v = s.menuBarColoredStatus { menuBarColoredStatus = v }
        accentColorHex = s.accentColorHex
        panelTintHex = s.panelTintHex
        waveColorHex = s.waveColorHex
        if let v = s.waveColorStyle { waveColorStyle = v }
        if let v = s.waveStrength { waveStrength = v }
        if let v = s.waveRGBSpeed { waveRGBSpeed = v }
        if let v = s.waveRGBSpread { waveRGBSpread = v }
        if let v = s.panelRGBSpeed { panelRGBSpeed = v }
        if let v = s.panelTintStrength { panelTintStrength = v }
        if let v = s.quickEditTintStyle { quickEditTintStyle = v; quickEditTintHex = s.quickEditTintHex }
        if let v = s.quickEditTintStrength { quickEditTintStrength = v }
        if let v = s.quickEditRGBSpeed { quickEditRGBSpeed = v }
        if let v = s.quickEditWaveColorStyle { quickEditWaveColorStyle = v; quickEditWaveColorHex = s.quickEditWaveColorHex }
        if let v = s.quickEditWaveStrength { quickEditWaveStrength = v }
        if let v = s.quickEditWaveRGBSpeed { quickEditWaveRGBSpeed = v }
        if let v = s.quickEditWaveRGBSpread { quickEditWaveRGBSpread = v }
        if let v = s.panelTintStyle { panelTintStyle = v }
        if let v = s.soundStart { soundStart = v }
        if let v = s.soundStop { soundStop = v }
        if let v = s.soundError { soundError = v }
        if let v = s.showDockIcon { showDockIcon = v }
        if let v = s.hasDismissedHomeNote { hasDismissedHomeNote = v }
        if let v = s.hasDismissedDictionaryTip { hasDismissedDictionaryTip = v }
        inputDeviceUID = s.inputDeviceUID
        showRecordingPanel = s.showRecordingPanel
        if let v = s.livePreviewEnabled { livePreviewEnabled = v }
        if let v = s.panelStyle { panelStyle = v }
        panelPosition = s.panelPosition
        if let v = s.panelSize { panelSize = v }
        panelAnimation = s.panelAnimation
        playSounds = s.playSounds
        saveHistory = s.saveHistory
        historyRetention = s.historyRetention
        clearHistoryOnQuit = s.clearHistoryOnQuit
        saveAudio = s.saveAudio
        if let v = s.recordCancelledDictations { recordCancelledDictations = v }
        autoDeleteDays = s.autoDeleteDays
        launchAtLogin = s.launchAtLogin
        if let v = s.offeredModelDownloads { offeredModelDownloads = v }
        hasCompletedOnboarding = s.hasCompletedOnboarding
        isLoading = false
        save()
    }

#if DEBUG
    /// Marketing rig (Marketing/tools/shoot_v5.py): swap in the look every shot shares, in memory
    /// only, then put the user's own values back. Writes stay suspended while staged, so nothing
    /// staged ever reaches the preferences file, even if the rig dies mid-shoot.
    private var stagedLook: Snapshot?
    func stageMarketingLook(_ on: Bool) {
        if on {
            guard stagedLook == nil else { return }
            stagedLook = snapshot()
            AppSettings.writesSuspended = true
            var s = snapshot()
            s.accentColorHex = "#0A84FF"
            s.panelTintStyle = .accent; s.panelTintHex = nil; s.panelTintStrength = 0.35
            s.waveColorStyle = .accent; s.waveColorHex = nil; s.waveStrength = 1
            s.panelStyle = .expanded; s.panelPosition = .bottomCenter; s.panelSnapsBack = true
            s.panelDraggedX = nil; s.panelDraggedY = nil
            s.quickEditTintStyle = .custom; s.quickEditTintHex = "#BF5AF2"; s.quickEditTintStrength = 0.35
            s.quickEditWaveColorStyle = .custom; s.quickEditWaveColorHex = "#BF5AF2"; s.quickEditWaveStrength = 1
            s.quickEditPosition = .bottomCenter; s.quickEditSnapsBack = true
            s.quickEditDraggedX = nil; s.quickEditDraggedY = nil
            s.showRecordingPanel = true; s.hasCompletedOnboarding = true
            s.lastSeenWhatsNewVersion = Changelog.whatsNewKey
            s.userName = ""; s.menuBarIconStyle = .capybara; s.showMenuBarIcon = true; s.showDockIcon = true
            apply(s)
            yapdiag("settings: marketing look staged")
        } else {
            guard let s = stagedLook else { return }
            stagedLook = nil
            AppSettings.writesSuspended = false
            apply(s)
            yapdiag("settings: marketing look removed, user values restored")
        }
    }
#endif
}
