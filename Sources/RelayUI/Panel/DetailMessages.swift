import RelayCore
import SwiftUI

/// The Messages section (0.12, pick 4 A), after the replies and before Links: the heading
/// with a "?", earlier messages (text and time), then the field. On an ask with a reply prompt
/// the field sits behind a "Message the session" disclosure; on a closed ask the earlier
/// messages stay, read-only, with no field. A message never answers, closes or changes anything.
/// When the ask's `done` holds "message" the field is always inline (RD 27), and until the owner
/// has sent one the section is marked: the badge after its "?" and the required hue behind it.
struct DetailMessages<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let snapshot: DetailSnapshot
    @FocusState private var focused: Bool
    @State private var disclosed = false
    @Environment(\.panelGallery) private var gallery

    init(model: Model, snapshot: DetailSnapshot) {
        _model = ObservedObject(wrappedValue: model)
        self.snapshot = snapshot
    }

    /// A Pond with messages; a closed ask only when it has some to show.
    static func shows(_ snapshot: DetailSnapshot) -> Bool {
        snapshot.canMessage && (snapshot.closedText == nil || !snapshot.messages.isEmpty)
    }

    /// The field: always on an open ask without a reply prompt, or whose Done waits for a message;
    /// behind the disclosure on any other ask with a reply prompt.
    static func fieldPlacement(_ snapshot: DetailSnapshot) -> FieldPlacement {
        guard snapshot.closedText == nil else { return .none }
        if snapshot.model?.done.contains(.message) == true { return .inline }
        return snapshot.model?.reply == nil ? .inline : .disclosed
    }

    /// The section carries the required mark: Done waits for a message and none was sent yet.
    static func marked(_ snapshot: DetailSnapshot) -> Bool { snapshot.requirements.marksMessages }

    enum FieldPlacement: Equatable { case none, inline, disclosed }

    private var draft: Binding<String> {
        let id = snapshot.id
        return Binding(get: { model.messageDrafts[id] ?? "" },
                       set: { model.messageDrafts[id] = $0.isEmpty ? nil : $0 })
    }

    private var expanded: Binding<Bool> {
        Binding(get: { gallery.messagesExpanded ?? disclosed }, set: { disclosed = $0 })
    }

    var body: some View {
        let marked = Self.marked(snapshot)
        return VStack(alignment: .leading, spacing: DS.Space.inline) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(MessageText.heading)
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                    .accessibilityValue(RequiredMark.headingValue(marked) ?? "")
                    .help(MessageText.heading + " (⌘L)")
                HelpButton(rowLabel: MessageText.heading, text: MessageText.help)
                RequiredHeadingBadge(on: marked)
            }
            if !snapshot.messages.isEmpty { RepliesList(snapshot.messages) }
            switch Self.fieldPlacement(snapshot) {
            case .none: EmptyView()
            case .inline: box
            case .disclosed:
                DisclosureGroup(isExpanded: expanded) {
                    box.padding(.top, DS.Space.stepPart)
                } label: {
                    Text(MessageText.disclosure).font(DS.Font.body)
                }
            }
        }
        .requiredSection(marked)
        // ⌘L and Message Session… ask for the field through the model; the field's own focus
        // goes back to it, so ⌘Return knows the message field is the one typing.
        .onChange(of: model.messageFocus, initial: true) { _, focus in
            guard focus == snapshot.id, Self.fieldPlacement(snapshot) != .none else { return }
            disclosed = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, on in
            if on {
                if model.messageFocus != snapshot.id { model.messageFocus = snapshot.id }
            } else if model.messageFocus == snapshot.id {
                model.messageFocus = nil
            }
        }
    }

    private var box: some View {
        MessageBox(text: draft, limits: snapshot.limits, state: snapshot.message, isFocused: $focused,
                   onSend: { model.sendMessage(snapshot.id, text: model.messageDrafts[snapshot.id] ?? "") })
    }
}
