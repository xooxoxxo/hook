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

    @Test func anotherFailureStaysInTheWindow() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        await source.failNext(QueueError.unreachable("The Pond didn't answer within 10 seconds."), on: "postBug")
        store.reviewCrash()
        await store.sendCrashReport()
        #expect(store.crashSheet?.send == .failed("The Pond didn't answer within 10 seconds."))
        #expect(store.crashOffer != nil)
    }

    /// Review… opens the window; a second Review… while it is open only brings it forward,
    /// so the target picked and a shown failure stay.
    @Test func reviewOpensTheWindowAndAgainOnlyBringsItForward() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, source) = await crashStore(defaults)
        let shown = SentValues<Bool>()
        store.shell.showCrashReport = { shown.items.append(true) }
        store.reviewCrash()
        #expect(shown.items.count == 1)
        await source.failNext(QueueError.unreachable("The Pond didn't answer within 10 seconds."), on: "postBug")
        await store.sendCrashReport()
        store.reviewCrash()
        #expect(shown.items.count == 2)
        #expect(store.crashSheet?.send == .failed("The Pond didn't answer within 10 seconds."))
        store.setCrashTarget(.github)
        store.reviewCrash()
        #expect(store.crashSheet?.target == .github)
    }

    /// The window closes once whenever the report ends: Cancel, Not Now, or a send.
    @Test func theWindowClosesWhenTheReportEnds() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults)
        let closed = SentValues<Bool>()
        store.shell.closeCrashReport = { closed.items.append(true) }
        store.reviewCrash()
        store.setCrashTarget(.github)
        #expect(closed.items.isEmpty)
        store.closeCrashSheet()
        store.closeCrashSheet()
        #expect(closed.items.count == 1)
        store.reviewCrash()
        store.dismissCrash()
        #expect(closed.items.count == 2)
        store.offerCrash(crashWithReport)
        store.reviewCrash()
        await store.sendCrashReport()
        #expect(store.notice == .crashReport(message: "Sent to your Pond."))
        #expect(closed.items.count == 3)
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

/// Records what the GitHub path opened and copied.
@MainActor private final class GitHubShell {
    var opened: [URL] = []
    var copied: [String] = []
    var updates = 0
    var searched: [String] = []
}

@MainActor private func gitHubStore(_ defaults: TestDefaults, match: IssueMatch,
                                    summary: CrashSummary = crashWithReport) async -> (Store, GitHubShell) {
    let (store, _) = await crashStore(defaults, target: .github, offered: false, summary: summary)
    let shell = GitHubShell()
    store.shell.openURL = { shell.opened.append($0) }
    store.shell.copy = { shell.copied.append($0) }
    store.shell.checkForUpdates = { shell.updates += 1 }
    let searched = SentValues<String>()
    store.issueSearch = { signature, _ in
        await MainActor.run { searched.items.append(signature) }
        return match
    }
    store.reviewCrash()
    _ = await eventually { store.crashSheet?.match != nil }
    shell.searched = searched.items
    return (store, shell)
}

@Suite @MainActor struct CrashGitHubTests {
    private let issue42 = URL(string: "https://github.com/xooxoxxo/hook/issues/42")!

    /// Only the signature goes to the search, and the button waits for its answer.
    @Test func theSheetSearchesBySignatureOnly() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .none)
        #expect(shell.searched == [crashWithReport.signature])
        #expect(store.crashSheet?.match == IssueMatch.none)
        #expect(store.crashSheet?.primaryTitle == "Open Issue on GitHub…")
        #expect(CrashSheetModel(summary: crashWithReport, target: .github, pondOffered: false, preview: "x").checking)
    }

    @Test func noMatchOpensANewPrefilledIssue() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .none)
        let expected = store.crashSheet?.newIssue.url
        await store.sendCrashReport()
        #expect(shell.opened == [expected].compactMap { $0 })
        #expect(shell.copied.isEmpty)
        #expect(store.crashSheet == nil)
        #expect(store.crashOffer == nil)
        #expect(store.notice == .crashReport(message: "Opened a new issue on GitHub. Review it and submit it there."))
    }

    @Test func anOpenMatchOpensItAndCopiesTheComment() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .open(number: 42, title: "Hook crash: X", url: issue42))
        #expect(store.crashSheet?.primaryTitle == "Add to #42…")
        let preview = store.crashSheet?.preview ?? ""
        await store.sendCrashReport()
        #expect(shell.opened == [issue42])
        #expect(shell.copied == [GitHubIssues.comment(preview)])
        #expect(store.notice == .crashReport(message: "Comment copied. Paste it on the issue."))
    }

    @Test func aFixedMatchOffersTheUpdate() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults,
                                               match: .closedFixed(number: 42, version: SemVer(major: 0, minor: 12, patch: 1)))
        #expect(store.crashSheet?.primaryTitle == "Update Hook")
        #expect(store.crashSheet?.matchText == "Fixed in 0.12.1. Update Hook.")
        await store.sendCrashReport()
        #expect(shell.updates == 1)
        #expect(shell.opened.isEmpty)
        #expect(store.crashOffer == nil)
    }

    @Test func aClosedOtherMatchSaysPossiblyTheSame() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .closedOther(number: 38))
        await store.sendCrashReport()
        let url = try #require(shell.opened.first)
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        #expect(body?.hasPrefix("Possibly the same as #38\n\n") == true)
    }

    /// Rate-limited or offline: two buttons, and checking by hand keeps the sheet.
    @Test func unavailableOffersBothButtons() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .unavailable)
        #expect(store.crashSheet?.secondaryTitle == "Check for an Existing Issue")
        #expect(store.crashSheet?.primaryTitle == "Open New Issue")
        store.checkExistingCrashIssue()
        #expect(shell.opened == [GitHubIssues.searchPageURL(signature: crashWithReport.signature)])
        #expect(store.crashSheet != nil)
        await store.sendCrashReport()
        #expect(shell.opened.count == 2)
        #expect(store.crashSheet == nil)
    }

    /// A report too long for the link: the full report goes to the clipboard, and the sheet says so.
    @Test func aTrimmedLinkCopiesTheFullReport() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, shell) = await gitHubStore(defaults, match: .none)
        store.crashSheet?.preview += "\n" + String(repeating: "2026-10-15T22:00:00Z action open\n", count: 400)
        #expect(store.crashSheet?.trimNote != nil)
        let body = store.crashSheet?.newIssue.body
        await store.sendCrashReport()
        #expect(shell.copied == [body].compactMap { $0 })
        #expect(store.notice == .crashReport(
            message: "Opened a new issue on GitHub. The full report is on the clipboard: paste it over the shortened one."))
    }

    /// Switching to GitHub in the sheet starts the search.
    @Test func pickingGitHubSearches() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await crashStore(defaults)
        store.issueSearch = { _, _ in .none }
        store.reviewCrash()
        #expect(store.crashSheet?.match == nil)
        store.setCrashTarget(.github)
        #expect(await eventually { store.crashSheet?.match == IssueMatch.none })
    }
}
