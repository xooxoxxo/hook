import AppKit
import RelayCore
import SwiftUI

/// Design/CodeBlock (design §3.2, §4.15): a command, wrapped (never scrolled sideways), with
/// hidden characters revealed as "⟨U+XXXX⟩" and a Copy button that copies exactly what is shown.
public struct CodeBlock: View {
    let code: String
    let copyLabel: String
    let lang: String?
    let onCopy: (String) -> Void
    @State private var copied: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `copied` seeds the state, for the gallery's "Copied" sample. `onCopy` receives
    /// `Sanitize.copyText(code)`, the text to put on the pasteboard.
    public init(code: String, copyLabel: String, lang: String? = nil, copied: Bool = false,
                onCopy: @escaping (String) -> Void) {
        self.code = code
        self.copyLabel = copyLabel
        self.lang = lang
        self.onCopy = onCopy
        _copied = State(initialValue: copied)
    }

    public var body: some View {
        let (shown, hidden) = Self.shown(code)
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(verbatim: shown)
                    .font(DS.Font.code)
                    .multilineTextAlignment(.leading)   // a grouped Form's trailing column would right-align it
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Self.codeLabel(lang: lang))
                    .accessibilityValue(shown)
                Button(Self.copyTitle(copied: copied, hidden: hidden)) { copy() }
                    .controlSize(DS.Control.inline)
                    .contentTransition(.opacity)
                    .accessibilityLabel(copyLabel)
            }
            .padding(.horizontal, DS.Space.codeH)
            .padding(.vertical, DS.Space.codeV)
            .background(DS.Color.codeFill, in: .rect(cornerRadius: DS.Metric.codeRadius))
            if hidden {
                Label(Self.warning, systemImage: DS.Symbol.warning)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    public static let warning = "Hidden characters shown as ⟨U+…⟩. Check before running."
    public static func copyTitle(copied: Bool, hidden: Bool) -> String {
        copied ? "Copied" : (hidden ? "Copy as Shown" : "Copy")
    }
    public static func codeLabel(lang: String?) -> String { lang.map { "Command, " + line($0) } ?? "Command" }
    public static func shown(_ code: String) -> (text: String, hidden: Bool) { Sanitize.reveal(code, as: .code) }

    private func copy() {
        onCopy(Sanitize.copyText(code))
        withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { copied = true }
        AccessibilityNotification.Announcement("Copied").post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.copiedFor))
            withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { copied = false }
        }
    }
}
