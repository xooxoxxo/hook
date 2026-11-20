import RelayCore
import SwiftUI

/// Design/Notice: one one-off failure or piece of news, with an
/// optional action, an optional "?" and a Dismiss button. VoiceOver announces it when it appears.
///
/// `text` is already sanitized (`PanelNotice.text`), so it is shown as is.
public struct Notice: View {
    let compact: Bool
    let kind: NoticeKind
    let text: String
    let summary: String?
    let collapses: Bool
    let actionTitle: String?
    let help: String?
    let secondaryTitle: String?
    let secondaryConfirmation: NoticeConfirmation?
    /// The action is the one to take, the second button the fallback: it gets the prominent style.
    let actionProminent: Bool
    let onAction: () -> Void
    let onSecondary: () -> Void
    let onDismiss: () -> Void
    @State private var expanded: Bool
    @State private var confirming = false

    /// `collapses` (with a `summary`) folds the Notice to one line with Details; `expanded`
    /// opens it at first (the gallery's open state).
    public init(compact: Bool = false, kind: NoticeKind, text: String, summary: String? = nil, collapses: Bool = false,
                expanded: Bool = false, actionTitle: String?, help: String? = nil,
                secondaryTitle: String? = nil, secondaryConfirmation: NoticeConfirmation? = nil,
                actionProminent: Bool = false, onSecondary: @escaping () -> Void = {},
                onAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.compact = compact
        self.kind = kind
        self.text = text
        self.summary = summary
        self.collapses = collapses && summary != nil
        self.actionTitle = actionTitle
        self.help = help
        self.secondaryTitle = secondaryTitle
        self.secondaryConfirmation = secondaryConfirmation
        self.actionProminent = actionProminent
        self.onAction = onAction
        self.onSecondary = onSecondary
        self.onDismiss = onDismiss
        _expanded = State(initialValue: expanded)
    }

    /// The panel's Notice, with its texts, buttons and layout.
    public init(_ notice: PanelNotice, expanded: Bool = false, onAction: @escaping () -> Void,
                onSecondary: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.init(compact: notice.isCompact, kind: notice.kind, text: notice.text, summary: notice.summary,
                  collapses: notice.collapses, expanded: expanded, actionTitle: notice.actionTitle, help: notice.help,
                  secondaryTitle: notice.secondaryActionTitle, secondaryConfirmation: notice.secondaryConfirmation,
                  actionProminent: notice.actionIsPrimary, onSecondary: onSecondary, onAction: onAction, onDismiss: onDismiss)
    }

    public var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: DS.Space.inline) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                        label
                        Spacer(minLength: 0)
                        IconButton(DS.Symbol.hide, label: "Dismiss", action: onDismiss)
                    }
                    if let actionTitle {
                        Button(actionTitle, action: onAction).controlSize(DS.Control.form)
                    }
                }
            } else if collapses, let summary {
                foldingNotice(summary)
            } else {
                fullNotice
            }
        }
        .helpLabelStyle(.prose)
        .modifier(NoticeSizing())
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(collapses ? summary ?? text : text).post() }
        .onChange(of: text) { _, _ in expanded = false }
        .confirmationDialog(secondaryConfirmation?.title ?? "", isPresented: $confirming, titleVisibility: .visible) {
            if let secondaryConfirmation {
                Button(secondaryConfirmation.confirmTitle, role: .destructive, action: onSecondary)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let secondaryConfirmation { Text(secondaryConfirmation.message) }
        }
    }

    /// The second button: straight away, or after its confirmation.
    private func secondary() {
        if secondaryConfirmation != nil { confirming = true } else { onSecondary() }
    }

    /// Folded: the icon, the summary, Details and Dismiss on one line. Open: the whole text at
    /// full width under that line, and the buttons on their own row below it, so no button
    /// ever squeezes the text.
    private func foldingNotice(_ summary: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Label {
                        Text(summary)
                    } icon: {
                        Image(systemName: Self.symbol(kind))
                            .foregroundStyle(kind == .error ? DS.Color.error : DS.Color.secondary)
                    }
                    .font(DS.Font.prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    Spacer(minLength: 0)
                    detailsButton
                    IconButton(DS.Symbol.hide, label: "Dismiss", action: onDismiss)
                }
                if expanded {
                    // A Label with the icon hidden, so the text starts where the summary's does.
                    Label {
                        Text(text)
                            .lineLimit(Self.maxLines)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .help(text)
                    } icon: {
                        Image(systemName: Self.symbol(kind)).hidden()
                    }
                    .font(DS.Font.prose)
                    .accessibilityElement(children: .combine)
                    if actionTitle != nil || secondaryTitle != nil || help != nil {
                        HStack(spacing: DS.Space.inline) {
                            if let help { HelpButton(rowLabel: "Notice", text: help) }
                            Spacer(minLength: 0)
                            if let secondaryTitle {
                                Button(secondaryTitle, action: secondary).controlSize(DS.Control.form).fixedSize()
                            }
                            if let actionTitle { actionButton(actionTitle) }
                        }
                    }
                }
            }
        }
    }

    /// The action beside a second button: prominent when it is the one to take.
    @ViewBuilder private func actionButton(_ title: String) -> some View {
        if actionProminent {
            Button(title, action: onAction).buttonStyle(.borderedProminent).controlSize(DS.Control.form).fixedSize()
        } else {
            Button(title, action: onAction).controlSize(DS.Control.form).fixedSize()
        }
    }

    /// "Details" with a chevron that turns down while open.
    private var detailsButton: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: DS.Space.stateLabel) {
                Text("Details")
                Image(systemName: expanded ? DS.Symbol.disclosureOpen : DS.Symbol.disclosureClosed)
                    .imageScale(.small)
            }
            .font(DS.Font.prose)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Details")
        .accessibilityValue(TrailingDisclosureStyle.value(expanded: expanded))
    }

    private var fullNotice: some View {
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
                        Button(secondaryTitle, action: secondary).controlSize(DS.Control.form).fixedSize()
                        actionButton(actionTitle)
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

    }

    private var label: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: Self.symbol(kind))
                .foregroundStyle(kind == .error ? DS.Color.error : DS.Color.secondary)
        }
        .font(DS.Font.prose)
        .lineLimit(Self.maxLines)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .help(text)
    }

    /// Enough for every notice Hook writes; a long error reason from a server stops here
    /// (the full text is in the tooltip) instead of squeezing the list away.
    public static let maxLines = 10

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
