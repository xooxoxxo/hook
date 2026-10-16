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

/// Design/ActionBar (design §4.4): the detail's bottom bar. Keys (⌘↩, ⌘⌫, ⇧⌘R) are
/// attached by the panel, not here; the help strings name them.
public struct ActionBar: View {
    let mode: ActionBarMode
    let onSkip: () -> Void
    let onPrimary: () -> Void
    let onReopen: () -> Void

    public init(mode: ActionBarMode, onSkip: @escaping () -> Void, onPrimary: @escaping () -> Void,
                onReopen: @escaping () -> Void) {
        self.mode = mode
        self.onSkip = onSkip
        self.onPrimary = onPrimary
        self.onReopen = onReopen
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DS.Space.inline) {
                switch mode {
                case let .open(action):
                    Spacer()
                    buttons(action)
                case let .busy(action):
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
                    Spacer()
                    buttons(action).disabled(true)
                case let .closed(text):
                    Text(text).font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit()
                    Spacer()
                    Button("Reopen", action: onReopen).help(Self.reopenHelp)
                }
            }
            .controlSize(DS.Control.action)
            .padding(.horizontal, DS.Space.gutter)
            .frame(height: DS.Metric.actionBar)
            .background(DS.Color.bar)
        }
    }

    @ViewBuilder private func buttons(_ action: PrimaryAction) -> some View {
        Button("Skip", action: onSkip).help(Self.skipHelp)
        Button(action.title, action: onPrimary)
            .buttonStyle(.borderedProminent)
            .help(Self.primaryHelp(action))
    }

    public static func primaryHelp(_ action: PrimaryAction) -> String {
        action == .done ? "Done (⌘↩)" : "Send and close (⌘↩)"
    }

    public static let skipHelp = "Skip (⌘⌫)"
    public static let reopenHelp = "Reopen (⇧⌘R)"
}
