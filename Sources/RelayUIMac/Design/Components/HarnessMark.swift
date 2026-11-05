import RelayUI
import AppKit
import RelayCore
import SwiftUI

/// Design/HarnessMark: a coding agent's two letters on its own colour, keyed by the harness
/// table's id, so no two marks look alike (a hash of the name made Claude Code and Codex both
/// "CC"). An id from a newer table falls back to the project monogram. Decorative: the
/// harness name beside it is what VoiceOver reads.
public struct HarnessMark: View {
    public struct Spec: Sendable {
        public let letters: String
        public let color: NSColor
    }

    /// Every entry of integration/harnesses.json.
    public static let known: [String: Spec] = {
        typealias C = DS.Color.Harness
        let marks: [(String, String, NSColor)] = [
            ("claude-code", "CC", C.claudeCode), ("codex", "CX", C.codex), ("gemini-cli", "GE", C.geminiCLI),
            ("antigravity", "AG", C.antigravity), ("copilot-cli", "CP", C.copilotCLI),
            ("vscode-copilot", "VS", C.vscodeCopilot), ("cursor", "CU", C.cursor), ("opencode", "OC", C.opencode),
            ("zed", "ZD", C.zed), ("pi", "PI", C.pi), ("devin", "DV", C.devin), ("factory", "FD", C.factory),
            ("kiro", "KI", C.kiro), ("amp", "AM", C.amp), ("cline", "CL", C.cline), ("goose", "GO", C.goose),
            ("junie", "JU", C.junie), ("warp", "WA", C.warp),
        ]
        return Dictionary(uniqueKeysWithValues: marks.map { ($0.0, Spec(letters: $0.1, color: $0.2)) })
    }()

    public static func letters(id: String, name: String) -> String {
        known[id]?.letters ?? Monogram.letters(name)
    }

    public static func tint(id: String, name: String) -> SwiftUI.Color {
        known[id].map { SwiftUI.Color(nsColor: $0.color) } ?? DS.Color.monogram(name)
    }

    let id: String
    let name: String
    let dimmed: Bool

    public init(id: String, name: String, dimmed: Bool = false) {
        self.id = id
        self.name = name
        self.dimmed = dimmed
    }

    public var body: some View {
        Text(Self.letters(id: id, name: name))
            .font(DS.Font.harnessMark)
            .foregroundStyle(DS.Color.monogramText)
            .frame(width: DS.Metric.harnessMark, height: DS.Metric.harnessMark)
            .background(RoundedRectangle(cornerRadius: DS.Metric.harnessMarkRadius, style: .continuous)
                .fill(Self.tint(id: id, name: name)))
            .opacity(dimmed ? DS.Color.harnessDimmedOpacity : 1)
            .accessibilityHidden(true)
    }
}
