import RelayCore
import SwiftUI

/// Design/Notice: one one-off failure or piece of news, with an
/// optional action and a Dismiss button. VoiceOver announces it when it appears.
///
/// `text` is already sanitized (`PanelNotice.text`), so it is shown as is.
public struct Notice: View {
    let kind: NoticeKind
    let text: String
    let actionTitle: String?
    let onAction: () -> Void
    let onDismiss: () -> Void

    public init(kind: NoticeKind, text: String, actionTitle: String?, onAction: @escaping () -> Void,
                onDismiss: @escaping () -> Void) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: Self.symbol(kind))
                        .foregroundStyle(kind == .error ? DS.Color.error : DS.Color.secondary)
                }
                .font(DS.Font.prose)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                Spacer(minLength: 0)
                if let actionTitle {
                    Button(actionTitle, action: onAction).controlSize(DS.Control.form).fixedSize()
                }
                IconButton(DS.Symbol.hide, label: "Dismiss", action: onDismiss)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }

    public static func symbol(_ kind: NoticeKind) -> String { kind == .error ? DS.Symbol.error : DS.Symbol.info }
}
