import RelayCore
import SwiftUI

/// What the detail's bottom bar shows.
public enum ActionBarMode: Equatable, Sendable {
    /// Skip and the prominent primary button.
    case open(PrimaryAction)
    /// A labelled spinner while the close is sent; both buttons disabled.
    case busy(PrimaryAction)
    /// The closed line ("Done by you · …") and Reopen.
    case closed(String)
}

/// What the bar says beside its buttons: the caption ("Done sends your answer first", or the
/// unanswered count, R6), and a failed send's reason, which replaces the caption.
public struct ActionBarAnswers: Equatable, Sendable {
    public var caption: String?
    public var failure: String?

    public init(caption: String? = nil, failure: String? = nil) {
        self.caption = caption
        self.failure = failure
    }

    public static let none = ActionBarAnswers()
}

/// Design/ActionBar: the detail's bottom bar, Skip and Done only: every reply and question
/// has its own Send, and Done sends what is unsent first. The open state carries ⌘↩ and ⌘⌫;
/// ⌘S (send every unsent answer) and ⇧⌘R (Reopen) go through the panel's key router.
/// A caption or failure that doesn't fit beside the buttons goes on its own line above them.
public struct ActionBar: View {
    let mode: ActionBarMode
    let answers: ActionBarAnswers
    let onSkip: () -> Void
    let onPrimary: () -> Void
    let onReopen: () -> Void

    public init(mode: ActionBarMode, answers: ActionBarAnswers = .none, onSkip: @escaping () -> Void,
                onPrimary: @escaping () -> Void, onReopen: @escaping () -> Void) {
        self.mode = mode
        self.answers = answers
        self.onSkip = onSkip
        self.onPrimary = onPrimary
        self.onReopen = onReopen
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

    private func noteView(_ text: String) -> some View {
        Text(verbatim: text)
            .font(DS.Font.caption)
            .foregroundStyle(answers.failure == nil ? DS.Color.secondary : DS.Color.error)
    }

    /// Skip and the primary. Only `.open` carries ⌘⌫ and ⌘↩ (busy is disabled, closed has
    /// no primary). The panel's key router consumes them before the view hierarchy, so ⌘↩
    /// and ⌘⌫ never fire inside a text field.
    @ViewBuilder private func buttons(_ action: PrimaryAction, keyed: Bool) -> some View {
        Button("Skip", action: onSkip)
            .help(Self.skipHelp)
            .keyboardShortcut(keyed ? KeyboardShortcut(.delete, modifiers: .command) : nil)
        Button(action.title, action: onPrimary)
            .buttonStyle(.borderedProminent)
            .help(Self.primaryHelp(action))
            .keyboardShortcut(keyed ? KeyboardShortcut(.return, modifiers: .command) : nil)
    }

    public static func primaryHelp(_ action: PrimaryAction) -> String {
        action == .done ? "Done (⌘↩)" : "Send your answer, then close (⌘↩)"
    }

    public static let skipHelp = "Skip (⌘⌫)"
    public static let reopenHelp = "Reopen (⇧⌘R)"
}
