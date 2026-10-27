import RelayCore
import SwiftUI

/// Design/Notice: one one-off failure or piece of news, with an
/// optional action, an optional "?" and a Dismiss button. VoiceOver announces it when it appears.
///
/// `text` is already sanitized (`PanelNotice.text`), so it is shown as is.
public struct Notice: View {
    let kind: NoticeKind
    let text: String
    let actionTitle: String?
    let help: String?
    let secondaryTitle: String?
    let onAction: () -> Void
    let onSecondary: () -> Void
    let onDismiss: () -> Void

    public init(kind: NoticeKind, text: String, actionTitle: String?, help: String? = nil,
                secondaryTitle: String? = nil, onSecondary: @escaping () -> Void = {},
                onAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
        self.help = help
        self.secondaryTitle = secondaryTitle
        self.onAction = onAction
        self.onSecondary = onSecondary
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GroupBox {
            if let secondaryTitle, let actionTitle {
                // Two buttons don't fit beside the text at panel width: they get their own line.
                VStack(alignment: .trailing, spacing: DS.Space.inline) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                        label
                        Spacer(minLength: 0)
                        if let help { HelpButton(rowLabel: "Notice", text: help) }
                        IconButton(DS.Symbol.hide, label: "Dismiss", action: onDismiss)
                    }
                    HStack(spacing: DS.Space.inline) {
                        Button(secondaryTitle, action: onSecondary).controlSize(DS.Control.form).fixedSize()
                        Button(actionTitle, action: onAction).controlSize(DS.Control.form).fixedSize()
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    label
                    Spacer(minLength: 0)
                    if let help { HelpButton(rowLabel: "Notice", text: help) }
                    if let actionTitle {
                        Button(actionTitle, action: onAction).controlSize(DS.Control.form).fixedSize()
                    }
                    IconButton(DS.Symbol.hide, label: "Dismiss", action: onDismiss)
                }
            }
        }
        .modifier(NoticeSizing())
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }

    private var label: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: Self.symbol(kind))
                .foregroundStyle(kind == .error ? DS.Color.error : DS.Color.secondary)
        }
        .font(DS.Font.prose)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    public static func symbol(_ kind: NoticeKind) -> String { kind == .error ? DS.Symbol.error : DS.Symbol.info }
}

/// How a Notice takes its height in the panel's column: always its whole content at the width
/// it is given (every line of text, the button row in full), and before the List below it.
/// Without this the GroupBox could be offered less than its content when the column was
/// short of room; its content then spilled out of both edges, cut off under the header and
/// drawn over the List, worst for the two-button Notice whose buttons sit on their own line.
struct NoticeSizing: ViewModifier {
    /// The stack gives the Notice its room before the List, which takes what is left.
    static let priority: Double = 1

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(Self.priority)
    }
}
