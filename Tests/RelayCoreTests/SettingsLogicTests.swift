import CryptoKit
import Foundation
import Testing
@testable import RelayCore

/// A throwaway defaults domain; the caller removes it.
private func scratchDefaults() -> (UserDefaults, String) {
    let name = "relay-settings-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private let legacyKey = "relay.settings.tab"
private let home = "/home/tester"

private func screen(_ id: String, primary: Bool) -> DockScreen {
    DockScreen(id: id, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
               visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), isPrimary: primary)
}

@Suite struct SettingsLogicTests {
    @Test func theSavedTabIDWins() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("panel", forKey: SettingsTabID.defaultsKey)
        defaults.set(3, forKey: legacyKey)
        #expect(SettingsTabID.restore(defaults) == .panel)
        #expect(defaults.object(forKey: legacyKey) == nil)
    }

    @Test func aLegacyIndexMapsToTheOldFourTabs() {
        let expected: [(Int, SettingsTabID)] = [(0, .general), (1, .queue), (2, .notifications), (3, .agents)]
        for (index, tab) in expected {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(index, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults) == tab)
            #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == tab.rawValue)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test func aLegacyStringIsItsRawValue() {
        for raw in ["queue", "notifications", "general"] {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(raw, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults).rawValue == raw)
            #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == raw)
        }
    }

    /// Connect became Agents in 0.13: a saved "connect", new or legacy, opens Agents and is saved as it.
    @Test func aSavedConnectTabOpensAgents() {
        for key in [SettingsTabID.defaultsKey, legacyKey] {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set("connect", forKey: key)
            #expect(SettingsTabID.restore(defaults) == .agents)
            #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == "agents")
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test func anUnknownLegacyValueFallsBackToGeneralAndIsDeleted() {
        for value: Any in [7, -1, "bogus", "2"] {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(value, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults) == .general)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test func nothingSavedIsGeneralAndWritesNothing() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsTabID.restore(defaults) == .general)
        #expect(defaults.object(forKey: SettingsTabID.defaultsKey) == nil)
    }

    @Test func savingWritesTheID() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsTabID.queue.save(defaults)
        #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == "queue")
        #expect(SettingsTabID.restore(defaults) == .queue)
    }

    /// Documents and Privacy follow the older tabs, so ⌘1–⌘5 keep the tabs they had.
    @Test func commandDigitsPickTheSevenTabsInOrder() {
        #expect((1...7).compactMap(SettingsTabID.init(shortcutDigit:))
            == [.general, .panel, .queue, .notifications, .agents, .documents, .privacy])
        #expect(SettingsTabID(shortcutDigit: 0) == nil)
        #expect(SettingsTabID(shortcutDigit: 8) == nil)
    }

    @Test func titlesAndSymbols() {
        #expect(SettingsTabID.allCases.map(\.title) == ["General", "Panel", "Queue", "Notifications", "Agents",
                                                           "Documents", "Privacy"])
        #expect(SettingsTabID.allCases.map(\.symbol) == ["gearshape", "sidebar.right", "tray", "bell", "terminal",
                                                            "doc.text", "hand.raised"])
    }

    @Test func anEmptyDraftAndSnapshotStartBlank() {
        #expect(MailboxDraft() == MailboxDraft(address: "", tokenFile: "", context: ""))
        let snapshot = SettingsSnapshot()
        #expect(snapshot.config == nil && snapshot.sourceKey == SourceKey.none && snapshot.displays.isEmpty)
    }

    @Test func anErrorChangesTheAgentsState() {
        #expect(AgentsState().error == nil && !AgentsState().busy)
        let failed = AgentsState(repoPath: "~/src/relay", error: "another run holds the lock")
        #expect(failed != AgentsState(repoPath: "~/src/relay"))
        #expect(AgentsState(running: .status).busy)
    }

    @Test func aPieceCommandNamesItsRow() {
        #expect(AgentsState.key(for: .accept(harness: "zed", piece: "mcp")) == "zed/mcp")
        #expect(AgentsState.key(for: .diff(harness: "zed", piece: "skill")) == "zed/skill")
        #expect(AgentsState.key(for: .reinstall(harness: "zed", piece: "replies", force: true)) == "zed/replies")
        #expect(AgentsState.key(for: .reinstall(harness: "zed", piece: nil, force: true)) == nil)
        #expect(AgentsState.key(for: .reinstall(harness: nil, piece: nil, force: false)) == nil)
        #expect(AgentsState.key(for: .accept(harness: "zed", piece: nil)) == nil)
        #expect(AgentsState.key(for: .sync(ifChanged: false, includeNew: false, harness: "zed")) == nil)
        #expect(AgentsState.key(for: .status) == nil)
    }

    @Test func onThisMacPutsClaudeCodeFirstThenByName() {
        func entry(_ id: String, _ name: String, detected: Bool, managed: Bool) -> IntegrationStatus.Harness {
            IntegrationStatus.Harness(id: id, name: name, detected: detected, managed: managed, state: .installed,
                                      verified: "pending", pieces: [], ownerSteps: [], changes: [])
        }
        let status = IntegrationStatus(harnesses: [
            entry("zed", "Zed", detected: true, managed: true),
            entry("amp", "Amp", detected: false, managed: false),
            entry("pi", "pi", detected: false, managed: true),
            entry("claude-code", "Claude Code", detected: true, managed: true),
            entry("codex", "Codex", detected: true, managed: false),
        ])
        #expect(AgentsState(status: status).onThisMac.map(\.id) == ["claude-code", "codex", "pi", "zed"])
        #expect(AgentsState().onThisMac.isEmpty)
    }

    @Test func theAgentsPageIsDoneWhenNoDetectedHarnessIsNotSetUp() {
        func entry(_ id: String, detected: Bool, _ state: HarnessState) -> IntegrationStatus.Harness {
            IntegrationStatus.Harness(id: id, name: id, detected: detected, managed: state != .notSetUp, state: state,
                                      verified: "pending", pieces: [], ownerSteps: [], changes: [])
        }
        #expect(!AgentsState().allSetUp)                                    // not read yet
        #expect(AgentsState(status: IntegrationStatus()).allSetUp)          // nothing found
        let done = IntegrationStatus(harnesses: [entry("a", detected: true, .installed),
                                                 entry("b", detected: true, .needsOwner),
                                                 entry("c", detected: false, .notSetUp)])
        #expect(AgentsState(status: done).allSetUp)
        var open = done
        open.harnesses.append(entry("d", detected: true, .notSetUp))
        #expect(!AgentsState(status: open).allSetUp)
        // One the owner removed Hook from stays removed: it doesn't keep the page open.
        var removed = done
        var gone = entry("e", detected: true, .notSetUp)
        gone.removed = true
        removed.harnesses.append(gone)
        #expect(AgentsState(status: removed).allSetUp)
    }

    @Test func shortcutProblemsHaveTheSpecTexts() {
        #expect(ShortcutProblem.unsupportedKey.text == "That key can't be used. Pick a letter, a digit, Space, ` or F1–F12.")
        #expect(ShortcutProblem.refused.text == "macOS refused this shortcut. Another app may be using it.")
        #expect(ShortcutProblem.resumeFailed.text == "The shortcut was turned off because macOS refused it again. Record it again.")
    }

    @Test func aRecordingMapsToAProblem() {
        let spec = HotkeySpec.parse("ctrl+opt+cmd+r")
        #expect(ShortcutProblem.forRecording(nil, registered: false) == .unsupportedKey)
        #expect(ShortcutProblem.forRecording(spec, registered: false) == .refused)
        #expect(ShortcutProblem.forRecording(spec, registered: true) == nil)
    }

    @Test func displayChoicesStartWithMainThenEachDisplay() {
        let names = ["P": "Built-in Retina Display", "S": "Studio Display"]
        #expect(DisplayChoice.options(screens: [screen("P", primary: true), screen("S", primary: false)],
                                      names: names, pinned: nil) == [
            DisplayOption(id: nil, title: "Main display", connected: true),
            DisplayOption(id: "P", title: "Built-in Retina Display", connected: true),
            DisplayOption(id: "S", title: "Studio Display", connected: true),
        ])
    }

    @Test func aPinnedDisplayThatIsGoneIsListedDisabled() {
        let names = ["P": "Built-in Retina Display", "S": "Studio Display"]
        let gone = DisplayChoice.options(screens: [screen("P", primary: true)], names: names, pinned: "S")
        #expect(gone.last == DisplayOption(id: "S", title: "Studio Display (not connected)", connected: false))
        #expect(gone.count == 3)
        let unnamed = DisplayChoice.options(screens: [screen("P", primary: true)], names: [:], pinned: "X")
        #expect(unnamed.last == DisplayOption(id: "X", title: "Pinned display (not connected)", connected: false))
        let here = DisplayChoice.options(screens: [screen("P", primary: true)], names: names, pinned: "P")
        #expect(here.count == 2)
    }

    @Test func aDisplayWithoutANameIsCalledDisplay() {
        #expect(DisplayChoice.options(screens: [screen("P", primary: true)], names: [:], pinned: nil)[1].title == "Display")
    }

    @Test func notifySettingsBecomeTheConfigObject() {
        let object = NotifySettings(now: false, today: true, whenever: true, sound: true, slideIn: false).configObject
        #expect(object.count == 5)
        #expect(object["now"] as? Bool == false)
        #expect(object["today"] as? Bool == true)
        #expect(object["whenever"] as? Bool == true)
        #expect(object["sound"] as? Bool == true)
        #expect(object["slideIn"] as? Bool == false)
    }

    @Test func pollAndKeepLabels() {
        #expect(ChoiceLabel.pollChoices == [5, 15, 30, 60, 300])
        #expect(ChoiceLabel.pollChoices.map(ChoiceLabel.poll) == ["5 seconds", "15 seconds", "30 seconds", "1 minute", "5 minutes"])
        #expect(ChoiceLabel.poll(20) == "20 seconds (from config.json)")
        #expect(ChoiceLabel.poll(120) == "120 seconds (from config.json)")
        #expect(ChoiceLabel.keepChoices == [3, 7, 14, 30, 90])
        #expect(ChoiceLabel.keepDays(14) == "14 days")
        #expect(ChoiceLabel.keepDays(45) == "45 days (from config.json)")
    }

    @Test func tildePathsRoundTrip() {
        #expect(TildePath.abbreviate("/home/tester/.config/relay/token", home: home) == "~/.config/relay/token")
        #expect(TildePath.expand("~/.config/relay/token", home: home) == "/home/tester/.config/relay/token")
        #expect(TildePath.expand(TildePath.abbreviate("/home/tester/a b/c", home: home), home: home) == "/home/tester/a b/c")
        #expect(TildePath.expand("~", home: home) == home)
        #expect(TildePath.abbreviate(home, home: home) == "~")
        #expect(TildePath.abbreviate("/home/testerX/a", home: home) == "/home/testerX/a")
        #expect(TildePath.expand("/opt/token", home: home) == "/opt/token")
        #expect(TildePath.expand("~other/token", home: home) == "~other/token")
    }

    @Test func aDraftStartsFromTheConfig() {
        let config = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example:8790",
                                 tokenFile: "/home/tester/.config/relay/mailbox-token", context: "work")
        #expect(MailboxDraft(config: config, home: home)
            == MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token", context: "work"))
        #expect(MailboxDraft(config: RelayConfig(mailboxURL: "https://m.example", tokenFile: "/t"), home: home).context == "")
        #expect(MailboxDraft(config: nil, home: home) == MailboxDraft())
    }

    @Test func aDraftIsDirtyOnlyWhenAFieldDiffers() {
        let config = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example:8790",
                                 tokenFile: "/home/tester/.config/relay/mailbox-token")
        var draft = MailboxDraft(config: config, home: home)
        #expect(!draft.isDirty(against: config, home: home))
        draft.address += "  "
        #expect(!draft.isDirty(against: config, home: home))
        draft.tokenFile = "/home/tester/.config/relay/mailbox-token"
        #expect(!draft.isDirty(against: config, home: home))
        draft.context = "personal"
        #expect(!draft.isDirty(against: config, home: home))
        draft.context = "work"
        #expect(draft.isDirty(against: config, home: home))
        #expect(MailboxDraft(address: "https://m.example").isDirty(against: nil, home: home))
        #expect(!MailboxDraft().isDirty(against: nil, home: home))
    }

    @Test func errorsNameTheBadField() {
        let valid = MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/token")
        #expect(valid.errors().address == nil && valid.errors().tokenFile == nil)
        #expect(MailboxDraft(tokenFile: "~/t").errors().address == "Enter the Pond URL.")
        for bad in ["mailbox.example", "ftp://mailbox.example", "http://", "https:// x"] {
            #expect(MailboxDraft(address: bad, tokenFile: "~/t").errors().address
                == "The address must start with http:// or https://.")
        }
        #expect(MailboxDraft(address: "https://m.example", tokenFile: "  ").errors().tokenFile == "Enter the token file.")
    }

    @Test func changesSaveTheMailboxAndExpandTheTilde() {
        let work = MailboxDraft(address: " https://mailbox.example:8790 ", tokenFile: "~/.config/relay/token", context: " work ")
        let saved = work.changes(home: home)
        #expect(NSDictionary(dictionary: saved.set) == NSDictionary(dictionary: [
            "source": "mailbox", "mailboxURL": "https://mailbox.example:8790",
            "tokenFile": "/home/tester/.config/relay/token", "context": "work",
        ]))
        #expect(saved.remove.isEmpty)
        let personal = MailboxDraft(address: "https://m.example", tokenFile: "/t", context: "").changes(home: home)
        #expect(personal.set["context"] == nil)
        #expect(personal.remove == ["context"])
    }

    @Test func connectionNotesShowAsOneRevealedLine() {
        let problems = ConnectionStatus.problems(
            configNote: "config.json isn't valid JSON:\nUnexpected character \u{202E} at line 3",
            listenerNote: "Port 47823 is in use by another app")
        #expect(problems == [
            "config.json isn't valid JSON:⟨U+000A⟩Unexpected character ⟨U+202E⟩ at line 3",
            "Port 47823 is in use by another app",
        ])
        #expect(ConnectionStatus.problems(configNote: nil, listenerNote: nil).isEmpty)
    }

    @Test func thePermissionRowSaysWhatToDo() {
        #expect(NotificationPermission.authorized.statusText == "Allowed")
        #expect(NotificationPermission.authorized.action == nil)
        #expect(NotificationPermission.denied.statusText == "Turned off in System Settings")
        #expect(NotificationPermission.denied.action == .openNotificationSettings)
        #expect(NotificationPermission.denied.actionTitle == "Open System Settings")
        #expect(NotificationPermission.notDetermined.statusText == nil)
        #expect(NotificationPermission.notDetermined.action == .requestNotifications)
        #expect(NotificationPermission.notDetermined.actionTitle == "Allow Notifications…")
        #expect(NotificationPermission.sentFor == 5)
    }
}


// MARK: - The owner key's setup (Settings › Queue)

/// A Pond with only the owner routes; every call is recorded.
private actor OwnerPond: QueueSource {
    var enrollResult: Result<Enrollment, QueueError> = .success(Enrollment(id: "e1", code: "000000", status: "pending"))
    /// One status per poll; the last one repeats.
    var polls: [String] = ["approved"]
    var owner = OwnerStatus(required: false, keys: [])
    var requireOutcome: OwnerKeyRequirement = .on
    private(set) var calls: [String] = []
    private(set) var enrolled: [(keyHash: String, label: String)] = []
    /// Called as the enroll arrives, before it answers.
    private var atEnroll: (@Sendable () -> Void)?

    func set(enroll: Result<Enrollment, QueueError>) { enrollResult = enroll }
    func set(polls: [String]) { self.polls = polls }
    func set(owner: OwnerStatus) { self.owner = owner }
    func set(require: OwnerKeyRequirement) { requireOutcome = require }
    func set(atEnroll: @escaping @Sendable () -> Void) { self.atEnroll = atEnroll }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    func list() async throws -> [WireItem] { throw QueueError.notSupported }
    func get(_ id: String) async throws -> AskDetail { throw QueueError.notSupported }
    func post(project: String, instructable: Data) async throws -> PostResult { throw QueueError.notSupported }
    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem { throw QueueError.notSupported }
    func reply(_ id: String, text: String) async throws -> WireItem { throw QueueError.notSupported }
    func answer(_ id: String, answers: [JSONValue]) async throws -> WireItem { throw QueueError.notSupported }
    func reopen(_ id: String) async throws -> WireItem { throw QueueError.notSupported }
    func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] { [] }
    func changes() async -> AsyncStream<Void>? { nil }

    func enroll(keyHash: String, label: String) async throws -> Enrollment {
        calls.append("enroll")
        atEnroll?()
        enrolled.append((keyHash, label))
        return try enrollResult.get()
    }

    func enrollment(_ id: String) async throws -> Enrollment {
        calls.append("enrollment")
        let status = polls.count > 1 ? polls.removeFirst() : polls[0]
        return Enrollment(id: id, status: status)
    }

    func ownerStatus() async throws -> OwnerStatus {
        calls.append("owner")
        return owner
    }

    func requireOwnerKey(_ on: Bool) async throws -> OwnerKeyRequirement {
        calls.append(on ? "require on" : "require off")
        return requireOutcome
    }
}

/// What the Keychain held when the enroll arrived.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: OwnerKeyRecord.Status?
    var value: OwnerKeyRecord.Status? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Counts the keys made.
private final class KeyMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return made.count }
    var last: String? { lock.lock(); defer { lock.unlock() }; return made.last }
    func make() -> String {
        let key = OwnerKey.generate()
        lock.lock()
        made.append(key)
        lock.unlock()
        return key
    }
}

private let pondKey = "mailbox:pond.example:8790#personal"
private let pondURL = URL(string: "https://pond.example:8790")!

private func approvedRow(_ id: String) -> OwnerKeyRow {
    OwnerKeyRow(id: id, label: id, status: "approved", created: "2026-10-29T10:00:00+00:00")
}

@MainActor
private func makeFlow(_ secrets: MemorySecretStore = MemorySecretStore(), pond: OwnerPond = OwnerPond(),
                      keys: KeyMaker = KeyMaker()) async -> OwnerKeyFlow {
    let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() },
                            generate: { keys.make() })
    await flow.attach(sourceKey: pondKey, url: pondURL, source: pond)?.value
    return flow
}

/// A seal that a test can swap, as Reset Review Records… does.
private final class SealBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _key: SymmetricKey
    init(_ key: SymmetricKey) { _key = key }
    var key: SymmetricKey {
        get { lock.lock(); defer { lock.unlock() }; return _key }
        set { lock.lock(); _key = newValue; lock.unlock() }
    }
}

/// The seal that marks the flow's records.
private let ownerSeal = SymmetricKey(data: Data(repeating: 9, count: 32))

/// The stored record, without Hook's mark (`OwnerKeyTests` checks the mark).
@MainActor
private func record(_ secrets: MemorySecretStore) -> OwnerKeyRecord? {
    secrets.peek(.ownerKey(sourceKey: pondKey)).flatMap { try? JSONDecoder().decode(OwnerKeyRecord.self, from: $0) }
        .map { var bare = $0; bare.mark = nil; return bare }
}

@MainActor @Suite struct OwnerKeyFlowTests {
    @Test func setUpWritesTheKeyFirstThenWaitsForTheTap() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["pending", "pending", "approved"])
        await pond.set(owner: OwnerStatus(required: false, keys: [approvedRow("k1")], self_: OwnerSelf(id: "k1", status: "approved")))
        // Before the Pond hears of it, the key is in the Keychain as pending, and not sent.
        let atEnroll = StatusBox()
        await pond.set(atEnroll: {
            let stored = secrets.peek(.ownerKey(sourceKey: pondKey)).flatMap { try? JSONDecoder().decode(OwnerKeyRecord.self, from: $0) }
            atEnroll.value = stored?.status
        })
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        #expect(flow.state == .notSetUp)
        let task = try #require(flow.setUp())
        await task.value
        #expect(atEnroll.value == .pending)
        let key = try #require(keys.last)
        let enrolled = await pond.enrolled
        #expect(enrolled.map(\.keyHash) == [OwnerKey.hash(key)])
        #expect(enrolled.map(\.label) == ["Studio"])
        #expect(await pond.count("enrollment") == 3)
        #expect(flow.state == .approved)
        #expect(record(secrets) == OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"))
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == key)
        await flow.refresh()?.value
        #expect(flow.status?.self_?.status == "approved")
    }

    /// After Reset Review Records… the seal is new, so the approved record's mark no longer
    /// verifies: reading the record again shows the key as not set up, and none is sent.
    @Test func aNewSealMakesTheApprovedKeyReadAsNotSetUp() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["approved"])
        let seal = SealBox(ownerSeal)
        let flow = OwnerKeyFlow(secrets: secrets, seal: { seal.key }, label: "Studio", sleep: { _ in await Task.yield() },
                                generate: { keys.make() })
        await flow.attach(sourceKey: pondKey, url: pondURL, source: pond)?.value
        await flow.setUp()?.value
        #expect(flow.state == .approved)
        seal.key = SymmetricKey(data: Data(repeating: 4, count: 32))
        await flow.reread()?.value
        #expect(flow.state == .notSetUp)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { seal.key })() == nil)
    }

    @Test func whileWaitingTheCodeIsHooksOwn() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["pending"])
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        let task = try #require(flow.setUp())
        while await pond.count("enrollment") < 2 { await Task.yield() }
        let key = try #require(keys.last)
        // The Pond's own code ("000000" here) is never what Hook shows.
        #expect(flow.state == .waiting(id: "e1", code: OwnerKey.enrollCode(id: "e1", keyHash: OwnerKey.hash(key))))
        await flow.cancelSetup()?.value
        await task.value
        #expect(flow.state == .notSetUp)
        #expect(record(secrets) == nil)
    }

    /// Setting up makes a fresh item: one already there, even one another app planted, is
    /// deleted first, so the new key never lands in an item whose access list Hook didn't set.
    /// A Pond on plain http (other than this Mac) gets no owner key: setting up stops before
    /// the Keychain and the Pond. One set up on https is bound to it.
    @Test func setUpNeedsHTTPSAndBindsTheKeyToIt() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() },
                                generate: { keys.make() })
        await flow.attach(sourceKey: pondKey, url: URL(string: "http://pond.example:8790"), source: pond)?.value
        #expect(flow.setUp() == nil)
        #expect(flow.state == .refused("The owner key needs a Pond URL that starts with https."))
        #expect(keys.count == 0)
        #expect(secrets.writes == 0)
        #expect(await pond.count("enroll") == 0)

        await pond.set(polls: ["approved"])
        await flow.attach(sourceKey: pondKey, url: pondURL, source: pond)?.value
        await flow.setUp()?.value
        #expect(flow.state == .approved)
        #expect(record(secrets)?.scheme == "https")
        let http = OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: URL(string: "http://pond.example:8790")!,
                                         seal: { ownerSeal })
        #expect(await http() == nil)
    }

    /// A key approved over https isn't sent once the Pond URL switches to http, so the flow
    /// says so instead of "approved"; switching back shows it approved again.
    @Test func aKeyApprovedOverHTTPSIsNotUsedOnAnHTTPAddress() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["approved"])
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        await flow.setUp()?.value
        #expect(flow.state == .approved)
        let http = URL(string: "http://pond.example:8790")!
        await flow.attach(sourceKey: pondKey, url: http, source: pond)?.value
        #expect(flow.state == .notUsedHere(OwnerKeyFlow.notUsedHere(scheme: "https")))
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: http, seal: { ownerSeal })() == nil)
        // The record stays: Hook neither refuses nor drops a key it only doesn't send here.
        await pond.set(owner: OwnerStatus(required: false, keys: [], self_: nil))
        await flow.refresh()?.value
        #expect(flow.state == .notUsedHere(OwnerKeyFlow.notUsedHere(scheme: "https")))
        #expect(record(secrets)?.status == .approved)
        #expect(flow.requireOwnerKey(true) == nil)
        await flow.keyRefused()?.value
        #expect(record(secrets)?.status == .approved)
        await flow.attach(sourceKey: pondKey, url: pondURL, source: pond)?.value
        #expect(flow.state == .approved)
    }

    /// Read at launch with the URL already on another scheme: not used here, never "approved".
    @Test func aRecordForAnotherSchemeReadsAsNotUsedHereAtAttach() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        let approved = OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e0", status: .approved, scheme: "http")
        try OwnerKeyVault.save(approved, secrets, sourceKey: pondKey, seal: ownerSeal)
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        #expect(flow.state == .notUsedHere(OwnerKeyFlow.notUsedHere(scheme: "http")))
        #expect(OwnerKeyFlow.notUsedHere(scheme: "http")
                == "This Mac's key was approved for the Pond's http address. Hook doesn't send it to this one.")
        // Setting up again makes a key for this address.
        await pond.set(polls: ["approved"])
        await flow.setUp()?.value
        #expect(keys.count == 1)
        #expect(flow.state == .approved)
        #expect(record(secrets)?.scheme == "https")
    }

    @Test func setUpReplacesAPlantedItemWithAFreshOne() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["approved"])
        let planted = OwnerKeyRecord(key: "known-to-its-maker", enrollID: "e0", status: .approved, scheme: "https")
        secrets.plantForeign(.ownerKey(sourceKey: pondKey), try JSONEncoder().encode(planted))
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
        await flow.setUp()?.value
        let key = try #require(keys.last)
        #expect(secrets.creates == 1)
        #expect(flow.state == .approved)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == key)
    }

    /// An approved record whose access list looks like Hook's but carries no mark Hook wrote:
    /// never sent, shown as not set up, and replaced by setting up.
    @Test func anUnmarkedRecordIsNotHooksKey() async throws {
        let planted = OwnerKeyRecord(key: "known-to-its-maker", enrollID: "e0", status: .approved, scheme: "https")
        let secrets = MemorySecretStore([.ownerKey(sourceKey: pondKey): try JSONEncoder().encode(planted)])
        let pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["approved"])
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        #expect(flow.state == .notSetUp)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
        await flow.setUp()?.value
        #expect(secrets.creates == 1)
        #expect(flow.state == .approved)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == keys.last)
        // Without the seal that marked it (none yet, or another one), the key isn't sent.
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { nil })() == nil)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { SymmetricKey(size: .bits256) })() == nil)
    }

    /// A seal the Keychain refuses is a refused read, not a missing key: nothing is replaced.
    @Test func aRefusedSealIsARefusedRead() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        let approved = OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e0", status: .approved, scheme: "https")
        try OwnerKeyVault.save(approved, secrets, sourceKey: pondKey, seal: ownerSeal)
        let flow = OwnerKeyFlow(secrets: secrets, seal: { throw SecretStoreError.unreadable(-128) }, label: "Studio",
                                sleep: { _ in await Task.yield() }, generate: { keys.make() })
        await flow.attach(sourceKey: pondKey, url: pondURL, source: pond)?.value
        #expect(flow.state == .unavailable(OwnerKeyFlow.readFailed))
        await flow.setUp()?.value
        #expect(flow.state == .unavailable(OwnerKeyFlow.readFailed))
        #expect(keys.count == 0)
        #expect(record(secrets) == approved)
    }

    @Test func aKeychainThatCantSaveStopsBeforeThePond() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        secrets.writeError = .writeFailed(-25308)
        let flow = await makeFlow(secrets, pond: pond)
        await flow.setUp()?.value
        #expect(flow.state == .unavailable("Hook couldn't save its key in the Keychain."))
        #expect(await pond.count("enroll") == 0)
    }

    @Test func aRefusedReadIsNotAMissingKey() async throws {
        let approved = OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e0", status: .approved, scheme: "https")
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        try OwnerKeyVault.save(approved, secrets, sourceKey: pondKey, seal: ownerSeal)
        secrets.readError = .unreadable(-128)
        let writes = secrets.writes
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        let text = "Hook couldn't read its key from the Keychain. Allow Hook when macOS asks, or set it up again."
        #expect(flow.state == .unavailable(text))
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
        await flow.setUp()?.value
        #expect(flow.state == .unavailable(text))
        #expect(keys.count == 0)
        #expect(secrets.writes == writes)
        #expect(await pond.count("enroll") == 0)
        secrets.readError = nil
        #expect(record(secrets) == approved)       // the old item stays
    }

    @Test func aDeclinedRequestWhoseDeleteFailsIsStillRefused() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        await pond.set(polls: ["pending", "rejected"])
        let flow = await makeFlow(secrets, pond: pond)
        let task = try #require(flow.setUp())
        while await pond.count("enroll") == 0 { await Task.yield() }
        secrets.deleteError = .deleteFailed(-25308)
        await task.value
        #expect(flow.state == .refused("The request was turned down on Telegram."))
        #expect(record(secrets)?.status == .refused)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
    }

    @Test func anExpiredRequestForgetsTheKey() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        await pond.set(polls: ["expired"])
        let flow = await makeFlow(secrets, pond: pond)
        await flow.setUp()?.value
        #expect(flow.state == .refused("The request expired before it was approved."))
        #expect(record(secrets) == nil)
    }

    @Test func tenMinutesOfWaitingIsAnExpiry() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        await pond.set(polls: ["pending"])
        let flow = await makeFlow(secrets, pond: pond)
        await flow.setUp()?.value
        #expect(await pond.count("enrollment") == 200)
        #expect(flow.state == .refused("The request expired before it was approved."))
        #expect(record(secrets) == nil)
    }

    @Test func aRefusedEnrollmentSaysWhyAndKeepsNoKey() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        await pond.set(enroll: .failure(.rejected(status: 409, error: "too many keys", details: [])))
        let flow = await makeFlow(secrets, pond: pond)
        await flow.setUp()?.value
        #expect(flow.state == .refused("Couldn't start the setup: too many keys"))
        #expect(record(secrets) == nil)
    }

    @Test func aRefusedKeyOnAnOwnerActGoesWithoutItNextTime() async throws {
        let secrets = MemorySecretStore()
        let key = OwnerKey.generate()
        try OwnerKeyVault.save(OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"), secrets, sourceKey: pondKey, seal: ownerSeal)
        let flow = await makeFlow(secrets)
        #expect(flow.state == .approved)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == key)
        await flow.keyRefused()?.value
        #expect(flow.state == .refused("The Pond no longer accepts this Mac's key."))
        #expect(record(secrets)?.status == .refused)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
    }

    @Test func afterARestartARevokedKeyIsRefused() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"), secrets,
                               sourceKey: pondKey, seal: ownerSeal)
        await pond.set(owner: OwnerStatus(required: true, keys: [approvedRow("k2")], self_: OwnerSelf(id: "k1", status: "revoked")))
        let flow = await makeFlow(secrets, pond: pond)
        await flow.refresh()?.value
        #expect(flow.state == .refused("The Pond no longer accepts this Mac's key."))
        #expect(record(secrets)?.status == .refused)
        // An unknown key (no `self`) is refused the same way.
        let other = MemorySecretStore(), unknown = OwnerPond()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"), other,
                               sourceKey: pondKey, seal: ownerSeal)
        await unknown.set(owner: OwnerStatus(required: false, keys: []))
        let second = await makeFlow(other, pond: unknown)
        await second.refresh()?.value
        #expect(second.state == .refused("The Pond no longer accepts this Mac's key."))
    }

    @Test func aRefusedReadAfterAttachKeepsTheApprovedKey() async throws {
        let approved = OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https")
        let secrets = MemorySecretStore(), pond = OwnerPond()
        try OwnerKeyVault.save(approved, secrets, sourceKey: pondKey, seal: ownerSeal)
        // No key goes out while the Keychain refuses the read, so the Pond answers `self: null`.
        await pond.set(owner: OwnerStatus(required: false, keys: [approvedRow("k1")]))
        let flow = await makeFlow(secrets, pond: pond)
        #expect(flow.state == .approved)
        secrets.readError = .unreadable(-128)
        let writes = secrets.writes
        await flow.refresh()?.value
        #expect(flow.state == .unavailable(OwnerKeyFlow.readFailed))
        #expect(secrets.writes == writes)
        #expect(record(secrets) == approved)       // peek: the item stays, still approved
    }

    @Test func aRefusedKeyWhoseReadFailsKeepsTheItem() async throws {
        let approved = OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https")
        let secrets = MemorySecretStore()
        try OwnerKeyVault.save(approved, secrets, sourceKey: pondKey, seal: ownerSeal)
        let flow = await makeFlow(secrets)
        #expect(flow.state == .approved)
        secrets.readError = .unreadable(-128)
        await flow.keyRefused()?.value
        #expect(flow.state == .unavailable(OwnerKeyFlow.readFailed))
        #expect(record(secrets) == approved)
    }

    @Test func aRefusedKeyWhoseWriteFailsIsDeleted() async throws {
        let secrets = MemorySecretStore()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"), secrets,
                               sourceKey: pondKey, seal: ownerSeal)
        let flow = await makeFlow(secrets)
        secrets.writeError = .writeFailed(-25308)
        await flow.keyRefused()?.value
        #expect(flow.state == .refused("The Pond no longer accepts this Mac's key."))
        #expect(record(secrets) == nil)
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == nil)
    }

    @Test func aPendingRequestIsPolledAgainAfterARestart() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        let key = OwnerKey.generate()
        try OwnerKeyVault.save(OwnerKeyRecord(key: key, enrollID: "e9", status: .pending, scheme: "https"), secrets, sourceKey: pondKey, seal: ownerSeal)
        await pond.set(polls: ["approved"])
        let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() })
        let task = try #require(flow.attach(sourceKey: pondKey, url: pondURL, source: pond))
        while flow.state == .reading { await Task.yield() }
        #expect(flow.state == .waiting(id: "e9", code: OwnerKey.enrollCode(id: "e9", keyHash: OwnerKey.hash(key))))
        await task.value
        #expect(flow.state == .approved)
        #expect(await pond.count("enroll") == 0)
    }

    @Test(arguments: [
        (["approved"], "approved", false),
        (["approved", "approved"], "approved", true),
        (["approved", "approved", "approved"], "approved", true),
        (["approved", "approved"], "pending", false),
        (["approved", "approved"], nil, false),
        ([], "approved", false),
    ] as [([String], String?, Bool)])
    func requireIsOfferedOnlyWithTwoApprovedMacsIncludingThisOne(_ keys: [String], _ mine: String?, _ allowed: Bool) async {
        let pond = OwnerPond()
        let rows = keys.enumerated().map { OwnerKeyRow(id: "k\($0.offset)", label: "m", status: $0.element, created: "x") }
        await pond.set(owner: OwnerStatus(required: false, keys: rows, self_: mine.map { OwnerSelf(id: "k0", status: $0) }))
        let flow = await makeFlow(pond: pond)
        #expect(!flow.canRequireOwnerKey)
        await flow.refresh()?.value
        #expect(flow.canRequireOwnerKey == allowed)
    }

    @Test func requireOnIsAtOnceAndOffWaitsForTheTap() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"), secrets,
                               sourceKey: pondKey, seal: ownerSeal)
        let me = OwnerSelf(id: "k1", status: "approved")
        await pond.set(owner: OwnerStatus(required: false, keys: [approvedRow("k1")], self_: me))
        let flow = await makeFlow(secrets, pond: pond)
        await flow.refresh()?.value
        #expect(flow.requireOwnerKey(true) == nil)          // one approved Mac: not offered
        await pond.set(owner: OwnerStatus(required: false, keys: [approvedRow("k1"), approvedRow("k2")], self_: me))
        await flow.refresh()?.value
        await flow.requireOwnerKey(true)?.value
        #expect(flow.status?.required == true)
        #expect(!flow.requireOffPending)
        await pond.set(require: .pending)
        await flow.requireOwnerKey(false)?.value
        #expect(flow.requireOffPending)
        #expect(flow.status?.required == true)
        #expect(await pond.calls.filter { $0.hasPrefix("require") } == ["require on", "require off"])
        await pond.set(owner: OwnerStatus(required: false, keys: [approvedRow("k1"), approvedRow("k2")], self_: me))
        await flow.refresh()?.value
        #expect(!flow.requireOffPending)
    }

    @Test func anotherSourceStartsFromItsOwnRecord() async throws {
        let secrets = MemorySecretStore()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"), secrets,
                               sourceKey: pondKey, seal: ownerSeal)
        let flow = await makeFlow(secrets)
        #expect(flow.state == .approved)
        await flow.attach(sourceKey: "mailbox:other.example:8790#personal", url: URL(string: "https://other.example:8790"), source: OwnerPond())?.value
        #expect(flow.state == .notSetUp)
        await flow.attach(sourceKey: nil, url: nil, source: nil)?.value
        #expect(flow.state == .notSetUp)
        #expect(flow.setUp() == nil)
    }

    /// 0.14: attaching at launch never waits on the Keychain. While its prompt is up the flow
    /// says so, sends no key and offers no setup; once answered the record reads as before.
    @Test func attachReturnsWhileTheKeychainPromptWaits() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        let key = OwnerKey.generate()
        try OwnerKeyVault.save(OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"), secrets,
                               sourceKey: pondKey, seal: ownerSeal)
        secrets.holdReads()
        let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() },
                                keychain: KeychainQueue(label: "test.held"))
        let task = try #require(flow.attach(sourceKey: pondKey, url: pondURL, source: pond))
        #expect(flow.state == .reading)
        while secrets.waitingReads == 0 { await Task.yield() }
        #expect(flow.state == .reading)
        #expect(!flow.isApproved(sourceKey: pondKey, url: pondURL))
        #expect(flow.setUp() == nil)
        secrets.releaseReads()
        await task.value
        #expect(flow.state == .approved)
        #expect(flow.isApproved(sourceKey: pondKey, url: pondURL))
        #expect(!flow.isApproved(sourceKey: pondKey, url: URL(string: "https://other.example")))
        #expect(await OwnerKeyFlow.provider(secrets, sourceKey: pondKey, url: pondURL, seal: { ownerSeal })() == key)
    }

    /// A report's Send while the key is still being read asks for the setup once the read ends,
    /// and only when the key read isn't approved.
    @Test func aSetupAskedForDuringTheReadStartsOnceItEnds() async throws {
        for approved in [false, true] {
            let secrets = MemorySecretStore(), pond = OwnerPond()
            if approved {
                try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"),
                                       secrets, sourceKey: pondKey, seal: ownerSeal)
            }
            secrets.holdReads()
            let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() },
                                    keychain: KeychainQueue(label: "test.held"))
            var asked = 0
            flow.onSetUpAfterRead = { asked += 1 }
            let read = try #require(flow.attach(sourceKey: pondKey, url: pondURL, source: pond))
            #expect(flow.setUpAfterRead())
            #expect(asked == 0)
            secrets.releaseReads()
            await read.value
            #expect(asked == (approved ? 0 : 1), "approved: \(approved)")
            #expect(!flow.setUpAfterRead())     // not reading any more: the caller sets up itself
        }
    }

    /// `GET /owner` answered while the read waited: a revoked key is still refused once it reads.
    @Test func aRevocationThatArrivesDuringTheReadStillRefusesTheKey() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond()
        try OwnerKeyVault.save(OwnerKeyRecord(key: OwnerKey.generate(), enrollID: "e1", status: .approved, scheme: "https"),
                               secrets, sourceKey: pondKey, seal: ownerSeal)
        await pond.set(owner: OwnerStatus(required: false, keys: [], self_: OwnerSelf(id: "k1", status: "revoked")))
        secrets.holdReads()
        let flow = OwnerKeyFlow(secrets: secrets, seal: { ownerSeal }, label: "Studio", sleep: { _ in await Task.yield() },
                                keychain: KeychainQueue(label: "test.held"))
        let read = try #require(flow.attach(sourceKey: pondKey, url: pondURL, source: pond))
        await flow.refresh()?.value
        #expect(flow.status?.self_?.status == "revoked")
        secrets.releaseReads()
        await read.value
        #expect(flow.state == .refused(OwnerKeyFlow.noLongerAccepted))
        #expect(record(secrets)?.status == .refused)
    }

    /// A cancel's delete runs before a setup started right after it, never after.
    @Test func setUpAfterCancelKeepsTheNewKey() async throws {
        let secrets = MemorySecretStore(), pond = OwnerPond(), keys = KeyMaker()
        await pond.set(polls: ["pending"])
        let flow = await makeFlow(secrets, pond: pond, keys: keys)
        let first = try #require(flow.setUp())
        while await pond.count("enrollment") < 1 { await Task.yield() }
        flow.cancelSetup()
        await first.value
        await pond.set(polls: ["approved"])
        await flow.setUp()?.value
        #expect(flow.state == .approved)
        #expect(record(secrets)?.key == keys.last)
        #expect(keys.count == 2)
    }
}

@Suite struct PrivacyLineTests {
    private let pond = RelayConfig(source: .mailbox, mailboxURL: "https://pond.example.com", tokenFile: "~/.config/relay/token")

    @Test func myPondIsOfferedOnlyWithAPondAndAnApprovedKey() {
        #expect(PrivacyLine.make(config: pond, ownerKey: .approved, logSize: 0).pondOffered)
        #expect(!PrivacyLine.make(config: pond, ownerKey: .notSetUp, logSize: 0).pondOffered)
        #expect(!PrivacyLine.make(config: pond, ownerKey: .waiting(id: "x", code: "123"), logSize: 0).pondOffered)
        #expect(!PrivacyLine.make(config: pond, ownerKey: .refused("no"), logSize: 0).pondOffered)
        #expect(!PrivacyLine.make(config: RelayConfig(source: .local), ownerKey: .approved, logSize: 0).pondOffered)
        #expect(!PrivacyLine.make(config: nil, ownerKey: .approved, logSize: 0).pondOffered)
        // A Pond with a broken URL isn't a Pond.
        var broken = pond
        broken.mailboxURL = "not a url"
        #expect(!PrivacyLine.make(config: broken, ownerKey: .approved, logSize: 0).pondOffered)
    }

    @Test func aSavedPondWithoutAKeyReadsAsGitHub() {
        var config = pond
        config.crashReportTarget = .pond
        #expect(PrivacyLine.make(config: config, ownerKey: .notSetUp, logSize: 0).target == .github)
        #expect(PrivacyLine.make(config: config, ownerKey: .approved, logSize: 0).target == .pond)
        #expect(PrivacyLine.make(config: nil, ownerKey: .approved, logSize: 0).reports == .ask)
    }

    @Test(arguments: [(0, "Empty"), (1, "1 KB"), (1024, "1 KB"), (86_016, "84 KB"), (1_048_576, "1.0 MB"), (1_572_864, "1.5 MB")])
    func theLogSize(_ bytes: Int, _ text: String) {
        #expect(PrivacyLine.sizeText(bytes) == text)
    }
}
