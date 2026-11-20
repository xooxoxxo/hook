import Foundation
import Testing
@testable import RelayCore

/// When a Notice folds to one line with Details, and the plain texts the review key Notice shows.
@Suite struct NoticeLayoutTests {
    /// One of each Notice, with realistic values (`newAgents` names two agents).
    static let every: [PanelNotice] = [
        .deliveryFailed(reason: "The Pond didn't answer within 10 seconds."),
        .actionFailed(verdict: .done, id: "a", title: "Send the logo image", reason: "The Pond didn't answer within 10 seconds."),
        .reopenFailed(id: "a", title: "Send the logo image", reason: "The Pond didn't answer within 10 seconds."),
        .storeFailed(reason: "The disk is full."),
        .queueMoved(path: "~/Library/Application Support/Hook/queue.json.corrupt-2026-11-20T09-22-01"),
        .settingsReloaded,
        .sessionClosed(id: "a"),
        .noLongerOpen(id: "a", canShowClosed: true),
        .offlineCached(since: "09:22"),
        .updating(version: "0.18.0", logPath: "~/Library/Logs/Hook/update.log"),
        .resumeFailed(reason: "Terminal isn't allowed to be controlled by Hook."),
        .pondOlder(current: "1.0.0", required: "^1.1.0", missing: [.corrections]),
        .hookOlder(pond: "2.0.0"),
        .mailboxUpToDate(pond: "1.4.0"),
        .mailboxUpdateFailed(reason: "Terminal isn't allowed to be controlled by Hook."),
        .mailboxUpdateCommandInvalid(reason: "the command is empty"),
        .ownerKeyRefused,
        .corrected(id: "a", rev: 2),
        .historyChanged(id: "a"),
        .reviewRecordsChanged,
        .reviewRecordsUnreadable,
        .doneHeldBack(id: "a", title: "Send the logo image"),
        .acceptFailed(id: "a", title: "Send the logo image", reason: "The Pond didn't answer within 10 seconds."),
        .crashReport(message: "Sent to your Pond."),
        .newAgents(ids: ["cursor", "zed"], names: ["Cursor", "Zed"]),
        .doneRefused(id: "a", title: "Send the logo image"),
    ]

    /// A long text, or a wide button beside the text, would squeeze the text into a narrow
    /// column: every such Notice has a short line to fold to, and folds.
    @Test(arguments: every) func aLongOrWideNoticeFolds(_ notice: PanelNotice) {
        let buttons = (notice.actionTitle?.count ?? 0) + (notice.secondaryActionTitle?.count ?? 0)
        let crowded = notice.text.count > NoticeLayout.longText || buttons > NoticeLayout.wideButtons
        // Two buttons that already sit on their own row don't squeeze the text.
        let ownRow = notice.secondaryActionTitle != nil && notice.summary == nil
        guard crowded, !ownRow else { return }
        #expect(notice.summary != nil, "\(notice) needs a summary")
        #expect(notice.collapses, "\(notice)")
    }

    @Test(arguments: every) func aSummaryIsOneShortLine(_ notice: PanelNotice) {
        guard let summary = notice.summary else { return }
        #expect(summary.count <= NoticeLayout.summaryLimit, "\(notice): \(summary.count)")
        #expect(!summary.contains("\n"))
        #expect(summary != notice.text)
    }

    @Test func shortNoticesStayAsTheyAre() {
        for notice: PanelNotice in [.settingsReloaded, .offlineCached(since: "09:22"), .hookOlder(pond: "2.0.0"),
                                    .pondOlder(current: "1.0.0", required: "^1.1.0", missing: [.corrections]),
                                    .corrected(id: "a", rev: 2), .ownerKeyRefused,
                                    .actionFailed(verdict: .done, id: "a", title: "Logo", reason: "offline")] {
            #expect(!notice.collapses, "\(notice)")
        }
    }

    @Test func theRuleNeedsASummary() {
        let long = String(repeating: "word ", count: 40)
        #expect(!NoticeLayout.collapses(text: long, actionTitle: nil, secondaryTitle: nil, summary: nil))
        #expect(NoticeLayout.collapses(text: long, actionTitle: nil, secondaryTitle: nil, summary: "Short."))
        #expect(!NoticeLayout.collapses(text: "Short text.", actionTitle: "Retry", secondaryTitle: nil, summary: "Short."))
        #expect(NoticeLayout.collapses(text: "Short text.", actionTitle: "Trust the Pond's History Again…",
                                       secondaryTitle: nil, summary: "Short."))
    }

    @Test func aLongFailureFoldsToItsFirstSentence() {
        let reason = String(repeating: "The Pond answered with an error page. ", count: 4)
        let notice = PanelNotice.actionFailed(verdict: .done, id: "a", title: "Send the logo", reason: reason)
        #expect(notice.collapses)
        #expect(notice.summary == "Couldn't send Done for “Send the logo”.")
    }

    @Test func theReviewKeyNoticeSaysWhatHappenedInPlainWords() {
        let notice = PanelNotice.reviewRecordsUnreadable
        #expect(notice.summary == "Corrected asks are locked: Hook can't open its review key.")
        #expect(notice.text == "macOS didn't let Hook read its review key from your Keychain. This usually happens "
            + "after installing a new copy of Hook. Until it's fixed, asks an agent changed after you saw them stay locked.")
        #expect(notice.collapses)
        #expect(notice.actionTitle == "Try Again")
        #expect(notice.secondaryActionTitle == "Start Over…")
        let help = try? #require(notice.help)
        #expect(help?.contains(".json") == false)
        #expect(help?.contains("Try Again") == true)
        #expect(help?.contains("Start Over") == true)
    }

    @Test func startOverSaysExactlyWhatIsLost() throws {
        let confirm = try #require(PanelNotice.reviewRecordsUnreadable.secondaryConfirmation)
        #expect(confirm.title == "Start over with a new review key?")
        #expect(confirm.message.contains("Every corrected ask needs a review again"))
        #expect(confirm.message.contains("each owner key has to be set up again"))
        #expect(confirm.message.contains("Touch ID"))
        #expect(confirm.confirmTitle == "Start Over")
        #expect(PanelNotice.pondOlder(current: "1.0.0", required: "^1.1.0", missing: []).secondaryConfirmation == nil)
    }
}
