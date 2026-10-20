import AppKit
import RelayCore
import SwiftUI

/// Welcome (§4.9): page 1 picks the source; page 2 offers the shortcut, notifications,
/// Claude Code and login. 480 pt wide, a grouped Form, pages switched in place.
public struct WelcomeView<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @State private var flow: WelcomeFlow
    @State private var choice: SourceKind = .local
    @State private var attempted = false
    private let onDone: () -> Void
    private let onQuit: () -> Void

    public init(model: Model, onDone: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.init(model: model, initialFlow: WelcomeFlow(), onDone: onDone, onQuit: onQuit)
    }

    /// The gallery opens page 2 or the error state directly.
    public init(model: Model, initialFlow: WelcomeFlow, onDone: @escaping () -> Void, onQuit: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _flow = State(initialValue: initialFlow)
        // The first frame already shows the saved source's fields, so the window opens at its height.
        _choice = State(initialValue: QueueSourceRadio.saved(model.settings.config))
        self.onDone = onDone
        self.onQuit = onQuit
    }

    private var home: String { NSHomeDirectory() }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.section) {
            Text(flow.page == .source ? "Welcome to Relay" : "Relay is ready")
                .font(DS.Font.welcomeTitle)
                .accessibilityAddTraits(.isHeader)
                .padding([.top, .horizontal], DS.Space.section)
            Form {
                if flow.page == .source { sourcePage } else { readyPage }
            }
            .formStyle(.grouped)
            // The title and buttons sit outside the Form, on the window background: one surface.
            .scrollContentBackground(.hidden)
            .controlSize(DS.Control.form)
            .scrollDisabled(true)
            // A grouped Form fills any height offered; Welcome is as tall as its rows.
            .fixedSize(horizontal: false, vertical: true)
            buttons
                .padding([.bottom, .horizontal], DS.Space.section)
        }
        .frame(width: DS.Metric.welcomeWidth)
        .onAppear(perform: prefill)
        .onChange(of: model.settings.config) { _, config in
            switch config?.resolvedSource() {
            case .local?, .mailbox?: flow.configResolved()
            default: break
            }
        }
    }

    @ViewBuilder private var sourcePage: some View {
        Section("Where do asks come from?") {
            SettingsRow("Asks come from", help: QueueHelp.source) {
                Picker("Asks come from", selection: $choice) {
                    Text("This Mac only").tag(SourceKind.local)
                    Text("Mailbox").tag(SourceKind.mailbox)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
            }
            if choice == .mailbox {
                let errors = attempted ? model.draft.errors() : (address: nil, tokenFile: nil)
                MailboxFields(address: $model.draft.address, tokenFile: $model.draft.tokenFile,
                              context: $model.draft.context, addressError: errors.address,
                              tokenFileError: errors.tokenFile,
                              onChooseTokenFile: { model.perform(.chooseTokenFile) })
            }
            if let error = flow.error {
                SettingsRow("", error: error) { EmptyView() }
            }
        }
    }

    @ViewBuilder private var readyPage: some View {
        Section {
            SettingsRow("Show or hide Relay", error: model.settings.shortcutProblem?.text) {
                ShortcutField(label: model.settings.shortcutLabel ?? "Not set",
                              onBegin: { model.perform(.beginShortcut) },
                              onRecord: { model.perform(.recordShortcut($0)) },
                              onCancel: { model.perform(.cancelShortcut) },
                              onClear: { model.perform(.clearShortcut) })
            }
            SettingsRow("Notifications") { PermissionControl(model: model) }
            SettingsRow("Claude Code") {
                Button("Connect Settings…") { model.perform(.switchTab(.connect)) }
            }
            SettingsRow("Login", error: model.settings.login.error) {
                Toggle("Start Relay when I log in", isOn: Binding(
                    get: { model.settings.login.on }, set: { model.perform(.setLogin($0)) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: DS.Space.inline) {
            if flow.page == .source {
                Button("Quit Relay", action: onQuit)
                    .keyboardShortcut("q", modifiers: .command)
                Spacer()
                if flow.starting {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Connecting")
                }
                Button("Start", action: start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(DS.Control.action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.starting)
            } else {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(DS.Control.action)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Page 1 is prefilled from the current config (`source`, `mailboxURL`, `tokenFile`, `context`).
    private func prefill() {
        let config = model.settings.config
        choice = QueueSourceRadio.saved(config)
        if model.draft == MailboxDraft() { model.draft = MailboxDraft(config: config, home: home) }
    }

    private func start() {
        guard choice == .mailbox else {
            model.save(set: ["source": SourceKind.local.rawValue], remove: [])
            // save refreshes the snapshot synchronously: onApply on success, the note on failure.
            let saveProblem = model.settings.connectionProblems.first { $0.hasPrefix("Couldn't save config.json") }
            if model.settings.config?.resolvedSource() == .local, saveProblem == nil {
                flow.startTapped(isMailbox: false)
            } else {
                flow.saveFailed(saveProblem ?? "Couldn't save config.json")
            }
            return
        }
        attempted = true
        let errors = model.draft.errors()
        guard errors.address == nil, errors.tokenFile == nil else { return }
        flow.startTapped(isMailbox: true)
        Task { @MainActor in
            let reason = await model.connect()     // waits up to WelcomeFlow.firstListTimeout
            if reason == MailboxDraft.noAnswer {
                flow.timedOut()
            } else {
                flow.firstList(ok: reason == nil, reason: reason)
            }
        }
    }
}
