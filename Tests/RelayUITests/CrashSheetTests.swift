import Foundation
@testable import RelayCore
import Testing
@testable import RelayUI

private let log = ["2026-10-15T22:13:58Z launch hook=0.12.0 macos=15.6.0 cpu=arm64",
                   "2026-10-15T22:14:07Z error type=http status=401 route=asks/{id}/reply message=\"refused\""]

/// A Store on the fake Pond, with a crash on the bar and the injected log and targets.
@MainActor private func crashStore(_ defaults: TestDefaults, pond: PondVersion? = .semver(SemVer(major: 1, minor: 2, patch: 0)),
                                   target: CrashTarget = .pond, offered: Bool = true,
                                   summary: CrashSummary = crashWithReport) async -> (Store, FakeQueueSource) {
    let store = Store(defaults: defaults.defaults)
    let source = FakeQueueSource(items: [])
    await start(store, source, identity: mailboxIdentity)
    store.setPond(pond)
    store.crashLog = { log }
    store.crashTargets = { (target, offered) }
    store.offerCrash(summary)
    return (store, source)
}

@Suite @MainActor struct CrashSheetTests {
    @Test func reviewShowsExactlyWhatIsSent() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults)
        store.reviewCrash()
        let sheet = store.crashSheet
        #expect(sheet?.summary == crashWithReport)
        #expect(sheet?.target == .pond)
        #expect(sheet?.targets == [.pond, .github])
        #expect(sheet?.preview == CrashReportText.body(crashWithReport, source: "Pond", pond: "1.2.0", log: log))
        #expect(sheet?.primaryTitle == "Send to Pond")
    }

    /// A saved `pond` without an approved key reads as GitHub, and My Pond can't be picked.
    @Test func theTargetFallsBackToGitHubWithoutAKey() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults, target: .pond, offered: false)
        store.reviewCrash()
        #expect(store.crashSheet?.target == .github)
        #expect(store.crashSheet?.targets == [.github])
        store.setCrashTarget(.pond)
        #expect(store.crashSheet?.target == .github)
        #expect(store.crashSheet?.primaryTitle == "Open Issue on GitHub…")
    }

    @Test func copyCopiesExactlyThePreview() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults)
        let copied = SentValues<String>()
        store.shell.copy = { copied.items.append($0) }
        store.reviewCrash()
        store.copyCrashReport()
        #expect(copied.items == [store.crashSheet?.preview ?? "-"])
    }

    @Test func sendingToAPondFilesABugAndClosesTheSheet() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        var handled: [String] = []
        store.onCrashHandled = { handled.append($0) }
        await source.setBugAnswer(.occurrence(id: "bug-1", count: 3))
        store.reviewCrash()
        let preview = store.crashSheet?.preview ?? ""
        await store.sendCrashReport()

        let bugs = await source.bugs
        #expect(bugs.count == 1)
        #expect(bugs.first?.project == "Hook")
        #expect(bugs.first?.signature == crashWithReport.signature)
        #expect(bugs.first?.instructable == BugAsk.instructable(crashWithReport, body: preview))
        #expect(await source.count("post") == 1)   // the postBug call, and no plain post
        #expect(store.crashSheet == nil)
        #expect(store.crashOffer == nil)
        #expect(handled == [crashWithReport.signature])
        #expect(store.notice == .crashReport(message: "Added to the existing report (3 times)."))
    }

    /// Below Pond 1.2.0 the same ask goes out as a plain post (the 24-hour title dedupe applies).
    @Test func anOlderPondGetsAPlainAsk() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults, pond: .semver(SemVer(major: 1, minor: 1, patch: 0)))
        await source.setPostAnswer(PostResult(item: item("p1", project: "Hook", created: stamp(minutesAgo: 1)),
                                              deduped: false, openURL: nil))
        store.reviewCrash()
        let preview = store.crashSheet?.preview ?? ""
        await store.sendCrashReport()
        let posted = await source.posted
        #expect(posted.map(\.project) == ["Hook"])
        #expect(posted.first?.instructable == BugAsk.instructable(crashWithReport, body: preview))
        #expect(await source.bugs.isEmpty)
        #expect(store.notice == .crashReport(message: "Sent to your Pond."))
    }

    @Test func aRefusedOwnerKeyShowsItsNoticeAndKeepsTheBar() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        await source.failNext(QueueError.ownerKeyRefused, on: "postBug")
        store.reviewCrash()
        await store.sendCrashReport()
        #expect(store.notice == .ownerKeyRefused)
        #expect(store.crashSheet == nil)
        #expect(store.crashOffer != nil)
    }

    @Test func anotherFailureStaysInTheSheet() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        await source.failNext(QueueError.unreachable("The Pond didn't answer within 10 seconds."), on: "postBug")
        store.reviewCrash()
        await store.sendCrashReport()
        #expect(store.crashSheet?.send == .failed("The Pond didn't answer within 10 seconds."))
        #expect(store.crashOffer != nil)
    }

    @Test func cancelKeepsTheBar() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults)
        store.reviewCrash()
        store.closeCrashSheet()
        #expect(store.crashSheet == nil)
        #expect(store.crashOffer != nil)
    }

    /// Send Automatically to My Pond: no sheet, no bar on success.
    @Test func sendingAutomaticallyNeedsNoSheet() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        store.dismissCrash()
        await store.sendCrashAutomatically(crashWithoutReport)
        #expect(await source.bugs.map(\.signature) == [crashWithoutReport.signature])
        #expect(store.crashOffer == nil)
        #expect(store.crashSheet == nil)
    }

    /// A failed automatic send falls back to the bar.
    @Test func aFailedAutomaticSendOffersTheBar() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        store.dismissCrash()
        await source.failNext(QueueError.unreachable("offline"), on: "postBug")
        await store.sendCrashAutomatically(crashWithoutReport)
        #expect(store.crashOffer == CrashOffer(summary: crashWithoutReport))
    }

    @Test func sheetText() {
        let sheet = CrashSheetModel(summary: crashWithReport, target: .pond, pondOffered: true,
                                    preview: String(repeating: "x", count: 1412))
        #expect(sheet.countText == "Redacted · 1,412 characters")
        #expect(CrashSheetModel.targetName(.pond) == "My Pond")
        #expect(CrashSheetModel.targetName(.github) == "GitHub")
    }
}
