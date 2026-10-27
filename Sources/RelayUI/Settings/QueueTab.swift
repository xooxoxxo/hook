import Foundation
import RelayCore
import SwiftUI

/// Settings → Queue: where asks come from, that source's settings, and the
/// connection. Mailbox fields are a draft until Connect validates and saves them.
/// There is no read-only section: Queue is where config problems are fixed.
public struct QueueTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @State private var choice: SourceKind = .local
    @State private var attempted = false
    @State private var connecting = false
    @State private var sending = false
    @State private var testResult: TestAskResult?
    /// The update command being typed; saved on Return or when the field loses focus.
    @State private var updateCommand = ""
    @FocusState private var updateCommandFocused: Bool

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
        // The first frame already shows the saved source's section.
        _choice = State(initialValue: QueueSourceRadio.saved(model.settings.config))
    }

    private var home: String { NSHomeDirectory() }

    /// The draft differs from the config, or the saved source isn't a mailbox yet.
    private var isUnsaved: Bool {
        let savedMailbox = model.settings.config.map { config in
            if case .mailbox = config.resolvedSource() { true } else { false }
        } ?? false
        return model.draft.isDirty(against: model.settings.config, home: home) || !savedMailbox
    }

    public var body: some View {
        Form {
            Section("Source") {
                SettingsRow("Asks come from", help: QueueHelp.source) {
                    Picker("Asks come from", selection: $choice) {
                        Text("This Mac only").tag(SourceKind.local)
                        Text("Mailbox").tag(SourceKind.mailbox)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
            }
            .environment(\.settingsSection, "Source")
            if choice == .local {
                localSection
            }
            if choice == .mailbox {
                mailboxSection
            }
            connectionSection
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
        .onAppear {
            let saved = QueueSourceRadio.saved(model.settings.config)
            if choice != saved { choice = saved }
            syncDraft()
            updateCommand = model.settings.config?.mailboxUpdateCommand ?? ""
        }
        .onChange(of: model.settings.config) { old, new in
            if !updateCommandFocused { updateCommand = new?.mailboxUpdateCommand ?? "" }
            guard !connecting else { return }
            let next = QueueSourceRadio.afterConfigChange(current: choice, old: old, new: new)
            if next != choice { choice = next }
            syncDraft()
        }
        .onChange(of: choice) { _, new in
            if new == .local, model.settings.config?.resolvedSource() != .local {
                model.save(set: ["source": SourceKind.local.rawValue], remove: [])
            }
        }
    }

    // MARK: Sections

    private var localSection: some View {
        Section("This Mac") {
            SettingsRow("Stored in") {
                HStack(spacing: DS.Space.inline) {
                    Text(model.settings.localQueuePath ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Show in Finder") { model.perform(.showQueueInFinder) }
                }
            }
            SettingsRow("Keep closed asks for", help: QueueHelp.keep) {
                Picker("Keep closed asks for", selection: model.configBinding(
                    "keepDays", \.keepDays, fallback: RelayConfig.defaultKeepDays, encode: { $0 })) {
                    ForEach(ChoiceLabel.keepChoices, id: \.self) { Text(ChoiceLabel.keepDays($0)).tag($0) }
                    if let days = model.settings.config?.keepDays, !ChoiceLabel.keepChoices.contains(days) {
                        Divider()
                        Text(ChoiceLabel.keepDays(days)).tag(days)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
        .environment(\.settingsSection, "This Mac")
    }

    private var mailboxSection: some View {
        let errors = attempted ? model.draft.errors() : (address: nil, tokenFile: nil)
        return Section("Mailbox") {
            MailboxFields(
                address: $model.draft.address, tokenFile: $model.draft.tokenFile, context: $model.draft.context,
                addressError: errors.address, tokenFileError: errors.tokenFile,
                onChooseTokenFile: { model.perform(.chooseTokenFile) })
            SettingsRow("Check every") {
                Picker("Check every", selection: model.configBinding(
                    "pollSeconds", \.pollSeconds, fallback: RelayConfig.defaultPollSeconds, encode: { $0 })) {
                    ForEach(ChoiceLabel.pollChoices, id: \.self) { Text(ChoiceLabel.poll($0)).tag($0) }
                    if let seconds = model.settings.config?.pollSeconds, !ChoiceLabel.pollChoices.contains(seconds) {
                        Divider()
                        Text(ChoiceLabel.poll(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            SettingsRow("Update command", help: QueueHelp.updateCommand) {
                TextField("Update command", text: $updateCommand, prompt: Text("Opens the update guide"))
                    .settingsField(width: DS.Metric.fieldWide)
                    .focused($updateCommandFocused)
                    .onSubmit(saveUpdateCommand)
                    .onChange(of: updateCommandFocused) { _, focused in if !focused { saveUpdateCommand() } }
            }
            if isUnsaved {
                SettingsRow("") {
                    HStack(spacing: DS.Space.inline) {
                        Text("Not saved yet").foregroundStyle(DS.Color.warn)
                        Spacer(minLength: DS.Space.inline)
                        if connecting {
                            ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Connecting")
                        }
                        Button("Revert") {
                            model.draft = MailboxDraft(config: model.settings.config, home: home)
                            attempted = false
                        }
                        .disabled(connecting)
                        Button("Connect", action: connect)
                            .keyboardShortcut(.defaultAction)
                            .disabled(connecting)
                    }
                }
            }
        }
        .environment(\.settingsSection, "Mailbox")
    }

    private var connectionSection: some View {
        let connection = model.settings.connection
        let problems = model.settings.connectionProblems
        return Section("Connection") {
            SettingsRow("Status", error: problems.isEmpty ? nil : problems.joined(separator: "\n")) {
                Label {
                    Text(connection.text).textSelection(.enabled).lineLimit(2)
                } icon: {
                    Image(systemName: connection.ok ? DS.Symbol.statusOK : DS.Symbol.statusDown)
                        .imageScale(.small)
                        .foregroundStyle(connection.ok ? DS.Color.done : DS.Color.warn)
                }
            }
            if let line = model.settings.mailbox {
                mailboxRow(line)
            }
            SettingsRow("Test", help: QueueHelp.test) {
                Button("Send a Test Ask", action: sendTest)
                    .disabled(sending || model.settings.sourceKey == SourceKey.none)
            }
            if let testResult {
                SettingsRow("", error: { if case .failed(let reason) = testResult { reason } else { nil } }()) {
                    switch testResult {
                    case .sent(let id):
                        HStack(spacing: DS.Space.inline) {
                            Text("Test ask sent.")
                            Button("Show") { model.perform(.showAsk(id)) }
                        }
                    case .alreadyWaiting(let id):
                        HStack(spacing: DS.Space.inline) {
                            Text("A test ask is already waiting.")
                            Button("Show") { model.perform(.showAsk(id)) }
                        }
                    case .failed:
                        EmptyView()
                    }
                }
            }
        }
        .environment(\.settingsSection, "Connection")
    }

    /// The mailbox's version and level, ✓ or "Needs an update", and Check.
    private func mailboxRow(_ line: MailboxVersionLine) -> some View {
        SettingsRow("Mailbox", help: QueueHelp.mailboxVersion) {
            HStack(spacing: DS.Space.inline) {
                Text(line.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                switch line.state {
                case .ok:
                    Image(systemName: DS.Symbol.mailboxOK)
                        .imageScale(.small)
                        .foregroundStyle(DS.Color.done)
                        .accessibilityLabel("Up to date")
                case .needsUpdate, .hookOlder:
                    Label(line.badge ?? "", systemImage: DS.Symbol.mailboxBehind)
                        .foregroundStyle(DS.Color.warn)
                case .checking:
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Checking")
                case .failed:
                    EmptyView()
                }
                if line.state == .needsUpdate {
                    Button("Update Mailbox…") { model.perform(.updateMailbox) }
                }
                Button("Check") { model.perform(.checkMailbox) }
                    .disabled(line.state == .checking)
            }
        }
    }

    // MARK: Actions

    /// Saves the update command; an empty field removes the key.
    private func saveUpdateCommand() {
        let text = updateCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (model.settings.config?.mailboxUpdateCommand ?? "") else { return }
        if text.isEmpty {
            model.save(set: [:], remove: ["mailboxUpdateCommand"])
        } else {
            model.save(set: ["mailboxUpdateCommand": text], remove: [])
        }
    }

    private func connect() {
        attempted = true
        let errors = model.draft.errors()
        guard errors.address == nil, errors.tokenFile == nil else { return }
        connecting = true
        Task { @MainActor in
            _ = await model.connect()     // a failure shows in Connection → Status, once
            connecting = false
        }
    }

    private func sendTest() {
        sending = true
        testResult = nil
        Task { @MainActor in
            let result = await model.sendTestAsk()
            testResult = result
            sending = false
            try? await Task.sleep(for: .seconds(TestAskResult.hold))
            if testResult == result { testResult = nil }
        }
    }

    /// The draft follows the config while it is clean.
    private func syncDraft() {
        let config = model.settings.config
        let fields = MailboxDraft(config: config, home: home)
        // Assigning an equal draft would still publish a change and re-render the tab.
        if model.draft != fields, !model.draft.isDirty(against: config, home: home) || model.draft == MailboxDraft() {
            model.draft = fields
        }
    }

}

/// Where the Source radio points.
enum QueueSourceRadio {
    /// The source the config has saved.
    static func saved(_ config: RelayConfig?) -> SourceKind {
        config?.source ?? (config?.mailboxURL != nil ? .mailbox : .local)
    }

    /// Only a change of the saved source moves the radio, so a Check every save or a
    /// config reload keeps a picked but not yet connected Mailbox on screen.
    static func afterConfigChange(current: SourceKind, old: RelayConfig?, new: RelayConfig?) -> SourceKind {
        saved(old) == saved(new) ? current : saved(new)
    }
}

/// The Queue tab's "?" texts; Welcome uses the same ones.
public enum QueueHelp {
    public static let local = "Asks are stored in a file on this Mac and never leave it. Claude Code sessions on this Mac send them to Hook with the relay command or the MCP server."
    public static let mailbox = "Asks come from a mailbox server you run. Hook checks it on a timer and sends your answers back to it. The token file holds the mailbox's access token; Hook reads it only to talk to the mailbox and never shows it."
    public static let source = local + "\n\n" + mailbox
    public static let keep = "Closed asks older than this are deleted from this Mac."
    public static let updateCommand = "A shell command that updates your mailbox server, for example a script that pulls the new version and restarts it. Update Mailbox… runs it in your terminal through your login shell, so you see its output and any password prompt. Leave it empty to open the update guide instead."
    public static let mailboxVersion = "Hook reads the mailbox's protocol level when it connects and every 30 minutes. A mailbox below Hook's level can't take every step Hook shows: update it with Update Mailbox…."
    public static let test = "Posts a sample ask through the current source: project Hook, one step that runs echo relay-ok, and a verify step."
}
