import Combine
import Foundation
@testable import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

private let open = [item("a", urgency: "now", created: stamp(minutesAgo: 10), steps: 3, substeps: [1: 3]),
                    item("b", created: stamp(minutesAgo: 20)),
                    item("n", project: "Northwind", created: stamp(minutesAgo: 30))]
private let gone = [closed(item("c", created: stamp(minutesAgo: 90))), closed(item("d", created: stamp(minutesAgo: 95)), status: "dismissed")]

/// Counts `objectWillChange` sends while it lives.
@MainActor private final class PublishCounter {
    private(set) var count = 0
    private var token: AnyCancellable?

    init(_ store: Store) {
        token = store.objectWillChange.sink { [weak self] _ in self?.count += 1 }
    }
}

/// The queue is a stored snapshot: rebuilt when an input changes, published only when it differs.
@Suite @MainActor struct QueuePublishTests {
    private func settledStore(_ defaults: TestDefaults, clock: TestClock) async -> (Store, FakeQueueSource) {
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        let source = FakeQueueSource(items: open)
        await source.setClosed(gone)
        await start(store, source)
        await store.refresh()
        return (store, source)
    }

    @Test func aListThatChangesNothingPublishesNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, source) = await settledStore(defaults, clock: clock)
        let before = store.queue
        let counter = PublishCounter(store)
        let lists = await source.count("list")

        await store.refresh()
        await store.refresh()

        #expect(await source.count("list") == lists + 2)
        #expect(counter.count == 0)
        #expect(store.queue == before)
    }

    @Test func aListThatChangesSomethingPublishesAndRebuilds() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, source) = await settledStore(defaults, clock: clock)
        let counter = PublishCounter(store)

        await source.setItems(open + [item("e", project: "Atlas", created: stamp(minutesAgo: 1))])
        await store.refresh()

        #expect(counter.count > 0)
        #expect(store.queue.title == "4 waiting")
        #expect(store.queue.rows["e"] != nil)
    }

    @Test func readingTheQueueBuildsNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await settledStore(defaults, clock: TestClock())
        let builds = store.queueBuilds
        for _ in 0..<10 {
            _ = store.queue
            _ = store.visibleOrder
            _ = store.closedShown
            _ = store.sections
        }
        #expect(store.queueBuilds == builds)
    }

    /// Typing in the reply box changes no queue row; only the first character (the draft mark) does.
    @Test func typingADraftRebuildsTheQueueOnlyWhenTheMarkChanges() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await settledStore(defaults, clock: TestClock())
        let builds = store.queueBuilds
        store.drafts["a"] = "C"
        #expect(store.queue.rows["a"]?.hasDraft == true)
        #expect(store.queueBuilds == builds + 1)
        store.drafts["a"] = "C0"
        store.drafts["a"] = "C07"
        #expect(store.queueBuilds == builds + 1)
        store.drafts["a"] = "  "
        #expect(store.queue.rows["a"]?.hasDraft == false)
        #expect(store.queueBuilds == builds + 2)
    }

    /// The once-a-second check while a close is held publishes nothing until the close is due.
    @Test func aHeldCloseIsQuietUntilItIsDue() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, _) = await settledStore(defaults, clock: clock)
        store.close("b", .done)
        let counter = PublishCounter(store)
        for _ in 0..<5 {
            clock.advance(1)
            store.sendDue()
        }
        #expect(counter.count == 0)
        #expect(store.undoInfo != nil)
        clock.advance(PendingCloses.delay)
        store.sendDue()
        #expect(counter.count > 0)
        #expect(store.undoInfo == nil)
    }

    /// A closed ask whose events name no closer is fetched once, not on every list.
    @Test func aClosedAskWithoutACloserIsFetchedOnce() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await settledStore(defaults, clock: TestClock())
        let gets = await source.count("get c")
        await store.refresh()
        await store.refresh()
        #expect(await source.count("get c") == gets)
        #expect(store.closedBy(gone[0]) == nil)
    }

    @Test func theSnapshotHasTheSameRowsForTheSameInputs() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await settledStore(defaults, clock: TestClock())
        let first = store.queue
        store.setGrouping(.urgency)
        store.setGrouping(.project)
        #expect(store.queue == first)
        #expect(store.queue.rows["a"] == first.rows["a"])
        #expect(store.queue.closed.map(\.id) == ["c", "d"])
    }
}

@Suite struct RowModelTests {
    @Test func datesAreParsedOnceAndFollowTheStamps() {
        var row = AskRowModel(id: "a", title: "Ask", project: "Acme", urgency: .today, created: "2026-10-16T09:30:00+00:00",
                              summary: .none)
        #expect(row.createdDate == Timestamp.date("2026-10-16T09:30:00+00:00"))
        row.created = "2026-10-16T09:00:00Z"
        #expect(row.createdDate == Timestamp.date("2026-10-16T09:00:00+00:00"))
        row.created = "not a date"
        #expect(row.createdDate == nil)
        var info = ClosedInfo(status: "done", closedBy: nil, completedAt: "2026-10-16T09:35:00+00:00")
        #expect(info.completedDate != nil)
        info.completedAt = nil
        #expect(info.completedDate == nil)
    }

    @Test func agesFromDatesMatchAgesFromStamps() {
        let created = "2026-10-16T07:10:00+00:00"
        for minutes: Double in [0, 0.5, 12, 61, 1800] {
            let now = fixedNow.addingTimeInterval(minutes * 60)
            #expect(RelativeAge.text(created: Timestamp.date(created), now: now) == RelativeAge.text(created: created, now: now))
            #expect(RelativeAge.compact(created: Timestamp.date(created), now: now) == RelativeAge.compact(created: created, now: now))
            #expect(ClosedLine.text(status: "done", closedBy: nil, completed: Timestamp.date(created), now: now)
                == ClosedLine.text(status: "done", closedBy: nil, completedAt: created, now: now))
        }
        #expect(RelativeAge.text(created: nil, now: fixedNow) == "")
        #expect(ClosedLine.text(status: "dismissed", closedBy: nil, completed: nil, now: fixedNow) == "Skipped")
    }
}

/// Cards compare on what they draw, never on their actions, so the List can skip them.
@Suite @MainActor struct RowEquatableTests {
    private let row = AskRowModel(id: "a", title: "Ask a", project: "Acme", urgency: .now, created: "2026-10-16T09:30:00+00:00",
                                  summary: .steps(done: 0, total: 3))

    @Test func askRowIgnoresItsAction() {
        let one = AskRow(row: row, age: "10 min ago", compactAge: "10m", onShowOnlyProject: {})
        let two = AskRow(row: row, age: "10 min ago", compactAge: "10m", onShowOnlyProject: { print("other") })
        #expect(one == two)
        #expect(one != AskRow(row: row, age: "11 min ago", compactAge: "11m", onShowOnlyProject: {}))
        var ticked = row
        ticked.summary = .steps(done: 1, total: 3)
        #expect(one != AskRow(row: ticked, age: "10 min ago", compactAge: "10m", onShowOnlyProject: {}))
    }

    @Test func closedRowAndCardCompareOnTheirData() {
        let one = ClosedAskRow(row: row, closedLine: "Done 5 min ago", onReopen: {}, onShowOnlyProject: {})
        #expect(one == ClosedAskRow(row: row, closedLine: "Done 5 min ago", onReopen: { print("x") }, onShowOnlyProject: {}))
        #expect(one != ClosedAskRow(row: row, closedLine: "Done 6 min ago", onReopen: {}, onShowOnlyProject: {}))
        #expect(CardBackground(selected: true) == CardBackground(selected: true))
        #expect(CardBackground(selected: true) != CardBackground(selected: false))
        #expect(CardBackground(selected: false, quiet: true) != CardBackground(selected: false))
    }

    /// The queue view takes values from the model: detail-only state (drafts, anchors) leaves it equal.
    @Test func queueViewIsEqualUntilWhatItDrawsChanges() {
        let model = FixturePanelModel(queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: true),
                                      status: PanelStatus.make(StatusInputs(sourceKey: SourceKey.local, reachable: true,
                                                                            loadedOnce: true, problem: nil, configNote: nil,
                                                                            listenerNote: nil, away: false, sendingCloses: 0)))
        let first = QueueView(model: model)
        model.drafts["x"] = "typing"
        model.detailAnchor["x"] = "2.1"
        model.expandedDone["x"] = ["1"]
        #expect(QueueView(model: model) == first)
        model.listSelection = model.queue.sections.first?.items.first?.id
        #expect(QueueView(model: model) != first)
        let selected = QueueView(model: model)
        model.queue.title = "Changed"
        #expect(QueueView(model: model) != selected)
    }
}

@Suite struct TimestampCacheTests {
    @Test func cachedParsesMatchTheFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let samples = ["2026-10-16T09:40:00+00:00", "2026-10-16T09:40:00Z", "2026-10-16T11:40:00+02:00",
                       "2026-10-16T09:40:00.123Z", "2026-13-16T09:40:00Z", "", "yesterday", "2026-10-16"]
        for _ in 0..<2 {
            for sample in samples { #expect(Timestamp.date(sample) == formatter.date(from: sample), "\(sample)") }
        }
    }

    @Test func theCacheStartsOverWhenFull() {
        for i in 0...(Timestamp.parseCacheLimit + 10) {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            #expect(Timestamp.date(Timestamp.string(date)) == date)
        }
    }

    @Test func stringsRoundTripFromManyThreads() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                group.addTask {
                    let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(i * 61))
                    return Timestamp.date(Timestamp.string(date)) == date
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}
