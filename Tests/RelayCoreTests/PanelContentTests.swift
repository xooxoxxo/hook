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
            let detailOnly = notice == .sessionClosed(id: "a")
            #expect(notice.showsOnQueue == !detailOnly, "\(notice)")
            #expect(notice.detailAskID == (detailOnly ? "a" : nil), "\(notice)")
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

/// A Done the Pond refused with 409 requirements_unmet (RD 28): no items named, Show opens the ask.
@Suite struct DoneRefusedNoticeTests {
    @Test func theNoticeNamesTheAskAndNoItems() {
        let notice = PanelNotice.doneRefused(id: "a", title: "Rotate the staging deploy key\u{202E}")
        #expect(notice.text == "“Rotate the staging deploy key⟨U+202E⟩” isn't finished yet: the Pond still waits for a "
            + "marked item. Finish it, or Skip.")
        #expect(notice.kind == .info)
        #expect(notice.actionTitle == "Show")
        #expect(notice.detailAskID == nil)
        #expect(notice.showsOnQueue)
        #expect(!notice.isTransient)
        #expect(!notice.text.contains("Required"))
    }
}

private func node(_ number: Int, id: String?) -> DetailModel.Node {
    DetailModel.Node(path: "\(number)", label: "\(number)", kind: .step, number: number,
                     content: StepContent(action: "Step \(number)"), fingerprint: "", stepID: id)
}

private func marker(rev: Int, at: String = "2026-11-14T14:02:00+00:00", note: String = "Two more checks",
                    first: String, index: Int, added: Int = 2, afterAnswer: Bool = false) -> AppendMarker {
    AppendMarker(rev: rev, at: at, note: note, firstStepID: first, addedTopLevel: added, afterAnswer: afterAnswer,
                 firstStepIndex: index)
}

private let utc = TimeZone(identifier: "UTC")!

/// The detail's step list with the divider above the steps a revision added (Task 17).
@Suite struct StepEntriesTests {
    private func shape(_ entries: [StepEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .node(let node): return "step \(node.number)"
            case .appendMarker(_, let title, let note): return "marker \(title) | \(note)"
            }
        }
    }

    @Test func markerBeforeFirstNewStep() {
        let nodes = [node(1, id: "a"), node(2, id: "b"), node(3, id: "c"), node(4, id: "d")]
        let entries = StepEntries.make(nodes, markers: [marker(rev: 2, first: "c", index: 2)], timeZone: utc)
        #expect(shape(entries) == ["step 1", "step 2", "marker Added by the session · 14:02 | Two more checks",
                                   "step 3", "step 4"])
        // The steps keep their running numbers.
        #expect(entries.compactMap { if case .node(let n) = $0 { return n.number } else { return nil } } == [1, 2, 3, 4])
    }

    @Test func markerTitleAfterAnswer() {
        #expect(StepEntries.title(marker(rev: 2, first: "c", index: 2, afterAnswer: true), timeZone: utc)
            == "Added after your answer · 14:02")
    }

    @Test func markerTitleBySession() {
        #expect(StepEntries.title(marker(rev: 2, first: "c", index: 2), timeZone: utc) == "Added by the session · 14:02")
        // HH:mm in the Mac's own time zone, never a 12-hour clock.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(StepEntries.title(marker(rev: 2, at: "2026-11-14T09:05:00+00:00", first: "c", index: 2), timeZone: tokyo)
            == "Added by the session · 18:05")
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(StepEntries.title(marker(rev: 2, at: "2026-11-14T19:30:00+00:00", first: "c", index: 2), timeZone: newYork)
            == "Added by the session · 14:30")
    }

    @Test func twoMarkers() {
        let nodes = (1...5).map { node($0, id: "s\($0)") }
        let first = marker(rev: 2, note: "One", first: "s3", index: 2, added: 2, afterAnswer: true)
        let second = marker(rev: 3, at: "2026-11-14T14:20:00+00:00", note: "Two", first: "s5", index: 4, added: 1)
        #expect(shape(StepEntries.make(nodes, markers: [first, second], timeZone: utc)) == [
            "step 1", "step 2", "marker Added after your answer · 14:02 | One", "step 3", "step 4",
            "marker Added by the session · 14:20 | Two", "step 5",
        ])
    }

    @Test func stepsWithoutIDsUseTheIndex() {
        let nodes = [node(1, id: nil), node(2, id: nil), node(3, id: nil)]
        #expect(shape(StepEntries.make(nodes, markers: [marker(rev: 2, first: "", index: 2, added: 1)], timeZone: utc))
            == ["step 1", "step 2", "marker Added by the session · 14:02 | Two more checks", "step 3"])
    }

    @Test func verifyStaysLastAndAMarkerPastTheStepsIsDropped() {
        let verify = DetailModel.Node(path: "verify", label: "Verify", kind: .verify, number: 3,
                                      content: StepContent(action: "Check"), fingerprint: "", stepID: "@verify")
        let nodes = [node(1, id: "a"), node(2, id: "b"), verify]
        #expect(shape(StepEntries.make(nodes, markers: [marker(rev: 2, first: "b", index: 1, added: 1)], timeZone: utc))
            == ["step 1", "marker Added by the session · 14:02 | Two more checks", "step 2", "step 3"])
        #expect(shape(StepEntries.make(nodes, markers: [marker(rev: 2, first: "z", index: 2, added: 1)], timeZone: utc))
            == ["step 1", "step 2", "step 3"])
    }

    @Test func theNoteIsOneLine() {
        let nodes = [node(1, id: "a"), node(2, id: "b")]
        let entries = StepEntries.make(nodes, markers: [marker(rev: 2, note: "A\nB", first: "b", index: 1, added: 1)],
                                       timeZone: utc)
        #expect(shape(entries)[1] == "marker Added by the session · 14:02 | A⟨U+000A⟩B")
    }
}
