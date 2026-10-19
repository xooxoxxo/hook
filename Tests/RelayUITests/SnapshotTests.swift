import Foundation
@testable import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

private let three = [item("a", urgency: "now", created: stamp(minutesAgo: 10), steps: 3, substeps: [1: 3]),
                     item("b", created: stamp(minutesAgo: 20)),
                     item("n", project: "Northwind", created: stamp(minutesAgo: 30))]

@Suite @MainActor struct SnapshotTests {
    @Test func storeQueueSnapshot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        store.toggleTick("2.1", in: "a")
        var queue = store.queue
        #expect(queue.title == "3 waiting")
        #expect(queue.content == .list)
        #expect(queue.sourceName == "This Mac")
        #expect(queue.sections.map(\.header) == [.project("Acme"), .project("Northwind")])
        #expect(queue.rows["a"]?.summary == .steps(done: 1, total: 5))
        #expect(queue.rows["a"]?.urgency == .now)
        #expect(queue.hidden == .zero)

        store.setFilter("Acme")
        queue = store.queue
        #expect(queue.title == "2 waiting")
        #expect(queue.hidden == HiddenCount(total: 1, now: 0))
        #expect(queue.sections.map(\.header) == [nil])
        #expect(queue.projects.map(\.name) == ["Acme", "Northwind"])

        store.setFilter("Atlas")
        #expect(store.queue.title == "Queue")
        #expect(store.queue.content == .emptyFiltered(project: "Atlas"))
    }

    @Test func storeDetailSnapshot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        store.open("a")
        #expect(await eventually { store.detail("a")?.load == .loaded })
        store.toggleTick("1", in: "a")
        store.drafts["a"] = "C07"
        let detail = store.detail("a")
        #expect(detail?.current == "2.1")
        #expect(detail?.progress == StepProgress(done: 1, total: 5))
        #expect(detail?.primary == .sendAndDone)
        #expect(detail?.previous == .end)
        #expect(detail?.next == .ask("b"))
        #expect(detail?.closedText == nil)
        #expect(detail?.row.hasDraft == true)
        #expect(store.detail("missing") == nil)
    }

    @Test func storeStatusAndKeyContext() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        #expect(store.status == PanelStatus(symbol: .ok, text: "This Mac · ready", detail: .updated))
        store.away = true
        #expect(store.status.text == "Away · This Mac · ready")
        store.listSelection = "a"
        let list = store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false)
        #expect(list.mode == .list && list.selectionOpen == true && list.selectionHasProject)
        store.open("a")
        store.drafts["a"] = "x"
        let detail = store.keyContext(textFieldFocused: true, popoverOpen: false, closedHeaderFocused: false)
        #expect(detail.mode == .detail && detail.textFieldFocused && detail.hasDraftOrPick && detail.askOpen)
    }

    @Test func performRoutesCommands() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var copied: [String] = []
        store.shell = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                        copy: { copied.append($0) }, openURL: { _ in })
        await start(store, FakeQueueSource(items: three))
        store.perform(.switchGrouping)
        #expect(store.grouping == .urgency)
        store.listSelection = "n"
        store.perform(.showOnlyProject)
        #expect(store.filter == "Northwind")
        store.perform(.clearFilter)
        #expect(store.filter == nil)
        store.perform(.copyLink)
        #expect(copied == ["relay://i/n"])
        store.perform(.openSelection)
        #expect(store.selectedID == "n")
        store.perform(.pickChoice(1))
        #expect(store.pendingChoice["n"] == 1)
        store.perform(.back)
        #expect(store.selectedID == nil)
    }

    @Test func fixturesBuild() {
        #expect(GalleryFixtures.now == Timestamp.date("2026-10-16T09:40:00+00:00"))
        #expect(GalleryFixtures.open.count == 5)
        #expect(Set(GalleryFixtures.open.compactMap(\.projectId)) == ["Acme", "Relay", "Northwind"])
        let steps = GalleryFixtures.detailSteps
        #expect(steps.progress == StepProgress(done: 2, total: 8))
        #expect(steps.model?.nodes.map(\.path) == ["1", "2", "3", "4", "5", "verify"])
        #expect(steps.model?.nodes[1].children.map(\.label) == ["2a", "2b", "2c"])
        #expect(steps.model?.origin?.session == "1b2c3d4e-0000-4000-8000-000000000001")
        #expect(GalleryFixtures.detailChoice.model?.reply?.choices?.count == 2)

        let limits = GalleryFixtures.limits
        #expect(limits.row.title.count == 120)
        #expect(limits.model?.nodes.count == 21)
        #expect(limits.progress.total == 57)
        #expect(limits.model?.reply?.choices?.allSatisfy { $0.count == 60 } == true)
        #expect(limits.model?.links.count == 10)
        #expect(limits.model?.nodes.contains { $0.content.detail?.count == 1500 } == true)
        #expect(limits.model?.nodes.contains { $0.content.code?.count == 4000 } == true)

        let queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: true)
        #expect(queue.title == "5 waiting")
        #expect(queue.sections.count == 3)
        #expect(queue.rows["acme-1"]?.summary == .steps(done: 2, total: 8))
        #expect(queue.closed.count == 2)
        #expect(GalleryFixtures.queue(grouping: .project, filter: "Acme", closedExpanded: false).hidden == HiddenCount(total: 2, now: 0))
        #expect(Set(GalleryFixtures.manyProjects.compactMap(\.projectId)).count == 12)
        #expect(GalleryFixtures.manyProjects.contains { $0.projectId?.count == 60 })
    }

    @Test func fixturesPassTheValidator() throws {
        for item in GalleryFixtures.open + [GalleryFixtures.limitsItem] {
            let data = try JSONEncoder().encode(item.instructable)
            let value = try JSONValue.parse(data)
            guard case .success = Validator.validate(value) else {
                Issue.record("\(item.id) isn't a valid instructable")
                continue
            }
        }
    }

    @Test func aFixtureModelServesItsSnapshots() {
        let model = FixturePanelModel(queue: GalleryFixtures.queue(grouping: .urgency, filter: nil, closedExpanded: true),
                                      details: ["acme-1": GalleryFixtures.detailSteps],
                                      status: PanelStatus(symbol: .ok, text: "Mailbox · ready", detail: .updated))
        #expect(model.detail("acme-1") == GalleryFixtures.detailSteps)
        #expect(model.detail("nope") == nil)
        model.setGrouping(.project)
        #expect(model.queue.grouping == .urgency)
        model.listSelection = "acme-2"
        #expect(model.navigation.listSelection == "acme-2")
    }

    /// Controller ruling (Task 14 review): the 10 s "Still trying…" flip happens with no other state change.
    @Test func theStillTryingFlipNeedsNoOtherChange() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now },
                          timeoutSleep: { duration in await clock.advance(Double(duration.components.seconds)) })
        let source = FakeQueueSource(items: three)
        await source.setListDelay(.seconds(3600))
        store.swap(to: source, identity: localIdentity, pollSeconds: 3600)
        #expect(store.queue.content == .loading(stillTrying: false))
        #expect(await eventually { store.stateTick == 1 })
        #expect(store.queue.content == .loading(stillTrying: true))
        store.swap(to: nil, identity: localIdentity, pollSeconds: 3600)
    }
}

@MainActor @Suite struct PanelRootTests {
    @Test func detailShowsOnlyWithAnOpenAsk() {
        #expect(!PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation()))
        #expect(!PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(listSelection: "a1")))
        #expect(PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(listSelection: "a1", selectedID: "a1")))
        // An ask outside the filter (slide-in, link) opens with no list selection.
        #expect(PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(selectedID: "outside")))
    }

    @Test func galleryOverridesDefaultToNothing() {
        let overrides = EnvironmentValues().panelGallery
        #expect(overrides == PanelGalleryOverrides())
        #expect(overrides.now == nil && overrides.closedExpanded == nil && overrides.fromExpanded == nil && overrides.fullHeight == nil)
    }
}

/// 2026-10-16T09:40:00Z, the gallery clock.
private let phase3Now = Date(timeIntervalSince1970: 1_792_143_600)

/// A Store over a fake mailbox source, listed once, on its own throwaway defaults suite.
@MainActor struct PanelTestEnv {
    let store: Store
    let fake: FakeQueueSource
    let suite: String

    static func make(_ items: [WireItem], details: [String: AskDetail] = [:],
                     sentHold: Duration = .seconds(4)) async -> PanelTestEnv {
        let suite = "relay.test.phase3." + UUID().uuidString
        let fake = FakeQueueSource(items: items, details: details)
        let store = Store(defaults: UserDefaults(suiteName: suite)!, now: { phase3Now }, sentHold: sentHold)
        store.swap(to: fake, identity: SourceIdentity(key: "mailbox:mailbox.example#personal", mailbox: nil),
                   pollSeconds: 3600)
        await store.refresh(manual: false)
        return PanelTestEnv(store: store, fake: fake, suite: suite)
    }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

@MainActor @Suite struct QueueHeaderSnapshotTests {
    @Test func filteredTitleCountsTheProjectOnlyAndHiddenCountsNow() async {
        let env = await PanelTestEnv.make([
            item("a1", project: "Acme", created: "2026-10-16T08:00:00+00:00"),
            item("a2", project: "Acme", created: "2026-10-16T08:10:00+00:00"),
            item("n1", project: "Northwind", urgency: "now", created: "2026-10-16T08:20:00+00:00"),
            item("t1", project: "Atlas", created: "2026-10-16T08:30:00+00:00"),
        ])
        defer { env.tearDown() }
        #expect(env.store.queue.title == "4 waiting")
        env.store.setFilter("Acme")
        let queue = env.store.queue
        #expect(queue.title == "2 waiting")
        #expect(queue.filter == "Acme")
        #expect(queue.hidden == HiddenCount(total: 2, now: 1))
        #expect(queue.sections.count == 1)
        #expect(queue.sections.first?.header == nil)
        #expect(queue.projects.map(\.name) == ["Acme", "Atlas", "Northwind"])
    }

    @Test func filterAnnouncementSanitizesTheProject() {
        #expect(QueueView<FixturePanelModel>.filterAnnouncement("Acme") == "Showing only Acme")
        #expect(QueueView<FixturePanelModel>.filterAnnouncement("Ac\u{202E}me") == "Showing only Ac⟨U+202E⟩me")
        #expect(QueueView<FixturePanelModel>.filterAnnouncement(nil) == "Showing all projects")
    }
}

@MainActor @Suite struct QueueBarsSnapshotTests {
    @Test func offlineWithACacheKeepsTheListAndSaysSoOnce() async {
        let env = await PanelTestEnv.make([item("a1", created: "2026-10-16T08:00:00+00:00")])
        defer { env.tearDown() }
        await env.fake.failNext(QueueError.unreachable("The mailbox didn't answer within 10 seconds."))
        await env.store.refresh(manual: false)
        #expect(env.store.queue.content == .list)
        guard case .offlineCached = env.store.notice else {
            Issue.record("expected .offlineCached, got \(String(describing: env.store.notice))")
            return
        }
        #expect(env.store.status.text == "Mailbox · offline")
        #expect(env.store.notice?.text != env.store.status.text)
        #expect(StatusDetails.message(env.store.status, updated: "09:40") != env.store.status.text)
    }

    @Test func popoverLinePerDetail() {
        func status(_ detail: StatusDetail, _ text: String) -> PanelStatus {
            var status = PanelStatus.make(StatusInputs(sourceKey: "mailbox:mailbox.example#personal", reachable: true, loadedOnce: true))
            status.detail = detail
            status.text = text
            return status
        }
        #expect(StatusDetails.message(status(.updated, "Mailbox · ready"), updated: "10:42") == "Updated 10:42")
        #expect(StatusDetails.message(status(.updated, "Mailbox · ready"), updated: "") == nil)
        #expect(StatusDetails.message(status(.unreachable(reason: "timed out\nretry"), "Mailbox · offline"), updated: "10:42")
                == "timed out⟨U+000A⟩retry")
        #expect(StatusDetails.message(status(.config(note: "port: must be 1–65535"), "config.json has an error"), updated: "")
                == "port: must be 1–65535")
        #expect(StatusDetails.message(status(.listener(note: "Port 47823 is in use by another app"), "Links aren't working"), updated: "")
                == "Port 47823 is in use by another app")
        // Not set up: a click on the status opens setup directly (design §4.3), so there is no popover line.
        #expect(StatusDetails.message(status(.notSetUp, "Not set up"), updated: "") == nil)
        #expect(StatusDetails.opensSetUp(status(.notSetUp, "Not set up")))
        #expect(!StatusDetails.opensSetUp(status(.updated, "Mailbox · ready")))
    }

    /// Controller ruling (Task 10 review): the Undo announcement follows the verdict and is
    /// posted once, when the held close is added; undoing or re-showing the bar never repeats it.
    @Test func undoAnnouncementIsPostedOncePerHeldClose() async {
        let env = await PanelTestEnv.make([
            item("a1", created: "2026-10-16T08:00:00+00:00"),
            item("a2", created: "2026-10-16T08:10:00+00:00"),
        ])
        defer { env.tearDown() }
        var announced: [String] = []
        env.store.onAnnounce = { announced.append($0) }
        env.store.close("a1", .done)
        env.store.close("a2", .declined)
        env.store.undo()
        #expect(announced == ["Done. Undo available for 10 seconds.", "Skipped. Undo available for 10 seconds."])
    }

    /// Controller ruling (Task 10 review): while held closes are sent on quit, the Undo bar
    /// shows "Sending" instead of the countdown, and Undo is off.
    @Test func undoBarSendingState() {
        let undo = UndoInfo(verdict: .done, title: "Store the key", deadline: Date(timeIntervalSince1970: 1_000), more: 0)
        #expect(UndoBar.sendingText == "Sending")
        #expect(UndoBar.accessibilityText(undo, sending: true, secondsLeft: 8) == "Done: Store the key. Sending")
        #expect(UndoBar.accessibilityText(undo, sending: false, secondsLeft: 8) == "Done: Store the key. Undo, 8 seconds left")
    }
}

@MainActor @Suite struct DetailFrameSnapshotTests {
    private let closedID = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"
    private let closedAt = "2026-10-16T06:12:00+00:00"

    @Test func closedSnapshotSaysWhoClosedItAndWhen() async {
        let ins = Instructable(v: 1, title: "Rotate the example token", steps: [Step(action: "Open the key page")])
        let closed = WireItem(id: closedID, title: ins.title, status: "done", projectId: "Acme",
                              created: "2026-10-16T05:00:00+00:00", updated: closedAt,
                              payload: Payload(instructable: ins), completedAt: closedAt)
        let events = [Event(seq: 1, itemId: closedID, kind: "resolved", actor: "owner", text: nil, at: closedAt)]
        let env = await PanelTestEnv.make([], details: [closedID: AskDetail(item: closed, events: events)])
        defer { env.tearDown() }
        await env.store.focus(closedID)
        let snapshot = env.store.detail(closedID)
        #expect(snapshot?.closedText == ClosedText.detail(status: "done", closedBy: "owner", closedAt: closedAt))
        #expect(ClosedText.detail(status: "done", closedBy: "owner", closedAt: closedAt,
                                  locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
                == "Done by you · 16 Oct, 06:12")
        if let snapshot {
            #expect(DetailView<FixturePanelModel>.actionMode(snapshot) == .closed(snapshot.closedText ?? ""))
        }
    }

    @Test func legacyCommandIsOneNode() {
        let legacy = WireItem(id: "l1", title: "Check the version", status: "open", projectId: "Atlas",
                              created: "2026-10-16T07:40:00+00:00", updated: "2026-10-16T07:40:00+00:00",
                              payload: Payload(why: "Before the rotation.", cmd: "relay --version"))
        let model = DetailModel.make(item: legacy, events: [])
        #expect(model.nodes.count == 1)
        #expect(model.nodes.first?.path == "1")
        #expect(Flow.leaves(of: model.nodes).map(\.path) == ["1"])
    }

    @Test func actionModeFollowsBusyAndPrimary() {
        var snapshot = GalleryFixtures.detailSteps
        snapshot.closedText = nil
        snapshot.busy = false
        snapshot.primary = .done
        #expect(DetailView<FixturePanelModel>.actionMode(snapshot) == .open(.done))
        snapshot.primary = .sendAndDone
        #expect(DetailView<FixturePanelModel>.actionMode(snapshot) == .open(.sendAndDone))
        snapshot.busy = true
        #expect(DetailView<FixturePanelModel>.actionMode(snapshot) == .busy(.sendAndDone))
    }

    @Test func neighbourTargets() {
        #expect(DetailView<FixturePanelModel>.target(.ask("a2")) == "a2")
        #expect(DetailView<FixturePanelModel>.target(.end) == nil)
        #expect(DetailView<FixturePanelModel>.target(.outsideFilter) == nil)
    }
}

@MainActor @Suite struct DetailStepsSnapshotTests {
    @Test func fixtureHasSubStepTwoACurrent() throws {
        let snapshot = GalleryFixtures.detailSteps
        let nodes = try #require(snapshot.model?.nodes)
        #expect(snapshot.ticks == ["1", "2.2"])   // Task 39's certTicks: step 1 and 2b done, so 2a is current
        #expect(snapshot.current == "2.1")
        #expect(Flow.currentStep(ticks: snapshot.ticks, nodes: nodes) == snapshot.current)
        #expect(snapshot.progress == Flow.progress(ticks: snapshot.ticks, nodes: nodes))
        #expect(snapshot.progress.total == 8)
        let parent = try #require(nodes.first { $0.path == "2" })
        #expect(parent.children.map(\.path) == ["2.1", "2.2", "2.3"])
        #expect(Flow.state(of: parent.children[0], ticks: snapshot.ticks, current: snapshot.current) == .current)
        #expect(DetailSteps<FixturePanelModel>.progressText(snapshot.progress)
                == "\(snapshot.progress.done) of 8 done")
    }

    @Test func rotorTitlesUseTheLabelAndASanitizedAction() {
        let nodes = DetailModel.nodes(
            steps: [Step(action: "Create the Slack app", substeps: [Step(action: "Click Create New App"),
                                                                     Step(action: "Name\u{200B} it")])],
            verify: Step(action: "Check the bot posts"))
        let titles = Flow.flattened(nodes).map(DetailSteps<FixturePanelModel>.rotorTitle)
        #expect(titles == ["1. Create the Slack app", "1a. Click Create New App", "1b. Name⟨U+200B⟩ it",
                           "Verify. Check the bot posts"])
    }

    /// Ruling 2: a sub-step is a scroll and rotor target in its own right, by its own path.
    @Test func aSubStepsScrollTargetIsItsOwnPath() throws {
        let nodes = DetailModel.nodes(
            steps: [Step(action: "Open the console"), Step(action: "Pick the project"),
                    Step(action: "Create the app", substeps: [Step(action: "Click New App"), Step(action: "Name it Acme")])],
            verify: nil)
        let parent = try #require(nodes.first { $0.path == "3" })
        #expect(parent.children.map(\.path) == ["3.1", "3.2"])   // what DetailSteps passes as childPaths
        #expect(parent.children[1].id == "3.2")                  // the rotor entry id and the row's .id
        #expect(Flow.flattened(nodes).map(\.id) == ["1", "2", "3", "3.1", "3.2"])
    }

    @Test func expansionTogglesOnePathAndKeepsTheRest() {
        #expect(DetailSteps<FixturePanelModel>.toggled(nil, path: "1", expanded: true) == ["1"])
        #expect(DetailSteps<FixturePanelModel>.toggled(["1", "2.1"], path: "1", expanded: false) == ["2.1"])
        #expect(DetailSteps<FixturePanelModel>.toggled(["2"], path: "2.1", expanded: true) == ["2", "2.1"])
    }

    /// A done parent collapses and its sub-step rows are not rendered, so the rotor leaves them out
    /// until the parent is expanded; an open parent keeps them.
    @Test func theRotorSkipsTheSubStepsOfADoneCollapsedParent() {
        let nodes = DetailModel.nodes(
            steps: [Step(action: "Open the console"),
                    Step(action: "Create the app", substeps: [Step(action: "Click New App"), Step(action: "Name it Acme")]),
                    Step(action: "Copy the key", substeps: [Step(action: "Open Keys"), Step(action: "Click Copy")])],
            verify: Step(action: "Check the key is saved"))
        let ticks: Set<String> = ["1", "2.1", "2.2", "3.1"]
        let current = Flow.currentStep(ticks: ticks, nodes: nodes)
        #expect(current == "3.2")
        let collapsed = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: ticks, current: current, expanded: [])
        #expect(collapsed.map(\.path) == ["1", "2", "3", "3.1", "3.2", "verify"])
        let expanded = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: ticks, current: current, expanded: ["2"])
        #expect(expanded.map(\.path) == Flow.flattened(nodes).map(\.path))
        // A sub-step's own expansion doesn't bring back the rows of its collapsed parent.
        let childOnly = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: ticks, current: current, expanded: ["2.1"])
        #expect(childOnly.map(\.path) == ["1", "2", "3", "3.1", "3.2", "verify"])
    }

    /// Task 16 ruling: `substeps: []` decodes as an empty list, and that step is a plain StepView.
    @Test func anEmptySubstepsListRendersAsAPlainStep() throws {
        let json = #"{"do": "Open the console", "substeps": []}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(json.utf8))
        #expect(step.substeps == [])
        let nodes = DetailModel.nodes(steps: [step], verify: nil)
        #expect(nodes.map(\.path) == ["1"])
        #expect(!DetailSteps<FixturePanelModel>.rendersAsParent(nodes[0]))
        #expect(Flow.flattened(nodes).map(\.id) == ["1"])
    }
}

@MainActor @Suite struct DetailReplySnapshotTests {
    private func replyItem(_ id: String, choices: [String]?, steps: [Step] = []) -> WireItem {
        let ins = Instructable(v: 1, title: "Pick where the example repo lives", steps: steps,
                               reply: ReplySpec(prompt: "Where should it live?", choices: choices))
        return WireItem(id: id, title: ins.title, status: "open", projectId: "Acme",
                        created: "2026-10-16T08:00:00+00:00", updated: "2026-10-16T08:00:00+00:00",
                        payload: Payload(instructable: ins))
    }

    @Test func primaryFlipsWithANonBlankDraft() async {
        let free = replyItem("r1", choices: nil)
        let env = await PanelTestEnv.make([free], details: ["r1": AskDetail(item: free, events: [])])
        defer { env.tearDown() }
        #expect(env.store.detail("r1")?.primary == .done)
        env.store.drafts["r1"] = "C0123ABCDEF"
        #expect(env.store.detail("r1")?.primary == .sendAndDone)
        env.store.drafts["r1"] = "   "
        #expect(env.store.detail("r1")?.primary == .done)
    }

    @Test func latestSentChoiceDisablesSendAndAnotherPickReenablesIt() async {
        let choice = replyItem("c1", choices: ["Option A", "Option B"])
        let events = [Event(seq: 1, itemId: "c1", kind: "reply", actor: "owner", text: "choice: Option B",
                            at: "2026-10-16T09:12:00+00:00")]
        let env = await PanelTestEnv.make([choice], details: ["c1": AskDetail(item: choice, events: events)])
        defer { env.tearDown() }
        let sent = env.store.detail("c1")
        #expect(sent?.sentChoices == [1])
        #expect(sent?.latestSentChoice == 1)
        env.store.pendingChoice["c1"] = 1
        #expect(env.store.detail("c1")?.primary == .done)
        #expect(!ChoiceGroup.canSend(picked: 1, latestSent: 1, sending: false))
        env.store.pendingChoice["c1"] = 0
        #expect(env.store.detail("c1")?.primary == .sendAndDone)
        #expect(ChoiceGroup.canSend(picked: 0, latestSent: 1, sending: false))
    }

    /// Task 38 ruling: the detail's reply state reads the Store's send state, .sent and then
    /// .idle once the hold elapses.
    @Test func theDetailShowsSentAndThenIdleAfterTheHold() async {
        let free = replyItem("r1", choices: nil)
        let env = await PanelTestEnv.make([free], details: ["r1": AskDetail(item: free, events: [])],
                                          sentHold: .milliseconds(20))
        defer { env.tearDown() }
        #expect(env.store.detail("r1")?.reply == .idle)
        env.store.drafts["r1"] = "C0123ABCDEF"
        #expect(await env.store.sendReply("r1"))
        guard case .sent = env.store.detail("r1")?.reply else {
            Issue.record("expected .sent, got \(String(describing: env.store.detail("r1")?.reply))")
            return
        }
        #expect(await eventually { env.store.detail("r1")?.reply == .idle })
    }

    @Test func anEmptyFieldStoresNoDraft() {
        #expect(DetailReply<FixturePanelModel>.storedDraft("") == nil)
        #expect(DetailReply<FixturePanelModel>.storedDraft("  ") == "  ")
        #expect(DetailReply<FixturePanelModel>.storedDraft("C07") == "C07")
    }

    /// Ruling 1: an open ask with a free reply whose steps have no code, url or sub-steps.
    @Test func onlyAnOpenFreeReplyAskWithInformationalStepsFocusesTheField() {
        var snapshot = GalleryFixtures.detailSteps
        snapshot.closedText = nil
        let reply = ReplySpec(prompt: "Paste the channel ID", choices: nil)
        snapshot.model?.reply = reply
        #expect(!DetailView<FixturePanelModel>.focusesReplyOnOpen(snapshot))      // its steps have code, a url and sub-steps
        snapshot.model?.nodes = DetailModel.nodes(steps: [Step(action: "Look up the channel ID in Slack")], verify: nil)
        #expect(DetailView<FixturePanelModel>.focusesReplyOnOpen(snapshot))       // one informational step
        // Task 16 ruling: an empty substeps list is no sub-steps.
        snapshot.model?.nodes = DetailModel.nodes(steps: [Step(action: "Look up the channel ID in Slack", substeps: [])],
                                                  verify: nil)
        #expect(DetailView<FixturePanelModel>.focusesReplyOnOpen(snapshot))
        snapshot.model?.reply = ReplySpec(prompt: "Which one?", choices: ["A", "B"])
        #expect(!DetailView<FixturePanelModel>.focusesReplyOnOpen(snapshot))      // choices: no field
        snapshot.model?.reply = reply
        snapshot.closedText = "Done by you · 16 Oct, 06:12"
        #expect(!DetailView<FixturePanelModel>.focusesReplyOnOpen(snapshot))      // closed: Reply anyway is collapsed
    }
}
