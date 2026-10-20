import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The first-launch window: "Where do asks come from?". Start writes
/// the config; AppDelegate closes this window once a config resolves to a source,
/// whether Start wrote it or install.sh did.
@MainActor final class WelcomeWindowController {
    private let window: NSWindow

    init(model: AppModel) {
        window = NSWindow(contentViewController: SettingsWindowController.hosting(WelcomeView(model: model)))
        window.title = "Welcome to Relay"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @State private var choice: SourceKind = .local
    @State private var address = ""
    @State private var tokenFile = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Relay")
                    .font(.title2.weight(.semibold))
                Text("Where do asks come from?")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RadioButton(title: "This Mac only", isOn: choice == .local) { pick(.local) }
                        .fixedSize()
                    HelpButton(QueueHelp.local)
                }
                HStack(spacing: 6) {
                    RadioButton(title: "Mailbox", isOn: choice == .mailbox) { pick(.mailbox) }
                        .fixedSize()
                    HelpButton(QueueHelp.mailbox)
                }
                if choice == .mailbox {
                    Form {
                        TextField("Address:", text: $address, prompt: Text(verbatim: "https://mailbox.example:8790"))
                        LabeledContent("Token file:") {
                            HStack(spacing: 8) {
                                TextField("Token file:", text: $tokenFile, prompt: Text("Path to the file that holds the token"))
                                    .labelsHidden()
                                Button("Choose…") {
                                    if let path = AppModel.chooseTokenFile() { tokenFile = path }
                                }
                            }
                        }
                    }
                    .formStyle(.columns)
                    .padding(.leading, 20)
                }
            }

            if let problem {
                Text(verbatim: problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    private func pick(_ kind: SourceKind) {
        choice = kind
        problem = nil
    }

    /// Writes merge into config.json (created when absent). The window
    /// closes when AppDelegate applies the result.
    private func start() {
        switch choice {
        case .local:
            model.save(set: ["source": SourceKind.local.rawValue])
        case .mailbox:
            if let reason = { let e = MailboxDraft(address: address, tokenFile: tokenFile).errors(); return e.address ?? e.tokenFile }() {
                problem = reason
                return
            }
            model.save(set: [
                "source": SourceKind.mailbox.rawValue,
                "mailboxURL": address.trimmingCharacters(in: .whitespacesAndNewlines),
                "tokenFile": tokenFile.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        problem = model.configNote
    }
}

// MARK: Layout for the 0.5 Settings tabs and Welcome; it goes when they are replaced

/// The native "?" button. A click shows `text` in a popover, so explanations stay
/// out of sight until asked for.
struct HelpButton: NSViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.bezelStyle = .helpButton
        button.setAccessibilityLabel("Help")
        context.coordinator.text = text
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.text = text
    }

    @MainActor final class Coordinator: NSObject {
        var text = ""
        private var popover: NSPopover?

        @objc func toggle(_ sender: NSButton) {
            if let popover, popover.isShown {
                popover.performClose(sender)
                return
            }
            let content = NSHostingController(rootView:
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12))
            content.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = content
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}

/// The Settings tabs' shared layout: a two-column grid with
/// right-aligned labels, and the window's padding and width.
enum SettingsLayout {
    static let padding: CGFloat = 24
    static let width: CGFloat = 560
    /// Between controls stacked inside one row (a radio pair, an error line).
    static let stackSpacing: CGFloat = 8
    /// Extra space above the first row of a logical group.
    static let groupGap: CGFloat = 8
}

/// The form grid. Its rows are `SettingsRow`s.
struct SettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
            content
        }
    }
}

/// One form row: the label, right-aligned in the first column, then its controls.
/// `newGroup` adds the group gap above it.
struct SettingsRow<Content: View>: View {
    private let label: String
    private let newGroup: Bool
    private let content: Content

    init(_ label: String, newGroup: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.newGroup = newGroup
        self.content = content()
    }

    var body: some View {
        GridRow {
            // Both cells get the gap, so the label and the control keep sharing the
            // first-text baseline.
            Text(verbatim: label)
                .gridColumnAlignment(.trailing)
                .padding(.top, newGroup ? SettingsLayout.groupGap : 0)
            content
                .padding(.top, newGroup ? SettingsLayout.groupGap : 0)
        }
    }
}

extension View {
    /// A taller rounded-border text field.
    func settingsField() -> some View {
        textFieldStyle(.roundedBorder).controlSize(.large)
    }

    /// A tab's padding and width.
    func settingsPage() -> some View {
        padding(SettingsLayout.padding)
            .frame(width: SettingsLayout.width, alignment: .leading)
    }
}

/// A native radio button. SwiftUI's radio-group picker can't put a "?" next to
/// each option, so each option is its own NSButton and `isOn` keeps them exclusive.
struct RadioButton: NSViewRepresentable {
    let title: String
    let isOn: Bool
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.clicked(_:)))
        button.setContentHuggingPriority(.required, for: .horizontal)
        configure(button, context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button, context.coordinator)
    }

    private func configure(_ button: NSButton, _ coordinator: Coordinator) {
        button.title = title
        button.state = isOn ? .on : .off
        coordinator.isOn = isOn
        coordinator.action = action
    }

    @MainActor final class Coordinator: NSObject {
        var isOn = false
        var action: (@MainActor () -> Void)?

        /// AppKit turns a clicked radio on by itself; the state is put back to what
        /// SwiftUI says, which the re-render then updates if the action changed it.
        @objc func clicked(_ sender: NSButton) {
            action?()
            sender.state = isOn ? .on : .off
        }
    }
}
