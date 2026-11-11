import Foundation
import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct PhoneDeliveryPolicyTests {
    private func phone(_ defaults: TestDefaults, secrets: MemorySecretStore = MemorySecretStore()) async -> Store {
        let store = Store(defaults: defaults.defaults, reviews: ReviewPersistence(secrets: secrets, url: reviewsURL()), deliveryPolicy: .phone)
        await store.reviewsLoaded()
        return store
    }

    @Test func ambiguousAcceptanceKeepsReviewLockAndDraftsAndNeverReplaysOnRefresh() async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let store = await phone(defaults), recorder = ShellRecorder()
        store.shell = recorder.shell
        let corrected = revised("a", [idSteps(1), idSteps(1, codes: [1: "changed command"])], acceptedRev: 1)
        let source = FakeQueueSource(items: [corrected.item], details: ["a": corrected.detail])
        await start(store, source, identity: mailboxIdentity)
        store.drafts["a"] = "Unsent reply"
        store.choiceWords["a"] = ["1": "Unsent answer"]
        await source.failNext(URLError(.timedOut), on: "accept")
        #expect(await store.acceptRevision("a", stamp: corrected.detail.revisions[1].stamp) == false)
        #expect(store.isContentLocked("a"))
        #expect(store.drafts["a"] == "Unsent reply")
        #expect(store.choiceWords["a"]?["1"] == "Unsent answer")
        #expect(store.record("a")?.pondAcceptPending != true)
        #expect(store.notice?.actionTitle == nil)
        await store.refresh()
        #expect(await source.count("accept") == 1)
        // A new explicit action can complete once transport has reconciled and permitted it.
        #expect(await store.acceptRevision("a", stamp: corrected.detail.revisions[1].stamp))
        #expect(!store.isContentLocked("a"))
        #expect(store.record("a")?.pondAcceptPending == false)
        #expect(await source.count("accept") == 2)
    }

    @Test func failedProgressIsNeverReplayedByRefreshOrDoneCatchup() async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let store = await phone(defaults)
        var body = idSteps(1); body.steps[0].required = true
        let item = WireItem(id: "a", title: body.title, status: "open", created: stamp(minutesAgo: 1), updated: stamp(minutesAgo: 1), payload: Payload(instructable: body))
        let source = FakeQueueSource(items: [item])
        await start(store, source, identity: mailboxIdentity)
        store.setPond(.semver(SemVer(major: 1, minor: 3, patch: 0)))
        await source.failNext(URLError(.timedOut), on: "progress")
        store.toggleTick("1", in: "a")
        _ = await store.flushProgress("a")
        #expect(await source.count("progress") == 1)
        #expect(store.progressOutbox.isEmpty)
        await store.refresh()
        store.catchUpProgress("a")
        _ = await store.flushProgress("a")
        #expect(await source.count("progress") == 1)
    }

    @Test func lockedReviewSealBlocksCopyEvenForLegacyOfflineAsk() async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let secrets = MemorySecretStore(); secrets.readError = .unreadable(-25308)
        let store = await phone(defaults, secrets: secrets), recorder = ShellRecorder()
        store.shell = recorder.shell
        let body = idSteps(1)
        let item = WireItem(id: "a", title: body.title, status: "open", created: stamp(minutesAgo: 1), updated: stamp(minutesAgo: 1), payload: Payload(instructable: body))
        await start(store, FakeQueueSource(items: [item]), identity: mailboxIdentity)
        store.mutationsAvailable = false
        #expect(store.copyCode("a", stamp: nil, text: "run 1") == .refused)
        #expect(recorder.copied.isEmpty)
        store.toggleTick("1", in: "a")
        store.close("a", .declined)
        #expect(store.pending.isEmpty)
        #expect(store.ticks(for: "a").isEmpty)
    }

    @Test func aHeldCloseRechecksAvailabilityAtTimerDispatchAndNeverReplays() async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        var now = Date()
        let store = Store(defaults: defaults.defaults, now: { now },
            reviews: ReviewPersistence(secrets: MemorySecretStore(), url: reviewsURL()), deliveryPolicy: .phone)
        await store.reviewsLoaded()
        let item = WireItem(id: "a", title: "Synthetic", status: "open", created: stamp(minutesAgo: 1), updated: stamp(minutesAgo: 1), payload: Payload())
        let source = FakeQueueSource(items: [item])
        await start(store, source, identity: mailboxIdentity)
        store.close("a", .declined)
        store.mutationsAvailable = false
        now = now.addingTimeInterval(11)
        store.sendDue()
        #expect(await eventually { store.heldCloseIDs.isEmpty })
        #expect(await source.count("resolve") == 0)
        #expect(store.notice?.actionTitle == nil)
        #expect(store.notice != nil)
        store.mutationsAvailable = true
        await store.refresh()
        store.sendDue()
        #expect(await source.count("resolve") == 0)
    }

    @Test(arguments: [false, true]) func backgroundDeliveryNeedsCurrentExplicitAuthorization(_ permitted: Bool) async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let store = await phone(defaults)
        let item = WireItem(id: "a", title: "Synthetic", status: "open", created: stamp(minutesAgo: 1), updated: stamp(minutesAgo: 1), payload: Payload())
        let source = FakeQueueSource(items: [item])
        await start(store, source, identity: mailboxIdentity)
        store.close("a", .declined)
        store.mutationsAvailable = false
        await store.sendAllPending(reason: .background, allowedWhileSuspended: { permitted })
        #expect(await source.count("resolve") == (permitted ? 1 : 0))
        #expect(!store.hasPendingCloses)
        store.mutationsAvailable = true
        await store.sendAllPending(reason: .background)
        #expect(await source.count("resolve") == (permitted ? 1 : 0))
    }

    @Test func shutdownDoesNotFlushPhoneButExplicitBackgroundFlushIsOneShot() async {
        let defaults = TestDefaults(); defer { defaults.drop() }
        let store = await phone(defaults)
        let item = WireItem(id: "a", title: "Synthetic", status: "open", created: stamp(minutesAgo: 1), updated: stamp(minutesAgo: 1), payload: Payload())
        let source = FakeQueueSource(items: [item])
        await start(store, source, identity: mailboxIdentity)
        store.close("a", .declined)
        await store.sendAllPending()
        #expect(await source.count("resolve") == 0)
        #expect(!store.pending.isEmpty)
        await source.failNext(URLError(.timedOut), on: "resolve")
        await store.sendAllPending(reason: .background)
        await store.sendAllPending(reason: .background)
        #expect(await source.count("resolve") == 1)
        #expect(store.pending.isEmpty)
    }
}
