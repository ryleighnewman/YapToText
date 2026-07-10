import Foundation

/// A global keyboard shortcut, stored using Carbon modifier bit values so it can be
/// handed straight to `RegisterEventHotKey`. Kept free of any Carbon import so the
/// model layer stays lightweight and Codable.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey / optionKey / controlKey / shiftKey).
    var modifiers: UInt32

    // Carbon modifier bit values (mirrors <Carbon/HIToolbox/Events.h>).
    static let cmd: UInt32     = 0x0100
    static let shift: UInt32   = 0x0200
    static let option: UInt32  = 0x0800
    static let control: UInt32 = 0x1000

    /// Default: Control-Option-Space. A conflict-free chord that works as either a
    /// toggle or push-to-talk trigger without needing Input Monitoring.
    static let `default` = KeyCombo(keyCode: 49, modifiers: control | option)

    var displayString: String {
        var out = ""
        if modifiers & KeyCombo.control != 0 { out += "⌃" }
        if modifiers & KeyCombo.option  != 0 { out += "⌥" }
        if modifiers & KeyCombo.shift   != 0 { out += "⇧" }
        if modifiers & KeyCombo.cmd     != 0 { out += "⌘" }
        out += KeyCombo.keyName(for: keyCode)
        return out
    }

    static func keyName(for code: UInt32) -> String {
        if let named = specialKeys[code] { return named }
        if let letter = letterKeys[code] { return letter }
        return "Key \(code)"
    }

    private static let specialKeys: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    ]

    private static let letterKeys: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
    ]
}
