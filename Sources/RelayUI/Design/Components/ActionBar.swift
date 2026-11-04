import RelayCore
import SwiftUI

/// What the detail's bottom bar shows.
public enum ActionBarMode: Equatable, Sendable {
    /// Skip and the prominent primary button.
    case open(PrimaryAction)
    /// A labelled spinner while the close is sent; both buttons disabled.
    case busy(PrimaryAction)
    /// Done was pressed with something unsent: the warning caption, Discard & Done and the
    /// prominent Send & Done (⌘↩). Esc, through the key router, goes back to editing.
    /// `busy` while Send & Done is sending: a spinner and both buttons disabled.
    case warning(UnsentKind, busy: Bool)
    /// The closed line ("Done by you · …") and Reopen.
    case closed(String)
}

/// What the bar says beside its buttons: the caption (the unanswered count, R6, or the
/// warning's "You have an unsent answer"), and a failed send's reason, which replaces it.
public struct ActionBarAnswers: Equatable, Sendable {
    public var caption: String?
    public var failure: String?

    public init(caption: String? = nil, failure: String? = nil) {
        self.caption = caption
        self.failure = failure
    }

    public static let none = ActionBarAnswers()
}

/// One of the bar's buttons, as drawn (`ActionBar.buttons`).
public struct BarButton: Equatable, Sendable {
    public enum Role: Hashable, Sendable { case skip, primary, discard, sendAndDone }
    public var role: Role
    public var title: String
    public var enabled: Bool
    public var help: String
    /// VoiceOver's hint: why the button is off; nil while it's on.
    public var hint: String?
    public var prominent: Bool
}

/// Design/ActionBar: the detail's bottom bar, Skip and Done only: every reply and question
/// has its own Send. Done with something unsent never sends or drops it silently: the bar
/// switches to its warning (Send & Done, Discard & Done). The open state carries ⌘↩ and ⌘⌫;
/// ⌘S (send every unsent answer) and ⇧⌘R (Reopen) go through the panel's key router.
/// A caption or failure that doesn't fit beside the buttons goes on its own line above them.
/// Every button is at least `DS.Metric.barButtonMinWidth` wide (owner pick 1). On an ask whose
/// Done waits for required items (Pond 1.3.0), Done stays prominent but off, with `doneHelp` as
/// its help and VoiceOver hint, and no caption says what's left; Skip is never off.
public struct ActionBar: View {
    let mode: ActionBarMode
    let answers: ActionBarAnswers
    let doneEnabled: Bool
    /// The warning's Discard & Done: off when only the unsent drafts would finish what's left.
    let discardEnabled: Bool
    /// Why Done is off.
    let doneHelp: String
    let onSkip: () -> Void
    let onPrimary: () -> Void
    let onReopen: () -> Void
    /// The warning's Send & Done.
    let onSendAndDone: () -> Void
    /// The warning's Discard & Done.
    let onDiscard: () -> Void

    public init(mode: ActionBarMode, answers: ActionBarAnswers = .none, doneEnabled: Bool = true,
                discardEnabled: Bool = true, doneHelp: String = "", onSkip: @escaping () -> Void,
                onPrimary: @escaping () -> Void, onReopen: @escaping () -> Void,
                onSendAndDone: @escaping () -> Void = {}, onDiscard: @escaping () -> Void = {}) {
        self.mode = mode
        self.answers = answers
        self.doneEnabled = doneEnabled
        self.discardEnabled = discardEnabled
        self.doneHelp = doneHelp
        self.onSkip = onSkip
        self.onPrimary = onPrimary
        self.onReopen = onReopen
        self.onSendAndDone = onSendAndDone
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                switch mode {
                case let .open(action):
                    withNote { buttons(action, keyed: true) }
                case let .busy(action):
                    withNote(busy: true) { buttons(action, keyed: false).disabled(true) }
                case let .warning(_, busy):
                    withNote(busy: busy) { warningButtons(keyed: !busy).disabled(busy) }
                case let .closed(text):
                    HStack(spacing: DS.Space.inline) {
                        Text(text).font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit()
                        Spacer()
                        Button("Reopen", action: onReopen).help(Self.reopenHelp)
                    }
                }
            }
            .controlSize(DS.Control.action)
            .padding(.horizontal, DS.Space.gutter)
            .frame(minHeight: DS.Metric.actionBar)
            .background(DS.Color.bar)
        }
    }

    /// The caption or failure, then the buttons: on one row when it fits, else the note
    /// on a line of its own above them.
    @ViewBuilder private func withNote(busy: Bool = false, @ViewBuilder _ buttons: () -> some View) -> some View {
        if let note = noteText {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.inline) {
                    if busy { spinner }
                    noteView(note).lineLimit(1).fixedSize()
                    Spacer(minLength: DS.Space.inline)
                    buttons()
                }
                VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                    noteView(note).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.inline) {
                        if busy { spinner }
                        Spacer(minLength: 0)
                        buttons()
                    }
                }
                .padding(.vertical, DS.Space.barStackV)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: DS.Space.inline) {
                if busy { spinner }
                Spacer()
                buttons()
            }
        }
    }

    private var spinner: some View {
        ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
    }

    private var noteText: String? { answers.failure ?? answers.caption }

    private var isWarning: Bool {
        if case .warning = mode { return true }
        return false
    }

    /// The caption in secondary; the warning's with its symbol, in the primary colour; a
    /// failure in red.
    @ViewBuilder private func noteView(_ text: String) -> some View {
        if answers.failure != nil {
            Text(verbatim: text).font(DS.Font.caption).foregroundStyle(DS.Color.error)
        } else if isWarning {
            Label {
                Text(verbatim: text).font(DS.Font.caption).foregroundStyle(DS.Color.primary)
            } icon: {
                Image(systemName: DS.Symbol.warning).foregroundStyle(DS.Color.warn).accessibilityHidden(true)
            }
            .font(DS.Font.caption)
        } else {
            Text(verbatim: text).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
        }
    }

    /// Skip and the primary, or the warning's Discard & Done and Send & Done, as drawn: Done
    /// (and Send & Done) off with `doneHelp` while `doneEnabled` is false, Discard & Done off
    /// with it while `discardEnabled` is false. Skip is always on. None on a closed ask.
    public static func buttons(_ mode: ActionBarMode, doneEnabled: Bool, discardEnabled: Bool,
                               doneHelp: String) -> [BarButton] {
        func gated(_ role: BarButton.Role, _ title: String, on: Bool, help: String, prominent: Bool) -> BarButton {
            BarButton(role: role, title: title, enabled: on, help: on ? help : doneHelp, hint: on ? nil : doneHelp,
                      prominent: prominent)
        }
        switch mode {
        case .open(let action), .busy(let action):
            return [BarButton(role: .skip, title: "Skip", enabled: true, help: skipHelp, hint: nil, prominent: false),
                    gated(.primary, action.title, on: doneEnabled, help: primaryHelp(action), prominent: true)]
        case .warning:
            return [gated(.discard, discardTitle, on: discardEnabled, help: discardHelp, prominent: false),
                    gated(.sendAndDone, sendAndDoneTitle, on: doneEnabled, help: sendAndDoneHelp, prominent: true)]
        case .closed:
            return []
        }
    }

    /// Skip and the primary. Only `.open` carries ⌘⌫ and ⌘↩ (busy is disabled, closed has
    /// no primary). The panel's key router consumes them before the view hierarchy, so ⌘↩
    /// and ⌘⌫ never fire inside a text field.
    @ViewBuilder private func buttons(_ action: PrimaryAction, keyed: Bool) -> some View {
        ForEach(Self.buttons(.open(action), doneEnabled: doneEnabled, discardEnabled: discardEnabled,
                             doneHelp: doneHelp), id: \.role) { item in
            barButton(item, keyed: keyed)
        }
    }

    /// Discard & Done, then the prominent Send & Done (⌘↩). Discard takes no key on purpose.
    @ViewBuilder private func warningButtons(keyed: Bool) -> some View {
        ForEach(Self.buttons(.warning(.answer, busy: false), doneEnabled: doneEnabled, discardEnabled: discardEnabled,
                             doneHelp: doneHelp), id: \.role) { item in
            barButton(item, keyed: keyed)
        }
    }

    /// One button, its label at least `barButtonMinWidth` wide.
    @ViewBuilder private func barButton(_ item: BarButton, keyed: Bool) -> some View {
        let button = Button(action: action(item.role)) {
            Text(verbatim: item.title)
                .frame(minWidth: DS.Metric.barButtonMinWidth)
                .alignmentProbe(.barButton, measure: .frame)
        }
        .help(item.help)
        .accessibilityHint(item.hint ?? "")
        .disabled(!item.enabled)
        .keyboardShortcut(keyed ? Self.shortcut(item.role) : nil)
        if item.prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func action(_ role: BarButton.Role) -> () -> Void {
        switch role {
        case .skip: return onSkip
        case .primary: return onPrimary
        case .discard: return onDiscard
        case .sendAndDone: return onSendAndDone
        }
    }

    /// ⌘⌫ for Skip, ⌘↩ for the primary and Send & Done; Discard & Done takes none.
    static func shortcut(_ role: BarButton.Role) -> KeyboardShortcut? {
        switch role {
        case .skip: return KeyboardShortcut(.delete, modifiers: .command)
        case .primary, .sendAndDone: return KeyboardShortcut(.return, modifiers: .command)
        case .discard: return nil
        }
    }

    public static func primaryHelp(_ action: PrimaryAction) -> String {
        action == .done ? "Done (⌘↩)" : "Done: asks first, as something is unsent (⌘↩)"
    }

    public static let sendAndDoneTitle = "Send & Done"
    public static let discardTitle = "Discard & Done"
    public static let sendAndDoneHelp = "Send what is unsent, then close (⌘↩). Esc goes back to editing."
    public static let discardHelp = "Close without sending; the unsent text and picks go. Esc goes back to editing."

    public static let skipHelp = "Skip (⌘⌫)"
    public static let reopenHelp = "Reopen (⇧⌘R)"
}
