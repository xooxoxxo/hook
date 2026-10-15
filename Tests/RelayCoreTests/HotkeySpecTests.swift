import Foundation
import Testing
@testable import RelayCore

@Test func defaultHotkeyParses() throws {
    let spec = try #require(HotkeySpec.parse(HotkeySpec.defaultString))
    #expect(spec.keyCode == 0x0F)
    #expect(spec.carbonModifiers == HotkeySpec.controlBit | HotkeySpec.optionBit | HotkeySpec.cmdBit)
    #expect(spec.display == "⌃⌥⌘R")
}

@Test func hotkeyRejectsUnsafeOrInvalidInput() {
    #expect(HotkeySpec.parse("") == nil)            // disabled
    #expect(HotkeySpec.parse("r") == nil)           // a bare letter would hijack typing
    #expect(HotkeySpec.parse("ctrl+r+t") == nil)    // two keys
    #expect(HotkeySpec.parse("ctrl+ü") == nil)      // unknown key
    #expect(HotkeySpec.parse("ctrl++r") == nil)     // empty part
    #expect(HotkeySpec.parse("shift+cmd+space")?.display == "⇧⌘Space")
    #expect(HotkeySpec.parse("f5")?.display == "F5")  // function keys may stand alone
}

@Test func configWithoutHotkeyUsesDefault() throws {
    let json = #"{"mailboxURL":"http://example.invalid:8790","tokenFile":"/tmp/t"}"#
    let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
    #expect(config.hotkey == HotkeySpec.defaultString)
}

@Test func hotkeyCanonicalRoundTrips() throws {
    for raw in [HotkeySpec.defaultString, "shift+cmd+space", "cmd+opt+ctrl+f5"] {
        let spec = try #require(HotkeySpec.parse(raw))
        #expect(HotkeySpec.parse(spec.canonical) == spec)
    }
    #expect(HotkeySpec.parse(HotkeySpec.defaultString)?.canonical == "ctrl+opt+cmd+r")
    #expect(HotkeySpec.parse("cmd+shift+space")?.canonical == "shift+cmd+space")
    #expect(HotkeySpec.parse("f5")?.canonical == "f5")
}

@Test func hotkeyFromKeyCode() throws {
    let all = HotkeySpec.controlBit | HotkeySpec.optionBit | HotkeySpec.cmdBit
    let spec = try #require(HotkeySpec.from(keyCode: 0x0F, carbonModifiers: all))
    #expect(spec == HotkeySpec.parse(HotkeySpec.defaultString))
    #expect(spec.display == "⌃⌥⌘R")
    let space = try #require(HotkeySpec.from(keyCode: 0x31, carbonModifiers: HotkeySpec.shiftBit | HotkeySpec.cmdBit))
    #expect(space.canonical == "shift+cmd+space")
    #expect(space.display == "⇧⌘Space")
    // Caps Lock (1 << 10) and other Carbon bits are ignored.
    #expect(HotkeySpec.from(keyCode: 0x0F, carbonModifiers: all | (1 << 10)) == spec)
}

@Test func hotkeyFromRejectsUnsafeOrUnknown() {
    #expect(HotkeySpec.from(keyCode: 0x0F, carbonModifiers: 0) == nil)                       // bare R
    #expect(HotkeySpec.from(keyCode: 0x0F, carbonModifiers: HotkeySpec.shiftBit) == nil)     // ⇧R types a capital
    #expect(HotkeySpec.from(keyCode: 0x60, carbonModifiers: 0) == nil)                       // F5 alone: recorder needs ⌘, ⌃ or ⌥
    #expect(HotkeySpec.from(keyCode: 0xFF, carbonModifiers: HotkeySpec.cmdBit) == nil)       // unknown key code
}

@Test func hotkeyShiftAloneNeedsAFunctionKey() {
    // A hand-edited "shift+a" would swallow every capital A typed system-wide.
    #expect(HotkeySpec.parse("shift+a") == nil)
    #expect(HotkeySpec.parse("shift+1") == nil)
    #expect(HotkeySpec.parse("shift+space") == nil)
    #expect(HotkeySpec.parse("shift+f5")?.display == "⇧F5")
    #expect(HotkeySpec.parse("shift+f12")?.canonical == "shift+f12")
    #expect(HotkeySpec.parse("shift+opt+a")?.display == "⌥⇧A")
    #expect(HotkeySpec.parse("ctrl+shift+a") != nil)
}
