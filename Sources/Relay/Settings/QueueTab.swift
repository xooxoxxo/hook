import AppKit
import RelayCore
import SwiftUI

/// Settings → Queue: where asks come from, and that source's settings.
/// Every write goes through AppModel.save (merge, unknown keys kept); AppDelegate
/// swaps the source when the saved config resolves to a different one.
struct QueueTab: View {
    static let localHelp = "Asks are stored in a file on this Mac and never leave it. Claude Code sessions on this Mac send them to Relay with the relay command or the MCP server."
    static let mailboxHelp = "Asks come from a mailbox server you run. Relay checks it on a timer and sends your answers back to it. The token file holds the mailbox's access token; Relay reads it only to talk to the mailbox and never shows it."
    static let fillInNote = "Enter the mailbox address and the token file."
    static let schemeNote = "The address must start with http:// or https://."
    static let keepChoices = [3, 7, 14, 30, 90]
    static let pollChoices = [5, 15, 30, 60, 300]

    @ObservedObject private var model: AppModel
    @ObservedObject private var store: Store
    @State private var choice: SourceKind = .local
    /// Mailbox was picked but its fields aren't complete, so nothing was written yet.
    @State private var pendingMailbox = false
    @State private var address = ""
    @State private var tokenFile = ""
    @State private var context = ""
    @State private var fieldsNote: String?
    @State private var testResult: String?
    @State private var sending = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address, tokenFile, context
    }

    /// What the fields show: from the last good config, or from the raw file.
    private struct Fields {
        var kind: SourceKind
        var address: String
        var tokenFile: String
        var context: String
    }

    init(model: AppModel, store: Store) {
        _model = ObservedObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        SettingsForm {
            SettingsRow("Asks come from:") {
                VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                    HStack(spacing: 6) {
                        RadioButton(title: "This Mac only", isOn: choice == .local) { select(.local) }
                            .fixedSize()
                        HelpButton(Self.localHelp)
                    }
                    HStack(spacing: 6) {
                        RadioButton(title: "Mailbox", isOn: choice == .mailbox) { select(.mailbox) }
                            .fixedSize()
                        HelpButton(Self.mailboxHelp)
                    }
                }
            }

            if choice == .local {
                localRows
            } else {
                mailboxRows
            }

            SettingsRow("Status:", newGroup: true) {
                statusRows
            }

            SettingsRow("") {
                testRow
            }
        }
        .settingsPage()
        .onAppear(perform: syncFromConfig)
        // A half-filled Mailbox choice isn't kept across a tab switch or a close and
        // reopen. onDisappear doesn't run when the window closes, so watch for that too.
        .onDisappear(perform: dropPendingMailbox)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.identifier == SettingsWindowController.windowID {
                dropPendingMailbox()
            }
        }
        .onChange(of: model.config) { _, _ in
            syncFromConfig()
        }
        .onChange(of: focus) { old, _ in
            if old != nil { applyMailbox(explicit: false) }
        }
    }

    private func dropPendingMailbox() {
        pendingMailbox = false
        fieldsNote = nil
        syncFromConfig()
    }

    // MARK: Rows

    @ViewBuilder private var localRows: some View {
        SettingsRow("Stored in:", newGroup: true) {
            HStack(spacing: 8) {
                Text(verbatim: (model.dataDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder", action: showInFinder)
            }
        }
        SettingsRow("Keep finished:") {
            Picker("Keep finished:", selection: Binding(
                get: { model.config?.keepDays ?? RelayConfig.defaultKeepDays },
                set: { model.save(set: ["keepDays": $0]) })) {
                ForEach(Self.options(Self.keepChoices, current: model.config?.keepDays), id: \.self) { days in
                    Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(model.config == nil)
        }
    }

    @ViewBuilder private var mailboxRows: some View {
        SettingsRow("Address:", newGroup: true) {
            TextField("Address:", text: $address, prompt: Text(verbatim: "https://mailbox.example:8790"))
                .labelsHidden()
                .settingsField()
                .focused($focus, equals: .address)
                .onSubmit { applyMailbox(explicit: true) }
                .frame(maxWidth: 360)
        }
        SettingsRow("Token file:") {
            HStack(spacing: 8) {
                TextField("Token file:", text: $tokenFile, prompt: Text("Path to the file that holds the token"))
                    .labelsHidden()
                    .settingsField()
                    .focused($focus, equals: .tokenFile)
                    .onSubmit { applyMailbox(explicit: true) }
                    .frame(maxWidth: 300)
                Button("Choose…") {
                    if let path = Self.chooseTokenFile() {
                        tokenFile = Self.abbreviated(path)
                        applyMailbox(explicit: true, chosenTokenFile: path)
                    }
                }
            }
        }
        SettingsRow("Context:") {
            TextField("Context:", text: $context, prompt: Text(verbatim: RelayConfig.defaultContext))
                .labelsHidden()
                .settingsField()
                .focused($focus, equals: .context)
                .onSubmit { applyMailbox(explicit: true) }
                .frame(width: 200)
        }
        SettingsRow("Check every:") {
            Picker("Check every:", selection: Binding(
                get: { model.config?.pollSeconds ?? RelayConfig.defaultPollSeconds },
                set: { model.save(set: ["pollSeconds": $0]) })) {
                ForEach(Self.options(Self.pollChoices, current: model.config?.pollSeconds), id: \.self) { seconds in
                    Text(Self.pollLabel(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(model.config == nil)
        }
        if let fieldsNote {
            SettingsRow("") {
                Text(fieldsNote)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
            let line = Self.statusLine(
                sourceKey: store.sourceKey, reachable: store.reachable,
                problem: store.problem, waiting: store.items.count)
            HStack(spacing: 6) {
                Circle()
                    .fill(line.ok ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(verbatim: line.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let note = model.configNote {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let note = model.listenerNote {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
            HStack(spacing: 6) {
                Button("Send a test ask", action: sendTest)
                    .disabled(sending || store.sourceKey == "none")
                HelpButton("Posts a sample ask (project Relay, one step that runs echo relay-ok, and a verify step) through the current source. A mailbox delivers it like any other ask.")
            }
            if let testResult {
                Text(verbatim: testResult)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Actions

    private func select(_ kind: SourceKind) {
        choice = kind
        fieldsNote = nil
        switch kind {
        case .local:
            pendingMailbox = false
            if model.config?.resolvedSource() != .local {
                model.save(set: ["source": SourceKind.local.rawValue])
            }
        case .mailbox:
            if Self.mailboxProblem(address: address, tokenFile: tokenFile) == nil {
                pendingMailbox = false
                applyMailbox(explicit: true)
            } else {
                pendingMailbox = true
                fieldsNote = Self.fillInNote
            }
        }
    }

    /// Writes the mailbox fields (and `source: "mailbox"`) once they resolve to a
    /// mailbox. `explicit` is Return, Choose… or the radio; a plain blur stays quiet
    /// about missing fields. The field shows the token file with `~`; a spelling
    /// that expands to the saved path keeps the saved spelling, and Choose… passes
    /// the absolute path it picked.
    private func applyMailbox(explicit: Bool, chosenTokenFile: String? = nil) {
        guard choice == .mailbox else { return }
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var file = chosenTokenFile ?? tokenFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.mailboxProblem(address: url, tokenFile: file) {
            if explicit { fieldsNote = problem }
            return
        }
        fieldsNote = nil
        pendingMailbox = false
        if chosenTokenFile == nil, let saved = model.config?.tokenFile, Self.samePath(saved, file) {
            file = saved
        }
        if let config = model.config, case .mailbox = config.resolvedSource(),
           config.mailboxURL == url, config.tokenFile == file,
           config.context == (ctx.isEmpty ? RelayConfig.defaultContext : ctx) {
            return
        }
        var set: [String: Any] = ["source": SourceKind.mailbox.rawValue, "mailboxURL": url, "tokenFile": file]
        var remove: [String] = []
        if ctx.isEmpty {
            remove.append("context")
        } else {
            set["context"] = ctx
        }
        model.save(set: set, remove: remove)
    }

    private func sendTest() {
        sending = true
        testResult = nil
        Task { @MainActor in
            let result = await model.sendTestAsk()
            testResult = result
            sending = false
        }
    }

    private func showInFinder() {
        let queue = model.dataDirectory.appending(path: "queue.json")
        if FileManager.default.fileExists(atPath: queue.path) {
            NSWorkspace.shared.activateFileViewerSelecting([queue])
        } else {
            NSWorkspace.shared.open(model.dataDirectory)
        }
    }

    /// A live reload (or another tab's save) refreshes the fields, except while the
    /// owner is typing or has a half-filled mailbox.
    private func syncFromConfig() {
        guard focus == nil, !pendingMailbox else { return }
        let fields = Self.fields(model.config, configURL: model.configURL)
        choice = fields.kind
        address = fields.address
        tokenFile = fields.tokenFile
        context = fields.context
    }

    // MARK: Helpers

    private static func fields(_ config: RelayConfig?, configURL: URL) -> Fields {
        if let config {
            return Fields(
                kind: config.source ?? (config.mailboxURL != nil ? .mailbox : .local),
                address: config.mailboxURL ?? "",
                tokenFile: abbreviated(config.tokenFile ?? ""),
                context: config.context)
        }
        let raw = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let kind = (raw["source"] as? String).flatMap(SourceKind.init(rawValue:))
            ?? (raw["mailboxURL"] is String ? .mailbox : .local)
        return Fields(
            kind: kind,
            address: raw["mailboxURL"] as? String ?? "",
            tokenFile: abbreviated(raw["tokenFile"] as? String ?? ""),
            context: raw["context"] as? String ?? RelayConfig.defaultContext)
    }

    /// A path as the Token file field shows it: the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        path.isEmpty ? path : (path as NSString).abbreviatingWithTildeInPath
    }

    /// Two spellings of one path, e.g. `~/x` and the absolute form.
    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).expandingTildeInPath == (b as NSString).expandingTildeInPath
    }

    /// nil when the two fields make a usable mailbox source.
    static func mailboxProblem(address: String, tokenFile: String) -> String? {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = tokenFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !file.isEmpty else { return fillInNote }
        guard case .mailbox = RelayConfig(source: .mailbox, mailboxURL: url, tokenFile: file).resolvedSource() else {
            return schemeNote
        }
        return nil
    }

    /// The token file's path. The panel never reads the file.
    @MainActor static func chooseTokenFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the token file"
        panel.message = "Relay reads this file only to talk to the mailbox and never shows what it holds."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    static func statusLine(sourceKey: String, reachable: Bool, problem: String?, waiting: Int) -> (text: String, ok: Bool) {
        if reachable { return ("Ready · \(waiting) waiting", true) }
        guard let problem else { return ("Connecting…", false) }
        guard sourceKey.hasPrefix("mailbox:"), problem != QueueError.unauthorized.localizedDescription else {
            return (problem, false)
        }
        return ("Can't reach the mailbox: \(problem)", false)
    }

    /// The pop-up's choices, plus a hand-edited value that isn't one of them.
    static func options(_ choices: [Int], current: Int?) -> [Int] {
        guard let current, !choices.contains(current) else { return choices }
        return (choices + [current]).sorted()
    }

    /// 5 s, 15 s, 30 s, 1 min, 5 min.
    static func pollLabel(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
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
