import SwiftUI
import Testing
@testable import RelayCore
@testable import RelayUI

@MainActor @Suite struct PanelKeysTests {
    /// Caps lock, keypad and function (named through `.all`: `EventModifiers.function` is deprecated).
    private let systemFlags = EventModifiers.all.subtracting([.command, .shift, .option, .control])

    @Test func plainKeys() {
        #expect(PanelKeys.key(.escape, modifiers: [], characters: "\u{1B}") == .escape)
        #expect(PanelKeys.key(.return, modifiers: [], characters: "\r") == .returnKey)
        #expect(PanelKeys.key(.return, modifiers: .option, characters: "\r") == .optionReturn)
        #expect(PanelKeys.key(.leftArrow, modifiers: systemFlags, characters: "") == .left)
        #expect(PanelKeys.key(.rightArrow, modifiers: .numericPad, characters: "") == .right)
        #expect(PanelKeys.key(KeyEquivalent("3"), modifiers: [], characters: "3") == .digit(3))
    }

    @Test func modifiedOrOtherKeysAreNotOurs() {
        #expect(PanelKeys.key(KeyEquivalent("3"), modifiers: .command, characters: "3") == nil)
        #expect(PanelKeys.key(KeyEquivalent("7"), modifiers: [], characters: "7") == nil)
        #expect(PanelKeys.key(.escape, modifiers: .shift, characters: "\u{1B}") == nil)
        #expect(PanelKeys.key(.upArrow, modifiers: systemFlags, characters: "") == nil)   // the List's own
        #expect(PanelKeys.key(KeyEquivalent("a"), modifiers: [], characters: "a") == nil)
    }

    @Test func modifierFlagsKeepOnlyTheFourKeyMapReads() {
        #expect(KeyResponder.modifiers([.command, .shift, .capsLock, .function, .numericPad]) == [.command, .shift])
        #expect(KeyResponder.modifiers([.control, .option]) == [.control, .option])
    }

    /// The router's guard: only ⌘ combinations go through performKeyEquivalent (rule 1).
    @Test func onlyCommandCombinationsReachTheRouter() {
        #expect(KeyResponder.isCommandCombination([.command]))
        #expect(KeyResponder.isCommandCombination([.command, .shift, .numericPad, .function]))
        #expect(!KeyResponder.isCommandCombination([]))                       // Return, digits, Esc
        #expect(!KeyResponder.isCommandCombination([.numericPad, .function])) // arrows
        #expect(!KeyResponder.isCommandCombination([.option]))                // ⌥Return
        #expect(!KeyResponder.isCommandCombination([.control, .shift, .capsLock]))
    }
}
