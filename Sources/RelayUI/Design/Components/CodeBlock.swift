import RelayCore
import SwiftUI

/// Design/CodeBlock: a command, wrapped (never scrolled sideways), with
/// hidden characters revealed as "⟨U+XXXX⟩" and a Copy button that copies exactly what is shown.
public struct CodeBlock: View {
    let code: String
    let copyLabel: String
    let lang: String?
    let onCopy: (String) -> CopyOutcome
    /// What the last click did, shown on the button for `copiedFor`; nil before one.
    @State private var outcome: CopyOutcome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askContentLocked) private var contentLocked

    /// `outcome` seeds the state, for the gallery's "Copied" and refused samples. `onCopy` receives
    /// `Sanitize.copyText(code)`, the text to put on the pasteboard, and says whether it went there:
    /// a guarded copy is refused when a correction landed between render and click.
    public init(code: String, copyLabel: String, lang: String? = nil, outcome: CopyOutcome? = nil,
                onCopy: @escaping (String) -> CopyOutcome) {
        self.code = code
        self.copyLabel = copyLabel
        self.lang = lang
        self.onCopy = onCopy
        _outcome = State(initialValue: outcome)
    }

    public var body: some View {
        let (shown, hidden) = Self.shown(code)
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(verbatim: shown)
                    .font(DS.Font.code)
                    .multilineTextAlignment(.leading)   // a grouped Form's trailing column would right-align it
                    .askTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Self.codeLabel(lang: lang))
                    .accessibilityValue(shown)
                Button(Self.copyTitle(outcome: outcome, hidden: hidden)) { copy() }
                    .disabled(!Self.allowsCopy(locked: contentLocked))
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
    /// "Copy", "Copy as Shown", then "Copied" or, when the copy was refused, `CopyOutcome.refusedText`.
    public static func copyTitle(outcome: CopyOutcome?, hidden: Bool) -> String {
        outcome.map(announcement) ?? (hidden ? "Copy as Shown" : "Copy")
    }
    /// What VoiceOver hears after a copy, from the button or the step's "Copy command" action.
    public static func announcement(_ outcome: CopyOutcome) -> String {
        outcome == .copied ? "Copied" : CopyOutcome.refusedText
    }
    public static func codeLabel(lang: String?) -> String { lang.map { "Command, " + line($0) } ?? "Command" }
    public static func shown(_ code: String) -> (text: String, hidden: Bool) { Sanitize.reveal(code, as: .code) }
    /// While the ask's content is locked the command can't be selected or copied.
    public static func allowsSelection(locked: Bool) -> Bool { AskContentLock.allowsSelection(locked: locked) }
    public static func allowsCopy(locked: Bool) -> Bool { AskContentLock.allowsCopy(locked: locked) }

    private func copy() {
        guard Self.allowsCopy(locked: contentLocked) else { return }
        let result = onCopy(Sanitize.copyText(code))
        withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { outcome = result }
        AccessibilityNotification.Announcement(Self.announcement(result)).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.copiedFor))
            withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { outcome = nil }
        }
    }
}
