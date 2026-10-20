import Foundation
import Testing
@testable import RelayCore

private func content(_ key: String = "mailbox:m#p", loadedOnce: Bool = true, reachable: Bool = true, problem: String? = nil,
                     waited: Bool = false, filter: String? = nil, open: Int = 0, closed: Int = 0) -> PanelContent {
    PanelContent.resolve(sourceKey: key, loadedOnce: loadedOnce, reachable: reachable, problem: problem,
                         waitedTenSeconds: waited, filter: filter, shownOpen: open, shownClosed: closed)
}

@Suite struct PanelContentTests {
    @Test func loading() {
        #expect(content(loadedOnce: false, reachable: false) == .loading(stillTrying: false))
        #expect(content(loadedOnce: false, reachable: false, waited: true) == .loading(stillTrying: true))
    }

    @Test func notSetUp() {
        #expect(content(SourceKey.none, loadedOnce: false, reachable: false, problem: "No queue is set up") == .notSetUp)
    }

    @Test func offlineWithoutACacheIsNeverNothingWaiting() {
        #expect(content(loadedOnce: false, reachable: false, problem: "timed\nout") == .offline(local: false, reason: "timed⟨U+000A⟩out"))
        #expect(content("local", loadedOnce: false, reachable: false, problem: "Port in use") == .offline(local: true, reason: "Port in use"))
    }

    @Test func offlineWithACacheKeepsTheList() {
        #expect(content(reachable: false, problem: "timed out", open: 3) == .list)
    }

    @Test func emptyOnlyWhenTheSourceAnswered() {
        #expect(content() == .empty)
        #expect(content(closed: 2) == .list)
        #expect(content(open: 1) == .list)
    }

    @Test func filteredEmptyIsNeverBare() {
        #expect(content(filter: "Atlas") == .emptyFiltered(project: "Atlas"))
        #expect(content(filter: "Atlas", closed: 1) == .list)
        #expect(content(filter: "Atlas", open: 2) == .list)
    }
}

@Suite struct PanelNoticeTests {
    @Test func texts() {
        #expect(PanelNotice.actionFailed(verdict: .done, id: "a", title: "Send the logo", reason: "timed out").text
            == "Couldn't send Done for “Send the logo”. timed out")
        #expect(PanelNotice.actionFailed(verdict: .declined, id: "a", title: "T\nX", reason: "a\u{202E}b").text
            == "Couldn't send Skip for “T⟨U+000A⟩X”. a⟨U+202E⟩b")
        #expect(PanelNotice.reopenFailed(id: "a", title: "Send the logo", reason: "timed out").text
            == "Couldn't reopen “Send the logo”. timed out")
        #expect(PanelNotice.storeFailed(reason: "The disk is full.").text == "Couldn't save the queue. The disk is full.")
        #expect(PanelNotice.queueMoved(path: "~/q.json.corrupt-1").text
            == "queue.json couldn't be read, so it was moved to ~/q.json.corrupt-1. A new queue has started.")
        #expect(PanelNotice.settingsReloaded.text == "Settings changed, so the queue reloaded.")
        #expect(PanelNotice.sessionClosed(id: "a").text == "The session closed this ask.")
        #expect(PanelNotice.noLongerOpen(id: "a", canShowClosed: false).text == "This ask is no longer open.")
        #expect(PanelNotice.offlineCached(since: "10:22").text == "Offline · showing asks from 10:22")
    }

    @Test func kindsAndActions() {
        let cases: [(PanelNotice, NoticeKind, String?)] = [
            (.actionFailed(verdict: .done, id: "a", title: "t", reason: "r"), .error, "Retry"),
            (.reopenFailed(id: "a", title: "t", reason: "r"), .error, "Retry"),
            (.storeFailed(reason: "r"), .error, nil),
            (.queueMoved(path: "p"), .error, "Show in Finder"),
            (.settingsReloaded, .info, nil),
            (.sessionClosed(id: "a"), .info, "Next Ask"),
            (.noLongerOpen(id: "a", canShowClosed: true), .info, "Show Closed Ask"),
            (.noLongerOpen(id: "a", canShowClosed: false), .info, nil),
            (.offlineCached(since: "10:22"), .info, "Try Again"),
        ]
        for (notice, kind, action) in cases {
            #expect(notice.kind == kind, "\(notice)")
            #expect(notice.actionTitle == action, "\(notice)")
        }
    }
}

@Suite struct DetailLoadStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func states() {
        #expect(DetailLoadState.resolve(hasModel: true, requestedAt: t0, now: t0.addingTimeInterval(60), failed: true, timeout: 10) == .loaded)
        #expect(DetailLoadState.resolve(hasModel: false, requestedAt: t0, now: t0.addingTimeInterval(9.9), failed: false, timeout: 10) == .loading)
        #expect(DetailLoadState.resolve(hasModel: false, requestedAt: t0, now: t0.addingTimeInterval(10), failed: false, timeout: 10) == .timedOut)
        #expect(DetailLoadState.resolve(hasModel: false, requestedAt: t0, now: t0, failed: true, timeout: 10) == .timedOut)
        #expect(DetailLoadState.resolve(hasModel: false, requestedAt: nil, now: t0, failed: false, timeout: 10) == .loading)
    }
}
