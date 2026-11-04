import AppKit
import RelayCore
import SwiftUI

/// The setup window: seven pages (WelcomeFlow) at 480 × 500 pt. A page pushes in from the
/// trailing edge (from the leading edge on Back); the footer, with the dots and a
/// full-width Continue, stays put. Under Reduce Motion pages switch in place.
public struct WelcomeView<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @State private var flow: WelcomeFlow
    @State private var choice: SourceKind = .local
    @State private var attempted = false
    @State private var testResult: TestAskResult?
    @State private var sendingTest = false
    @State private var copied: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onDone: () -> Void

    public init(model: Model, onDone: @escaping () -> Void) {
        self.init(model: model, initialFlow: WelcomeFlow(), onDone: onDone)
    }

    /// The gallery opens any page, or the error state, directly.
    public init(model: Model, initialFlow: WelcomeFlow, testResult: TestAskResult? = nil,
                onDone: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _flow = State(initialValue: initialFlow)
        _testResult = State(initialValue: testResult)
        // The first frame already shows the saved source's fields.
        _choice = State(initialValue: QueueSourceRadio.saved(model.settings.config))
        self.onDone = onDone
    }

    private var home: String { NSHomeDirectory() }
    private var agents: AgentsState { model.settings.agents }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(flow.page)
                    .id(flow.page)
                    .transition(transition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            SetupFooter(page: flow.page.number, count: WelcomeFlow.pageCount,
                        title: flow.page == .done ? "Open Hook" : "Continue",
                        showsBack: flow.canGoBack, busy: flow.starting,
                        onBack: { move { flow.back() } }, onContinue: continueTapped)
        }
        .frame(width: DS.Metric.welcomeWidth, height: DS.Metric.welcomeHeight)
        .onAppear(perform: prefill)
        .onChange(of: model.settings.config) { _, config in
            switch config?.resolvedSource() {
            case .local?, .mailbox?: move { flow.configResolved() }
            default: break
            }
        }
        .onChange(of: flow.page) { _, page in
            if page == .agents { model.perform(.refreshAgents) }
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .identity }
        return .push(from: flow.forward ? .trailing : .leading)
    }

    /// Applies a flow change, animated unless Reduce Motion is on.
    private func move(_ change: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, change)
        } else {
            withAnimation(DS.Motion.page, change)
        }
    }

    @ViewBuilder private func page(_ page: WelcomeFlow.Page) -> some View {
        switch page {
        case .welcome:
            SetupHero(title: "Welcome to Hook", line: WelcomeCopy.welcome) { SetupAppIcon() } extra: { EmptyView() }
        case .source: formPage { sourcePage }
        case .agents: formPage { agentsPage }
        case .notifications: formPage { notificationsPage }
        case .shortcut: formPage { shortcutPage }
        case .testAsk: formPage { testAskPage }
        case .done:
            SetupHero(title: "Hook is ready", line: doneLine) { SetupDoneSymbol() } extra: {
                if Self.showsSupport() {
                    Button {
                        model.perform(.openDonation)
                    } label: {
                        Label("Support Hook", systemImage: DS.Symbol.setupSupport)
                    }
                    .controlSize(DS.Control.form)
                }
            }
        }
    }

    /// The last page's Support Hook button shows only for a valid https donation link.
    static func showsSupport(_ raw: String = ConnectInfo.donationURL) -> Bool {
        ConnectInfo.donationLink(raw) != nil
    }

    /// A grouped Form on the window background, one surface with the footer.
    private func formPage(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .controlSize(DS.Control.form)
    }

    // MARK: Pages

    @ViewBuilder private var sourcePage: some View {
        Section {
            SetupRow("Asks come from", symbol: DS.Symbol.setupSource, help: QueueHelp.source) {
                Picker("Asks come from", selection: $choice) {
                    Text("This Mac").tag(SourceKind.local)
                    Text("Pond").tag(SourceKind.mailbox)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
            }
        } header: {
            SetupHeading("Where asks come from", line: WelcomeCopy.source)
        }
        if choice == .mailbox {
            Section {
                let errors = attempted ? model.draft.errors() : (address: nil, tokenFile: nil)
                MailboxFields(address: $model.draft.address, tokenFile: $model.draft.tokenFile,
                              context: $model.draft.context, addressError: errors.address,
                              tokenFileError: errors.tokenFile, width: DS.Metric.fieldSetup,
                              onChooseTokenFile: { model.perform(.chooseTokenFile) })
                SettingsRow("Connection", error: flow.error) {
                    Text(flow.starting ? "Testing…" : "Tested when you press Continue")
                        .foregroundStyle(DS.Color.secondary)
                }
            }
        } else if let error = flow.error {
            Section { SettingsRow("", error: error) { EmptyView() } }
        }
    }

    /// Set Up All and the automatic setup checkbox, then the agents on this Mac, read only.
    @ViewBuilder private var agentsPage: some View {
        Section {
            if agents.repoPath == nil {
                SetupRow("Hook repo", symbol: DS.Symbol.setupRepo, help: AgentsHelp.repo) {
                    Button("Choose…") { model.perform(.chooseRepoFolder) }
                }
            }
            SetupRow("Agents", symbol: DS.Symbol.setupMCP, help: WelcomeCopy.agentsHelp(agents),
                     error: agents.error) { agentsControl }
            SetupRow("New agents", symbol: DS.Symbol.setupSkill, help: AgentsHelp.autoSetup) {
                Toggle("Set up automatically", isOn: Binding(
                    get: { agents.status?.autoSetup ?? true },
                    set: { model.perform(.integration(.setAutoSetup($0))) }))
                    .toggleStyle(.checkbox)
                    .disabled(agents.status == nil || agents.busy)
            }
        } header: {
            SetupHeading("Connect your agents", line: WelcomeCopy.agents)
        }
        if !agents.onThisMac.isEmpty {
            Section("On this Mac") {
                ForEach(agents.onThisMac) { harness in
                    HStack(spacing: DS.Space.inline) {
                        HarnessMark(id: harness.id, name: harness.name)
                        Text(harness.name)
                        Spacer(minLength: DS.Space.inline)
                        Text(AgentsPane.caption(harness)).foregroundStyle(DS.Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private var notificationsPage: some View {
        Section {
            SetupRow("Notifications", symbol: DS.Symbol.setupNotifications) { PermissionControl(model: model) }
            SetupRow("Sound", symbol: DS.Symbol.setupSound) {
                Toggle("Play a sound", isOn: Binding(
                    get: { model.settings.config?.notify.sound ?? NotifySettings().sound },
                    set: { on in
                        var next = model.settings.config?.notify ?? NotifySettings()
                        next.sound = on
                        model.save(set: ["notify": next.configObject], remove: [])
                    }))
                    .toggleStyle(.checkbox)
            }
        } header: {
            SetupHeading("Notifications", line: WelcomeCopy.notifications)
        }
    }

    @ViewBuilder private var shortcutPage: some View {
        Section {
            SetupRow("Shortcut", symbol: DS.Symbol.setupShortcut, error: model.settings.shortcutProblem?.text) {
                ShortcutField(label: model.settings.shortcutLabel ?? "Not set",
                              onBegin: { model.perform(.beginShortcut) },
                              onRecord: { model.perform(.recordShortcut($0)) },
                              onCancel: { model.perform(.cancelShortcut) },
                              onClear: { model.perform(.clearShortcut) })
            }
            SetupRow("Login", symbol: DS.Symbol.setupLogin, error: model.settings.login.error) {
                Toggle("Start Hook when I log in", isOn: Binding(
                    get: { model.settings.login.on }, set: { model.perform(.setLogin($0)) }))
                    .toggleStyle(.checkbox)
            }
        } header: {
            SetupHeading("Shortcut and login", line: WelcomeCopy.shortcut)
        }
    }

    @ViewBuilder private var testAskPage: some View {
        Section {
            SetupRow("Test ask", symbol: DS.Symbol.setupTestAsk, help: QueueHelp.test, error: testFailure) {
                testControl
            }
        } header: {
            SetupHeading("Send a test ask", line: WelcomeCopy.testAsk)
        }
    }

    // MARK: Agent controls

    @ViewBuilder private var agentsControl: some View {
        if agents.busy {
            ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Setting up")
        } else if agents.allSetUp {
            SetupDone(agents.onThisMac.count == 1 ? "1 set up" : "\(agents.onThisMac.count) set up")
        } else {
            Button("Set Up All") {
                model.perform(.integration(.sync(ifChanged: false, includeNew: true, harness: nil)))
            }
            .disabled(agents.repoPath == nil)
        }
    }

    @ViewBuilder private func copyButton(_ text: String?, label: String) -> some View {
        IconButton(copied == label ? DS.Symbol.sent : DS.Symbol.copy, label: label) {
            if let text { copy(text, tag: label) }
        }
        .disabled(text == nil)
    }

    private func copy(_ text: String, tag: String) {
        model.perform(.copyText(text))
        copied = tag
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.copiedFor))
            if copied == tag { copied = nil }
        }
    }

    // MARK: Test ask

    @ViewBuilder private var testControl: some View {
        if sendingTest {
            ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
        } else {
            switch testResult {
            case .sent(let id)?, .alreadyWaiting(let id)?:
                HStack(spacing: DS.Space.inline) {
                    SetupDone(testResult == .sent(id: id) ? "Arrived" : "Already waiting")
                    Button("Show") { model.perform(.showAsk(id)) }
                }
            case .failed?, nil:
                Button("Send a Test Ask", action: sendTest)
                    .disabled(model.settings.sourceKey == SourceKey.none)
            }
        }
    }

    private var testFailure: String? {
        if case .failed(let reason)? = testResult { reason } else { nil }
    }

    private func sendTest() {
        sendingTest = true
        testResult = nil
        Task { @MainActor in
            let result = await model.sendTestAsk()
            testResult = result
            sendingTest = false
            // Watch it arrive: the panel slides in with the new card.
            if case .sent = result { model.perform(.showPanel) }
        }
    }

    // MARK: Continue

    private var doneLine: String {
        if let label = model.settings.shortcutLabel {
            return "Press \(label) or click the menu-bar icon to open Hook. Settings has everything you skipped."
        }
        return "Click the menu-bar icon to open Hook. Settings has everything you skipped."
    }

    /// Whether the page's own action is done, so Continue counts it done, not skipped.
    private var pageComplete: Bool {
        switch flow.page {
        case .agents:
            agents.allSetUp
        case .notifications: model.settings.permission == .authorized
        case .shortcut: model.settings.shortcutLabel != nil
        case .testAsk:
            if case .sent? = testResult { true } else if case .alreadyWaiting? = testResult { true } else { false }
        case .welcome, .source, .done: true
        }
    }

    private func continueTapped() {
        switch flow.page {
        case .source:
            start()
        case .done:
            flow.continueTapped()
            onDone()
        default:
            let complete = pageComplete
            move { flow.continueTapped(complete: complete) }
        }
    }

    /// The source page is prefilled from the current config (`source`, `mailboxURL`, `tokenFile`, `context`).
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
                move { flow.startTapped(isMailbox: false) }
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
                move { flow.firstList(ok: reason == nil, reason: reason) }
            }
        }
    }
}

/// The setup window's lines and "?" texts.
public enum WelcomeCopy {
    public static let welcome = "Your agents ask, Hook collects it: one card for each thing that needs you."
    public static let source = "Keep asks on this Mac, or use a Pond you run."
    public static let agents = "Tell your agents Hook is there. Skip any you don't need."
    public static let notifications = "Hook tells you when an ask needs you now."
    public static let shortcut = "Show or hide Hook from anywhere."
    public static let testAsk = "Send one, and watch it arrive in the panel."

    /// The agents row's "?": what Set Up All does, then each agent on this Mac and its state.
    public static func agentsHelp(_ agents: AgentsState) -> String {
        "Set Up All gives every agent on this Mac Hook's MCP server, the instructables skill, "
            + "Hook's instructions and, where the agent has one, the replies hook. A file you edited is left as it is. "
            + "Settings › Agents shows what Hook set up in each."
    }
}
