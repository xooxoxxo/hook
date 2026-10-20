import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// a: steps 1, 2 (2.1, 2.2, 2.3), 3.
private let a = item("a", created: stamp(minutesAgo: 10), steps: 3, substeps: [1: 3])
private let b = item("b", created: stamp(minutesAgo: 20), steps: 2)

@Suite @MainActor struct StoreTicksTests {
    @Test func ticksSurviveANewStore() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let first = Store(defaults: defaults.defaults)
        await start(first, FakeQueueSource(items: [a, b]))
        first.toggleTick("1", in: "a")
        first.toggleTick("2.2", in: "a")
        #expect(first.ticks(for: "a") == ["1", "2.2"])

        let second = Store(defaults: defaults.defaults)
        await start(second, FakeQueueSource(items: [a, b]))
        #expect(second.ticks(for: "a") == ["1", "2.2"])
        #expect(second.ticks(for: "b") == [])
    }

    @Test func aParentTicksAndUnticksAllItsSubsteps() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [a]))
        store.toggleTick("2.1", in: "a")
        store.toggleTick("2", in: "a")
        #expect(store.ticks(for: "a") == ["2.1", "2.2", "2.3"])
        store.toggleTick("2", in: "a")
        #expect(store.ticks(for: "a") == [])
        store.toggleTick("nope", in: "a")
        #expect(store.ticks(for: "a") == [])
    }

    @Test func tickCurrentAndUntickLastWalkLeaves() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [a]))
        #expect(store.tickCurrent(in: "a") == "1")
        #expect(store.tickCurrent(in: "a") == "2.1")
        store.toggleTick("3", in: "a")
        #expect(store.untickLast(in: "a") == "3")
        #expect(store.untickLast(in: "a") == "2.1")
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.untickLast(in: "a") == "1")
        #expect(store.untickLast(in: "a") == nil)
    }

    @Test func pruneKeepsHeldAndClosedWhateverTheFilter() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let d = defaults.defaults
        let one = DetailModel.nodes(steps: [Step(action: "Step 1")], verify: nil)
        let store = Store(defaults: d)
        let fake = FakeQueueSource(items: [a, b])
        await fake.setClosed([closed(item("c", created: stamp(minutesAgo: 90)))])
        await start(store, fake)
        store.toggleTick("1", in: "a")
        store.toggleTick("1", in: "b")
        TickStore.save(d, sourceKey: "local", id: "c", ticks: ["1"], nodes: one)
        TickStore.save(d, sourceKey: "local", id: "z", ticks: ["1"], nodes: one)
        store.setFilter("Northwind")
        store.close("b", .done)
        // A new ask changes the listed ids, so this list prunes (one with the same ids skips it).
        await fake.setItems([a, b, item("d", created: stamp(minutesAgo: 5))])

        await store.refresh()

        for id in ["a", "b", "c"] { #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: id)) != nil, "\(id)") }
        #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "z")) == nil)
    }

    @Test func noPruneWhenTheListIsEmptyOrUnreachable() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let d = defaults.defaults
        TickStore.save(d, sourceKey: "local", id: "z", ticks: ["1"], nodes: DetailModel.nodes(steps: [Step(action: "Step 1")], verify: nil))
        let store = Store(defaults: d)
        let fake = FakeQueueSource()
        await start(store, fake)
        #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "z")) != nil)
        await fake.setItems([a])
        await fake.failNext(QueueError.unreachable("down"), on: "list")
        await store.refresh()
        #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "z")) != nil)
        // A good list while the listener has a problem: the list works but the source
        // isn't reachable, so pruneTicks' own guard must hold.
        store.setListenerProblem("Port 8765 is in use by another app")
        await store.refresh()
        #expect(!store.reachable)
        #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "z")) != nil)
    }

    @Test func expansionAndAnchorsStayInMemory() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [a]))
        store.expandedDone["a"] = ["1", "2"]
        store.detailAnchor["a"] = "2.1"
        let relayKeys = defaults.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("relay.") }
        #expect(relayKeys.allSatisfy { $0.hasPrefix("relay.panel.selection.") || $0.hasPrefix("relay.queue.") })
    }

    /// A stale tick never reaches a count.
    @Test func repeatedTicksBuildTheTreeOnceUntilTheStepsChange() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [a])
        await start(store, fake)
        // The queue snapshot reads ticks too, so the one build may have happened already.
        let base = store.stepTreeBuilds
        #expect(store.ticks(for: "a") == [])
        #expect(store.ticks(for: "a") == [])
        #expect(store.stepTreeBuilds <= base + 1)
        #expect(store.stepTreeBuilds >= 1)

        // A tick saves and refills the cache: reads after it build nothing.
        store.toggleTick("1", in: "a")
        let afterToggle = store.stepTreeBuilds
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.stepTreeBuilds == afterToggle)

        // A re-posted ask (new `updated`) refetches its detail, which drops the cache:
        // the next read builds the tree once, later reads build nothing.
        var touched = a
        touched.updated = stamp(minutesAgo: 2)
        await fake.setItems([touched])
        await store.refresh()
        let afterTouch = store.stepTreeBuilds
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.stepTreeBuilds <= afterTouch + 1)
        let settled = store.stepTreeBuilds
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.stepTreeBuilds == settled)

        // Edited steps are a miss: the tree is built once more (dropping the stale
        // tick), then cached again.
        var edited = touched
        edited.payload.instructable?.steps[0] = Step(action: "Step 1, reworded")
        edited.updated = stamp(minutesAgo: 1)
        await fake.setItems([edited])
        await store.refresh()
        let afterEdit = store.stepTreeBuilds
        #expect(afterEdit > settled)
        #expect(store.ticks(for: "a") == [])
        #expect(store.ticks(for: "a") == [])
        #expect(store.stepTreeBuilds <= afterEdit + 1)
        let reCached = store.stepTreeBuilds
        #expect(store.ticks(for: "a") == [])
        #expect(store.stepTreeBuilds == reCached)
    }

    @Test func editedStepsCountOnlyTheRemainingMatchingLeaves() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [a])
        await start(store, fake)
        for path in ["1", "2.1", "2.3", "3"] { store.toggleTick(path, in: "a") }
        #expect(store.ticks(for: "a") == ["1", "2.1", "2.3", "3"])

        // Re-posted: step 2 lost its third sub-step and step 3 was reworded.
        var edited = item("a", created: stamp(minutesAgo: 10), steps: 3, substeps: [1: 2])
        edited.payload.instructable?.steps[2] = Step(action: "Step 3, reworded")
        edited.updated = stamp(minutesAgo: 1)
        await fake.setItems([edited])
        await store.refresh()

        let ticks = store.ticks(for: "a")
        #expect(ticks == ["1", "2.1"])
        #expect(QueueLayout.summary(for: edited, ticked: ticks) == .steps(done: 2, total: 4))
        #expect(Flow.progress(ticks: ticks, nodes: store.nodes(for: "a") ?? []) == StepProgress(done: 2, total: 4))
    }
}
