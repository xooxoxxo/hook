import RelayCore
import SwiftUI

extension Notification.Name {
    /// ⌘L: the panel's key router asks the open detail to focus its reply field.
    public static let relayFocusReply = Notification.Name("relay.panel.focusReply")
}

/// The Reply section. The draft and the picked choice live in the model, in
/// memory only, so they survive back, another ask and a poll; the send state and the sent
/// choices come from the snapshot (reply events), never from view state.
struct DetailReply<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let snapshot: DetailSnapshot
    let spec: ReplySpec
    let closed: Bool
    private let isFocused: FocusState<Bool>.Binding
    @State private var replyAnyway = false

    init(model: Model, snapshot: DetailSnapshot, spec: ReplySpec, closed: Bool, isFocused: FocusState<Bool>.Binding) {
        _model = ObservedObject(wrappedValue: model)
        self.snapshot = snapshot
        self.spec = spec
        self.closed = closed
        self.isFocused = isFocused
    }

    /// An empty field keeps no draft (no pencil on the row); anything typed, blanks included, is kept.
    static func storedDraft(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private var draft: Binding<String> {
        let id = snapshot.id
        return Binding(get: { model.drafts[id] ?? "" }, set: { model.drafts[id] = Self.storedDraft($0) })
    }

    private var picked: Binding<Int?> {
        let id = snapshot.id
        return Binding(get: { model.pendingChoice[id] }, set: { model.pendingChoice[id] = $0 })
    }

    var body: some View {
        if closed {
            // The primary button is Reopen, so ⌘↩ does nothing here; Return in the field still sends.
            DisclosureGroup("Reply anyway", isExpanded: $replyAnyway) {
                VStack(alignment: .leading, spacing: DS.Space.inline) {
                    Text("The session may have finished. It sees this only if it checks replies.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    control(showHeading: false)
                }
                .padding(.top, DS.Space.stepPart)
            }
        } else {
            control(showHeading: true)
        }
    }

    @ViewBuilder private func control(showHeading: Bool) -> some View {
        if let choices = spec.choices, !choices.isEmpty {
            ChoiceGroup(prompt: spec.prompt, choices: choices, picked: picked,
                        sent: snapshot.sentChoices, latestSent: snapshot.latestSentChoice,
                        sending: snapshot.reply == .sending, showHeading: showHeading,
                        onSend: { model.sendChoice(snapshot.id) })
        } else {
            ReplyBox(prompt: spec.prompt, text: draft, state: snapshot.reply, showHeading: showHeading,
                     isFocused: isFocused,
                     onSend: { model.sendReply(snapshot.id) },
                     onRetry: { model.sendReply(snapshot.id) })
        }
    }
}
