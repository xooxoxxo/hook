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


/// Two clients use the same append-only progress service. Delayed replies capture
/// their snapshot when the GET starts, reproducing network arrival order.
private actor SharedTickSource: QueueSource {
    private var detail: AskDetail
    private var failGets = false
    private var holdGet = false
    private var heldGets: [(AskDetail, CheckedContinuation<AskDetail, Never>)] = []
    private var holdSend = false
    private var heldSends: [CheckedContinuation<Void, Never>] = []
    private(set) var progressCount = 0
    private(set) var listCount = 0
    var waitingGets: Int { heldGets.count }
    var waitingSends: Int { heldSends.count }
    init(_ detail: AskDetail) { self.detail = detail }
    func replace(_ detail: AskDetail) { self.detail = detail }
    func failReads(_ on: Bool) { failGets = on }
    func holdNextGet() { holdGet = true }
    func holdProgress() { holdSend = true }
    func releaseGets() {
        let held = heldGets; heldGets = []
        for (snapshot, continuation) in held { continuation.resume(returning: snapshot) }
    }
    func releaseProgress() {
        holdSend = false
        let held = heldSends; heldSends = []
        held.forEach { $0.resume() }
    }
    func list() async throws -> [WireItem] { listCount += 1; return [detail.item] }
    func get(_ id: String) async throws -> AskDetail {
        if failGets { throw QueueError.unreachable("offline") }
        if holdGet {
            holdGet = false
            return await withCheckedContinuation { heldGets.append((detail, $0)) }
        }
        return detail
    }
    func progress(_ id: String, tick: [String], untick: [String], stamp: RevisionStamp?) async throws -> WireItem {
        progressCount += 1
        if holdSend { await withCheckedContinuation { heldSends.append($0) } }
        let text = String(decoding: try JSONEncoder().encode(["tick": tick, "untick": untick]), as: UTF8.self)
        detail.events.append(Event(seq: (detail.events.map(\.seq).max() ?? 0) + 1, itemId: id,
                                   kind: "progress", actor: "owner", text: text, at: "", rev: stamp?.rev))
        return detail.item
    }
    func post(project: String, instructable: Data) async throws -> PostResult { throw QueueError.notSupported }
    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem { throw QueueError.notSupported }
    func reply(_ id: String, text: String) async throws -> WireItem { throw QueueError.notSupported }
    func answer(_ id: String, answers: [JSONValue]) async throws -> WireItem { throw QueueError.notSupported }
    func reopen(_ id: String) async throws -> WireItem { throw QueueError.notSupported }
    func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] { [] }
    func changes() async -> AsyncStream<Void>? { nil }
}

private let sharedPond = PondVersion.semver(SemVer(major: 1, minor: 5, patch: 0))
private let sharedIdentity = SourceIdentity(key: "mailbox:pond.example.test#test", mailbox: nil)

@Suite @MainActor struct SharedStoreTicksTests {
    private func plain() -> AskDetail {
        var value = item("a", created: stamp(minutesAgo: 10), steps: 2)
        value.payload.instructable?.steps[0].id = "s1"
        value.payload.instructable?.steps[1].id = "s2"
        return AskDetail(item: value, events: [])
    }
    private func started(_ defaults: TestDefaults, _ source: SharedTickSource, version: PondVersion? = sharedPond) async -> Store {
        let store = Store(defaults: defaults.defaults, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        store.swap(to: source, identity: sharedIdentity, pollSeconds: 3600)
        #expect(await eventually { await source.listCount > 0 })
        await store.refresh()
        store.setPond(version)
        return store
    }
    /// A valid raw revision carrying an own field this client's Step cannot decode.
    private func futureFieldCorrection(_ first: AskDetail, events: [Event] = []) throws -> AskDetail {
        let previous = first.revisions.last!
        var object = try #require(try JSONSerialization.jsonObject(with: Data(previous.body.utf8)) as? [String: Any])
        var steps = try #require(object["steps"] as? [[String: Any]])
        steps[0]["futureField"] = "new content"
        object["steps"] = steps
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let hash = RevisionHash.make(rev: previous.rev + 1, prev: previous.hash, at: previous.at, reason: "Clarify step", body: raw)
        let revision = Revision(rev: previous.rev + 1, hash: hash, prev: previous.hash,
                                at: previous.at, reason: "Clarify step", body: raw)
        var next = first
        next.revisions.append(revision)
        next.item.revision = ServedRevision(rev: revision.rev, hash: hash, prev: previous.hash,
                                           at: revision.at, reason: revision.reason, body: raw, acceptedRev: revision.rev)
        next.events = events
        return next
    }

    @Test func orphanRevisionEnvelopeCannotAdoptOrDiscardLegacyTicks() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        var orphan = revised("a", [idSteps(2)]).detail
        orphan.item.revision = nil
        orphan.revisions[0].body += " "
        orphan.events = [Event(seq: 1, itemId: "a", kind: "progress", actor: "owner",
                               text: #"{"tick":["s1"]}"#, at: "", rev: 1)]
        TickStore.save(defaults.defaults, sourceKey: sharedIdentity.key, id: "a", ticks: ["1"],
                       nodes: DetailModel.nodes(steps: orphan.item.instructable!.steps, verify: nil))
        let source = SharedTickSource(orphan)
        let store = await started(defaults, source)
        #expect(store.sharedProgressDetails.isEmpty)
        #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: "a")) != nil)
        #expect(store.ticks(for: "a") == [])
        #expect(await source.progressCount == 0)
    }

    @Test func unknownOwnFieldCorrectionInvalidatesLocalDeltaBeforeRebinding() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let first = revised("a", [idSteps(2)]).detail
        let source = SharedTickSource(first)
        let store = await started(defaults, source)
        store.toggleTick("1", in: "a")
        #expect(store.progressOutbox["a"]?.tick == ["s1"])
        let corrected = try futureFieldCorrection(first)
        await source.replace(corrected); await store.reload("a")
        markAccepted(store, "a", corrected.item.revision!.stamp)
        #expect(store.ticks(for: "a") == [])
        #expect(await store.flushProgress("a"))
        #expect(await source.progressCount == 0)
        #expect(try SharedProgress.fold(detail: await source.get("a")) == [])
    }

    @Test func authoritativeTickIsNotProjectedOntoDifferentRawRenderedOwnFields() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let first = revised("a", [idSteps(2)]).detail
        let source = SharedTickSource(first)
        let store = await started(defaults, source)
        let event = Event(seq: 1, itemId: "a", kind: "progress", actor: "owner", text: #"{"tick":["s1"]}"#, at: "", rev: 2)
        let corrected = try futureFieldCorrection(first, events: [event])
        await source.replace(corrected); await store.reload("a")
        #expect(store.renderedStamp("a") == first.item.revision!.stamp)
        #expect(store.ticks(for: "a") == [])
        markAccepted(store, "a", corrected.item.revision!.stamp)
        #expect(store.ticks(for: "a") == ["1"])
    }

    @Test func unknownVersionRejectsLateTickSnapshotBeforeSharedAdoption() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source, version: nil)
        _ = try await source.progress("a", tick: ["s1"], untick: [], stamp: nil)
        await source.holdNextGet()
        let late = Task { await store.reload("a") }
        #expect(await eventually { await source.waitingGets == 1 })
        _ = try await source.progress("a", tick: [], untick: ["s1"], stamp: nil)
        await store.reload("a")
        await source.releaseGets(); await late.value
        store.setPond(sharedPond)
        #expect(store.ticks(for: "a") == [])
        #expect(store.sharedProgressDetails["a"]?.events.count == 2)
        #expect(await source.progressCount == 2)
    }

    @Test func legacyRawOwnFieldChangesAlsoInvalidateCurrentLocalDelta() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        func legacy(_ value: String) throws -> AskDetail {
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain())) as? [String: Any])
            var item = try #require(object["item"] as? [String: Any])
            var payload = try #require(item["payload"] as? [String: Any])
            var ins = try #require(payload["instructable"] as? [String: Any])
            var steps = try #require(ins["steps"] as? [[String: Any]])
            steps[0]["futureField"] = value
            ins["steps"] = steps; payload["instructable"] = ins; item["payload"] = payload; object["item"] = item
            return try JSONDecoder().decode(AskDetail.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let source = SharedTickSource(try legacy("first"))
        let store = await started(defaults, source)
        store.toggleTick("1", in: "a")
        await source.replace(try legacy("second")); await store.reload("a")
        #expect(store.ticks(for: "a") == [])
        #expect(await store.flushProgress("a"))
        #expect(await source.progressCount == 0)
    }

    @Test func macTickAppearsOnPhoneAndPhoneUntickRemovesItWithoutEcho() async throws {
        let macDefaults = TestDefaults(), phoneDefaults = TestDefaults()
        defer { macDefaults.drop(); phoneDefaults.drop() }
        let source = SharedTickSource(plain())
        let mac = await started(macDefaults, source), phone = await started(phoneDefaults, source)
        #expect(mac.navigation.selectedID == nil && phone.navigation.selectedID == nil)
        #expect(mac.ticks(for: "a").isEmpty && phone.ticks(for: "a").isEmpty)
        mac.toggleTick("1", in: "a")
        #expect(mac.ticks(for: "a") == ["1"])
        #expect(await mac.flushProgress("a"))
        // updated is unchanged; the unselected queue still reads new progress.
        await phone.refresh()
        #expect(phone.ticks(for: "a") == ["1"])
        #expect(await source.progressCount == 1)
        phone.toggleTick("1", in: "a")
        #expect(await phone.flushProgress("a"))
        await mac.refresh()
        #expect(mac.ticks(for: "a") == [])
        await mac.refresh(); await phone.refresh()
        #expect(await source.progressCount == 2)
        #expect(mac.progressOutbox.isEmpty && phone.progressOutbox.isEmpty)
    }
    @Test func staleDetailArrivalCannotResurrectRemoteUntick() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source)
        _ = try await source.progress("a", tick: ["s1"], untick: [], stamp: nil)
        await source.holdNextGet()
        let late = Task { await store.reload("a") }
        #expect(await eventually { await source.waitingGets == 1 })
        _ = try await source.progress("a", tick: [], untick: ["s1"], stamp: nil)
        await store.reload("a")
        #expect(store.ticks(for: "a") == [])
        await source.releaseGets(); await late.value
        #expect(store.ticks(for: "a") == [])
        #expect(store.details["a"]?.events.count == 2)
    }
    @Test func inflightDeltaOverlaysRemoteSnapshotUntilPostResponseFetch() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source)
        await source.holdProgress()
        store.toggleTick("1", in: "a")
        let send = Task { await store.flushProgress("a") }
        #expect(await eventually { await source.waitingSends == 1 })
        await store.reload("a") // server has not received the tick yet
        #expect(store.ticks(for: "a") == ["1"])
        await source.releaseProgress()
        #expect(await send.value)
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.progressOverlays["a"]?.isEmpty == true)
    }
    @Test func aGetStartedBeforeSendSuccessCannotAcknowledgeTheSend() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source)
        await source.holdNextGet()
        let before = Task { await store.reload("a") }
        #expect(await eventually { await source.waitingGets == 1 })
        await source.failReads(true)
        store.toggleTick("1", in: "a")
        #expect(await store.flushProgress("a")) // POST lands; its GET fails
        #expect(store.ticks(for: "a") == ["1"])
        await source.releaseGets(); await before.value
        #expect(store.ticks(for: "a") == ["1"])
        #expect(store.progressOverlays["a"]?.count == 1)
        await source.failReads(false)
        await store.reload("a")
        #expect(store.progressOverlays["a"]?.isEmpty == true)
    }
    @Test func firstAuthoritativeFetchDiscardsUpgradeTicksAcrossSourceAndNeverImportsThem() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let detail = plain(), source = SharedTickSource(plain())
        let nodes = DetailModel.nodes(steps: detail.item.instructable!.steps, verify: nil)
        for id in ["a", "older-ask"] {
            TickStore.save(defaults.defaults, sourceKey: sharedIdentity.key, id: id, ticks: ["1"], nodes: nodes)
        }
        await source.failReads(true)
        let store = await started(defaults, source)
        #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: "a")) != nil)
        await source.failReads(false)
        await store.reload("a")
        for id in ["a", "older-ask"] {
            #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: id)) == nil)
        }
        #expect(store.ticks(for: "a") == [])
        #expect(await source.progressCount == 0)
        // A stale device returning online also ignores its own pre-upgrade cache.
        let stale = TestDefaults(); defer { stale.drop() }
        TickStore.save(stale.defaults, sourceKey: sharedIdentity.key, id: "a", ticks: ["1"], nodes: nodes)
        let returning = await started(stale, source)
        #expect(returning.ticks(for: "a") == [])
        #expect(await source.progressCount == 0)
    }
    @Test func upgradeDoesNotQueueLegacyRequiredTicksBeforeVersionIsKnown() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        var detail = plain()
        detail.item.payload.instructable?.steps[0].required = true
        detail.item.requirements = PondRequirements(left: [PondRequirement(kind: "step", id: "s1", path: "1")], ready: false)
        TickStore.save(defaults.defaults, sourceKey: sharedIdentity.key, id: "a", ticks: ["1"],
                       nodes: DetailModel.nodes(steps: detail.item.instructable!.steps, verify: nil))
        let source = SharedTickSource(detail)
        let store = await started(defaults, source, version: nil)
        #expect(store.progressOutbox.isEmpty)
        store.setPond(sharedPond)
        #expect(await store.flushProgress("a"))
        #expect(store.ticks(for: "a") == [])
        #expect(await source.progressCount == 0)
    }

    @Test func userDeltaMadeBeforeVersionDiscoverySurvivesSharedAdoption() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source, version: nil)
        store.toggleTick("1", in: "a")
        #expect(store.progressOutbox["a"]?.tick == ["s1"])
        store.setPond(sharedPond)
        #expect(store.ticks(for: "a") == ["1"])
        #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: "a")) == nil)
        #expect(await store.flushProgress("a"))
        #expect(store.ticks(for: "a") == ["1"])
        #expect(await source.progressCount == 1)
    }

    @Test func knownOlderPondStillCatchesUpLegacyRequiredTicks() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        var detail = plain()
        detail.item.payload.instructable?.steps[0].required = true
        detail.item.requirements = PondRequirements(left: [PondRequirement(kind: "step", id: "s1", path: "1")], ready: false)
        TickStore.save(defaults.defaults, sourceKey: sharedIdentity.key, id: "a", ticks: ["1"],
                       nodes: DetailModel.nodes(steps: detail.item.instructable!.steps, verify: nil))
        let source = SharedTickSource(detail)
        let store = await started(defaults, source, version: nil)
        #expect(store.progressOutbox.isEmpty)
        store.setPond(.semver(SemVer(major: 1, minor: 4, patch: 0)))
        #expect(store.progressOutbox["a"]?.tick == ["s1"])
        #expect(await store.flushProgress("a"))
        #expect(store.ticks(for: "a") == ["1"])
        #expect(await source.progressCount == 1)
    }

    @Test func invalidRevisionFetchCannotDiscardLegacyTicksOrFallBackToPayload() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let valid = revised("a", [idSteps(2)]).detail
        var broken = valid
        broken.revisions[0].body += " "
        TickStore.save(defaults.defaults, sourceKey: sharedIdentity.key, id: "a", ticks: ["1"],
                       nodes: DetailModel.nodes(steps: valid.item.instructable!.steps, verify: nil))
        let source = SharedTickSource(broken)
        let store = await started(defaults, source)
        #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: "a")) != nil)
        #expect(store.sharedProgressDetails.isEmpty)
        await source.replace(valid); await store.reload("a")
        #expect(defaults.defaults.object(forKey: TickStore.keyV3(sourceKey: sharedIdentity.key, id: "a")) == nil)
        #expect(store.ticks(for: "a") == [])
        #expect(await source.progressCount == 0)
    }

    @Test func sourceSwapDropsPendingAndInflightProgressAndLateResponses() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source)
        await source.holdProgress()
        store.toggleTick("1", in: "a")
        let send = Task { await store.flushProgress("a") }
        #expect(await eventually { await source.waitingSends == 1 })
        store.toggleTick("2", in: "a")
        let next = SharedTickSource(plain())
        store.swap(to: next, identity: SourceIdentity(key: "mailbox:other.example.test#test", mailbox: nil), pollSeconds: 3600)
        store.setPond(sharedPond)
        await store.refresh()
        await source.releaseProgress()
        #expect(await send.value == false)
        #expect(store.ticks(for: "a") == [])
        #expect(store.progressOutbox.isEmpty && store.progressOverlays.isEmpty && store.progressSends.isEmpty)
        #expect(await next.progressCount == 0)
    }
    @Test func requiredOnlyCorrectionKeepsTicksChangedCommandClearsAndOldRevisionArrivalIsIgnored() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let body = idSteps(2)
        let event = Event(seq: 1, itemId: "a", kind: "progress", actor: "owner", text: #"{"tick":["s1"],"untick":[]}"#, at: "", rev: 1)
        let first = revised("a", [body], events: [event])
        let source = SharedTickSource(first.detail)
        let store = await started(defaults, source)
        #expect(store.ticks(for: "a") == ["1"])
        var required = body; required.steps[0].required = true
        let second = revised("a", [body, required], acceptedRev: 2, events: [event])
        await source.replace(second.detail); await store.reload("a")
        markAccepted(store, "a", second.item.revision!.stamp)
        #expect(store.ticks(for: "a") == ["1"])
        var changed = required; changed.steps[0].code = "run revised"
        let third = revised("a", [body, required, changed], acceptedRev: 3, events: [event])
        await source.replace(third.detail); await store.reload("a")
        markAccepted(store, "a", third.item.revision!.stamp)
        #expect(store.ticks(for: "a") == [])
        await source.replace(first.detail); await store.reload("a")
        #expect(store.ticks(for: "a") == [])
        #expect(store.sharedProgressDetails["a"]?.item.revision?.rev == 3)
    }
    @Test func remoteTickDuringDebounceDoesNotCancelTheOwnersLaterUntick() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let source = SharedTickSource(plain())
        let store = await started(defaults, source)
        store.toggleTick("1", in: "a")
        _ = try await source.progress("a", tick: ["s1"], untick: [], stamp: nil)
        await store.reload("a")
        store.toggleTick("1", in: "a")
        #expect(store.progressOutbox["a"]?.untick == ["s1"])
        #expect(await store.flushProgress("a"))
        #expect(store.ticks(for: "a") == [])
        #expect(try SharedProgress.fold(detail: await source.get("a")) == [])
    }

    @Test func correctionInvalidatesAnUnsentTickRatherThanRebindingItToChangedCommand() async throws {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let body = idSteps(2), first = revised("a", [idSteps(2)])
        let source = SharedTickSource(first.detail)
        let store = await started(defaults, source)
        store.toggleTick("1", in: "a")
        var changed = body; changed.steps[0].code = "run revised"
        let second = revised("a", [body, changed], acceptedRev: 2)
        await source.replace(second.detail); await store.reload("a")
        markAccepted(store, "a", second.item.revision!.stamp)
        #expect(store.ticks(for: "a") == [])
        #expect(await store.flushProgress("a"))
        #expect(await source.progressCount == 0)
    }
}
