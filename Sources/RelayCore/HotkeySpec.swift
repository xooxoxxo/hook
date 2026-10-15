import Foundation

/// A global shortcut written as text, e.g. "ctrl+opt+cmd+r", parsed into the
/// Carbon key code and modifier mask that `RegisterEventHotKey` expects.
public struct HotkeySpec: Equatable, Sendable {
    public static let defaultString = "ctrl+opt+cmd+r"

    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    /// Human label in macOS order, e.g. "⌃⌥⌘R".
    public let display: String

    // Carbon modifier bits (HIToolbox Events.h).
    static let cmdBit: UInt32 = 1 << 8
    static let shiftBit: UInt32 = 1 << 9
    static let optionBit: UInt32 = 1 << 11
    static let controlBit: UInt32 = 1 << 12

    /// kVK_ANSI_* and function-key codes (layout-independent positions of a US keyboard).
    static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, "space": 0x31, "`": 0x32,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Returns nil for "" (shortcut disabled) and for anything unparseable.
    /// A plain letter, digit or space needs ⌘, ⌃ or ⌥ (⇧ alone isn't enough), so
    /// typing is never hijacked. F1–F12 may stand alone or with ⇧.
    public static func parse(_ raw: String) -> HotkeySpec? {
        let parts = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        var mods: UInt32 = 0
        var key: String?
        for part in parts {
            switch part {
            case "ctrl", "control": mods |= controlBit
            case "opt", "option", "alt": mods |= optionBit
            case "shift": mods |= shiftBit
            case "cmd", "command": mods |= cmdBit
            default:
                guard key == nil else { return nil }   // two non-modifier keys
                key = part
            }
        }
        guard let key, let code = keyCodes[key] else { return nil }
        let isFunctionKey = key.count >= 2 && key.hasPrefix("f") && key.dropFirst().allSatisfy(\.isNumber)
        // Like the recorder: ⇧ alone would take over typing a capital, so it
        // needs ⌘, ⌃ or ⌥ too, unless the key is F1–F12.
        guard mods & (controlBit | optionBit | cmdBit) != 0 || isFunctionKey else { return nil }

        var label = ""
        if mods & controlBit != 0 { label += "⌃" }
        if mods & optionBit != 0 { label += "⌥" }
        if mods & shiftBit != 0 { label += "⇧" }
        if mods & cmdBit != 0 { label += "⌘" }
        label += key == "space" ? "Space" : key.uppercased()
        return HotkeySpec(keyCode: code, carbonModifiers: mods, display: label)
    }
}

extension HotkeySpec {
    /// Key code → name, the reverse of `keyCodes`, so the recorder can show and
    /// save what was pressed.
    static let keyNames: [UInt32: String] = Dictionary(
        uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })

    /// A pressed combination as a spec. Needs ⌘, ⌃ or ⌥ (⇧ alone would type),
    /// and a key code from `keyCodes`. Other Carbon modifier bits are ignored.
    public static func from(keyCode: UInt32, carbonModifiers: UInt32) -> HotkeySpec? {
        let mods = carbonModifiers & (controlBit | optionBit | shiftBit | cmdBit)
        guard mods & (controlBit | optionBit | cmdBit) != 0, let name = keyNames[keyCode] else { return nil }
        return parse(canonicalString(modifiers: mods, key: name))
    }

    /// The config string for this spec, e.g. "ctrl+opt+cmd+r".
    public var canonical: String {
        Self.canonicalString(modifiers: carbonModifiers, key: Self.keyNames[keyCode] ?? "")
    }

    static func canonicalString(modifiers: UInt32, key: String) -> String {
        var parts: [String] = []
        if modifiers & controlBit != 0 { parts.append("ctrl") }
        if modifiers & optionBit != 0 { parts.append("opt") }
        if modifiers & shiftBit != 0 { parts.append("shift") }
        if modifiers & cmdBit != 0 { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
