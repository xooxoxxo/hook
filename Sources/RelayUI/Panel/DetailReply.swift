import RelayCore
import SwiftUI

extension Notification.Name {
    /// ⌘L: the panel's key router asks the open detail to focus its reply field.
    public static let relayFocusReply = Notification.Name("relay.panel.focusReply")
}

/// The Reply section. The draft and the picked choice live in the model, in
/// memory only, so they survive back, another ask and a poll; the send state and the sent
/// choices come from the snapshot (reply events), never from view state.
///
/// Once a reply is sent it folds into an answer row: the prompt on one line, "You replied:
/// … · time" and Change, earlier replies behind History. Change brings the question back
/// prefilled (editing is memory only, in the model); a sent reply folds it again. A closed
/// ask shows the row without Change, and "Reply anyway" below it.
struct DetailReply<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let snapshot: DetailSnapshot
    let spec: ReplySpec
    let closed: Bool
    private let isFocused: FocusState<Bool>.Binding
    @State private var replyAnyway = false
    @State private var historyShown = false
    @Environment(\.panelGallery) private var gallery

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

    private var editing: Bool { model.editingReply.contains(snapshot.id) }

    private var showsAnswer: Bool {
        AnswerEditing.showsReplyAnswer(replies: snapshot.replies, editing: editing,
                                       draft: model.drafts[snapshot.id], pick: model.pendingChoice[snapshot.id])
    }

    private var historyExpanded: Binding<Bool> {
        Binding(get: { gallery.historyExpanded ?? historyShown }, set: { historyShown = $0 })
    }

    var body: some View {
        content
            // Here, not in ReplyBox: a sent reply folds the box into the answer row.
            .onChange(of: snapshot.reply) { _, new in
                if case .sent = new { AccessibilityNotification.Announcement("Sent").post() }
            }
    }

    @ViewBuilder private var content: some View {
        if closed {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                if let latest = snapshot.replies.last { answer(latest, canChange: false) }
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
            }
        } else if showsAnswer, let latest = snapshot.replies.last {
            answer(latest, canChange: true)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                control(showHeading: true)
                if editing { note }
            }
        }
    }

    private var heading: some View {
        Text("Reply")
            .font(DS.Font.heading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
            .help("Reply (⌘L)")
    }

    /// The answer row in its group, the Change note under it, then History.
    private func answer(_ latest: ReplyLine, canChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            heading
            Text(verbatim: line(spec.prompt))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(line(spec.prompt))
            StepGroup {
                AnsweredRow(text: AnswerEditing.repliedText(latest), time: latest.time, prominent: true,
                            changeHelp: "Change your reply",
                            onChange: canChange ? { model.changeReply(snapshot.id) } : nil)
                    .padding(.horizontal, DS.Space.groupRowH)
                    .padding(.vertical, DS.Space.groupRowV)
            }
            if canChange { note }
            if snapshot.replies.count > 1 { history }
        }
    }

    private var note: some View {
        Text(AnswerEditing.changeNote)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The earlier replies, newest first, each with its time.
    private var history: some View {
        let earlier = Array(snapshot.replies.dropLast().reversed())
        return DisclosureGroup(isExpanded: historyExpanded) {
            RepliesList(earlier)
                .foregroundStyle(DS.Color.secondary)
                .padding(.top, DS.Space.stepPart)
        } label: {
            Text(Self.historyTitle(earlier: earlier.count))
                .font(DS.Font.body)
        }
    }

    /// "History · 1 earlier reply".
    static func historyTitle(earlier: Int) -> String {
        "History · " + (earlier == 1 ? "1 earlier reply" : "\(earlier) earlier replies")
    }

    /// Cancel goes back to the answer row; only while changing an open ask's reply.
    private var cancel: (() -> Void)? {
        guard editing, !closed, !snapshot.replies.isEmpty else { return nil }
        let id = snapshot.id
        return { model.cancelReplyChange(id) }
    }

    @ViewBuilder private func control(showHeading: Bool) -> some View {
        if let choices = spec.choices, !choices.isEmpty {
            ChoiceGroup(prompt: spec.prompt, choices: choices, picked: picked,
                        sent: snapshot.sentChoices, latestSent: snapshot.latestSentChoice,
                        sending: snapshot.reply == .sending, showHeading: showHeading, onCancel: cancel,
                        onSend: { model.sendChoice(snapshot.id) })
        } else {
            ReplyBox(prompt: spec.prompt, text: draft, state: snapshot.reply, showHeading: showHeading,
                     isFocused: isFocused, sentText: AnswerEditing.latestText(snapshot.replies), onCancel: cancel,
                     onSend: { model.sendReply(snapshot.id) },
                     onRetry: { model.sendReply(snapshot.id) })
        }
    }
}
