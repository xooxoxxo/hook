import AppKit
import RelayCore
import Testing
@testable import RelayUI
@testable import RelayUIMac

@MainActor @Suite struct HarnessMarkTests {
    /// The 18 entries of integration/harnesses.json.
    static let ids = ["claude-code", "codex", "gemini-cli", "antigravity", "copilot-cli", "vscode-copilot", "cursor",
                      "opencode", "zed", "pi", "devin", "factory", "kiro", "amp", "cline", "goose", "junie", "warp"]

    private func rgb(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    @Test func everyTableEntryHasItsOwnLettersAndColour() {
        let specs = Self.ids.compactMap { HarnessMark.known[$0] }
        #expect(specs.count == Self.ids.count)
        #expect(Set(specs.map(\.letters)).count == Self.ids.count)
        #expect(Set(specs.map { rgb($0.color) }).count == Self.ids.count)
        #expect(Set(HarnessMark.known.keys) == Set(Self.ids))
    }

    @Test func theSameIdAlwaysGivesTheSameMark() {
        for id in Self.ids {
            #expect(HarnessMark.letters(id: id, name: "Anything") == HarnessMark.letters(id: id, name: "Else"))
            #expect(HarnessMark.letters(id: id, name: "x") == HarnessMark.known[id]?.letters)
        }
        // The prototype's name hash collided here: Claude Code and Codex, Copilot CLI and Cline.
        #expect(HarnessMark.letters(id: "claude-code", name: "Claude Code") == "CC")
        #expect(HarnessMark.letters(id: "codex", name: "Codex") == "CX")
        #expect(HarnessMark.letters(id: "cline", name: "Cline") != HarnessMark.letters(id: "copilot-cli", name: "Copilot CLI"))
    }

    @Test func anUnknownIdFallsBackToTheMonogram() {
        #expect(HarnessMark.known["new-agent"] == nil)
        #expect(HarnessMark.letters(id: "new-agent", name: "New Agent") == Monogram.letters("New Agent"))
    }

    /// White bold letters stay readable on every mark colour (3:1, the large-text floor).
    @Test func theLettersContrastWithEveryColour() {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for (id, spec) in HarnessMark.known {
            let c = spec.color.usingColorSpace(.sRGB)!
            let l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
            #expect((1.05) / (l + 0.05) >= 3, "\(id)")
        }
    }
}
