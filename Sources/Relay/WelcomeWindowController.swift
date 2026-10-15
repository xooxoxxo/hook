import AppKit
import RelayCore
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
                    HelpButton(QueueTab.localHelp)
                }
                HStack(spacing: 6) {
                    RadioButton(title: "Mailbox", isOn: choice == .mailbox) { pick(.mailbox) }
                        .fixedSize()
                    HelpButton(QueueTab.mailboxHelp)
                }
                if choice == .mailbox {
                    Form {
                        TextField("Address:", text: $address, prompt: Text(verbatim: "https://mailbox.example:8790"))
                        LabeledContent("Token file:") {
                            HStack(spacing: 8) {
                                TextField("Token file:", text: $tokenFile, prompt: Text("Path to the file that holds the token"))
                                    .labelsHidden()
                                Button("Choose…") {
                                    if let path = QueueTab.chooseTokenFile() { tokenFile = path }
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
            if let reason = QueueTab.mailboxProblem(address: address, tokenFile: tokenFile) {
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
